# Kafka en heyPudú! — cómo está implementado

**Fecha:** 24-11-2026
**Alcance:** implementación de Kafka en el backend (salas de audio en vivo y
publicaciones), su despliegue y la evidencia verificada.
**Base de código:** backend `main` = `c363210`, frontend `main` = `834cb96`.

> Documentos relacionados: `respecto a kafka.txt` (decisiones originales y
> anexo con desviaciones), `PLAN-IMPLEMENTACION-KAFKA.md` (plan por fases v1.2),
> `DESPLIEGUE-AWS.md` (§17 y §18) y `COSTES-AWS.md`.

---

## 1. Qué funciones cumple Kafka en el sistema

Kafka es el **bus de eventos de audiencia y actividad**. No transporta audio ni
comandos transaccionales.

| Necesidad | Herramienta | Por qué |
|---|---|---|
| Audio en tiempo real | WebRTC (MediaMTX) | Baja latencia; el audio nunca pasa por Spring Boot |
| Comandos transaccionales (`post.delete`, `room.closed`, notificaciones) | **RabbitMQ** | Un mensaje se entrega, se confirma y desaparece |
| Eventos de audiencia, reacciones y actividad de publicaciones | **Kafka** | Se retiene el histórico, se puede reprocesar y varios grupos leen el mismo flujo |

Funciones concretas sobre Kafka:

1. **Métricas en tiempo real** de las salas: oyentes activos y reacciones.
2. **Auditoría persistente**: cada evento de sala se guarda en
   `heypudu_analytics.live_event_audit` con deduplicación por `eventId`.
3. **Analítica de publicaciones**: publicaciones creadas, eliminadas y vigentes.
4. **Desacople**: `ms-live` y `ms-posts` publican sin conocer a los consumidores;
   se pueden añadir consumidores nuevos sin tocar a los productores.
5. **Trazabilidad para la defensa**: el histórico se puede releer desde el
   principio del tópico, algo imposible con una cola tradicional.

---

## 2. Arquitectura y flujo

```
                        EC2 heypudu-live (t3.medium)
   ┌──────────────────────────────────────────────────────────────┐
   │  ZooKeeper :2181                                             │
   │      ▲                                                       │
   │  broker1 :9092/:9192      broker2 :9092/:9193   (RF=2)       │
   │      ▲            ▲                                          │
   │      │            └──────────── ms-analytics :8087 ──────────┼──► Kafka
   │  ms-live :8086 ───────────────► (publica LiveRoomEvent)      │
   │  ms-kafka-admin :8088 ─────────► AdminClient                 │
   └──────────────────────────────────────────────────────────────┘
                 ▲ 9192/9193 (listener EXTERNAL)
                 │
        EC2 backend: ms-posts :8083 (publica PostEvent)
```

- `ms-live`, `ms-analytics` y `ms-kafka-admin` usan el **listener interno**
  `broker1:9092,broker2:9092`.
- `ms-posts` vive en otra instancia y usa el **listener externo**
  `10.0.7.159:9192,10.0.7.159:9193`.
- Los productores usan la **clave como identificador de la entidad**
  (`roomId` o `postId`), de modo que todos los eventos de una sala o de una
  publicación caen en la misma partición y se consumen en orden.

---

## 3. Modelo de eventos

Dos DTO tipados, uno por flujo. Ambos son `record` de Java y viajan como JSON
**sin cabeceras de tipo**, para que cada consumidor fije su propia clase.

**`LiveRoomEvent`** (`com.heypudu.ms_live.messaging`, copia en `ms-analytics`):

```json
{
  "eventId": "5f0c1e42-7d21-4b3a-9a3e-2c1a1c1b9f01",
  "eventType": "ROOM_CREATED | LISTENER_JOINED | LISTENER_LEFT | REACTION",
  "roomId": "9a3b2c1d-...",
  "creatorCognitoSub": "04d8f468-...",
  "actorCognitoSub": "743804d8-...",
  "reactionType": "CLAP | HEART | null",
  "occurredAt": "2026-11-23T15:52:16.126Z",
  "schemaVersion": 1
}
```

**`PostEvent`** (`com.heypudu.ms_posts.messaging`, copia en `ms-analytics`):

```json
{
  "eventId": "9a1d7b1e-8a39-475c-b146-6ada797f3d03",
  "eventType": "POST_CREATED | POST_DELETED",
  "postId": "67fb3c38-...",
  "authorCognitoSub": "743804d8-...",
  "postType": "AUDIO | TEXT",
  "occurredAt": "2026-11-23T16:13:59.677Z",
  "schemaVersion": 1
}
```

`schemaVersion` permite evolucionar el contrato sin romper consumidores.

---

## 4. Productores

| Servicio | Clases | Publica en | Cuándo |
|---|---|---|---|
| `ms-live` | `config/KafkaConfig`, `messaging/LiveEventPublisher`, `messaging/LiveRoomEventSerializer` | `heypudu.live.events` (`live.events.topic`) | Crear sala, entrar/salir un oyente y cada reacción |
| `ms-posts` | `config/KafkaProducerConfig`, `messaging/PostKafkaEventPublisher`, `messaging/PostEventSerializer` | `heypudu.posts.events` (`posts.events.topic`) | Crear publicación, eliminar (propia o como admin) |

Configuración del `ProducerFactory` (idéntica en ambos servicios):

| Propiedad | Valor | Motivo |
|---|---|---|
| `acks` | `all` | No perder eventos aunque caiga un broker |
| `enable.idempotence` | `true` | Evita duplicados por reintentos del propio productor |
| `retries` | `3` | Reintento ante fallo transitorio del broker |
| `request.timeout.ms` / `delivery.timeout.ms` | 5 000 / 10 000 | Fallar rápido y registrar el error, sin bloquear la petición del usuario |
| Serializador de clave | `StringSerializer` | La clave es el UUID de la entidad |
| Serializador de valor | `LiveRoomEventSerializer` / `PostEventSerializer` (JSON con `JavaTimeModule` y sin cabeceras de tipo) | Fechas ISO-8601 y desacople de DTOs |

La publicación es **asíncrona y tolerante a fallos**: se registra el error en el
log (`whenComplete`) y la operación del usuario continúa.

---

## 5. Consumidores y consumer groups

Todo el consumo vive en `ms-analytics`, con **un contenedor por tópico** porque
cada flujo tiene su DTO (`config/KafkaConsumerConfig`).

| Grupo | Tópico | Listener | Qué hace |
|---|---|---|---|
| `live-analytics-group` | `heypudu.live.events` | `LiveEventListener` → `RoomMetricsService` | Oyentes activos (conjunto de `cognitoSub`), reacciones totales y por minuto |
| `live-audit-group` | `heypudu.live.events` | `LiveAuditListener` → `LiveEventAuditService` | Persiste cada evento en `live_event_audit` (histórico) |
| `posts-analytics-group` | `heypudu.posts.events` | `PostEventListener` → `PostMetricsService` | Publicaciones creadas, eliminadas y vigentes |

Balanceo y resiliencia (lo que pide el indicador):

- Cada grupo tiene **offsets independientes**: el mismo tópico se procesa dos
  veces con dos responsabilidades distintas (métricas y auditoría).
- Dentro de un grupo, Kafka **reparte las particiones** entre los miembros: al
  escalar `ms-analytics`, el trabajo se divide solo.
- `auto.offset.reset=earliest` y `enable.auto.commit=false`: sin pérdidas al
  arrancar en vacío y confirmación bajo control del framework.
- **Idempotencia por `eventId`**: `RoomMetricsService` y `PostMetricsService`
  deduplican con un `Map` acotado, y la tabla de auditoría tiene clave única, así
  que un reenvío o un rebalanceo no infla los conteos.

Endpoints que exponen el resultado:

| Endpoint | Devuelve |
|---|---|
| `GET /api/v1/analytics/rooms/{id}/stats` | `activeListeners`, `totalReactions`, `reactionsLastMinute`, `updatedAt` |
| `GET /api/v1/analytics/posts/stats` | `created`, `deleted`, `published`, `updatedAt` |

---

## 6. Manejo de errores y DLT

Configurado en `ms-analytics/config/KafkaErrorHandlingConfig` con
`DefaultErrorHandler` + `DeadLetterPublishingRecoverer`.

| Situación | Comportamiento |
|---|---|
| Payload inválido (`eventId`, `roomId`/`postId` o `eventType` nulos) | `IllegalArgumentException` → **no se reintenta**, va al DLT |
| Error de deserialización | `DeserializationException` → **no se reintenta**, va al DLT |
| Fallo transitorio (por ejemplo la base de datos) | 3 reintentos con backoff exponencial: 500 ms → 1 s → 2 s |
| Reintentos agotados | Se publica en `<topico>.DLT` y **se confirma el offset** |

Los listeners validan el payload y **dejan propagar** la excepción (antes la
capturaban y confirmaban, lo que ocultaba los fallos).

El DLT conserva la partición original del mensaje. Los tópicos se declaran en
`kafka/init-topics.sh`:

| Tópico DLT | Particiones | RF | Retención |
|---|---|---|---|
| `heypudu.live.events.DLT` | 3 | 2 | 30 días |
| `heypudu.posts.events.DLT` | 2 | 2 | 30 días |

> Ojo con el sufijo: Spring Kafka publica por defecto en `<topico>-dlt`; aquí se
> fija explícitamente `-DLT` mediante un `TopicPartition` resuelto a
> `record.topic() + ".DLT"`.

---

## 7. Administración con `ms-kafka-admin`

Microservicio nuevo (puerto 8088) que expone el `AdminClient` por REST, igual
que `ms-heypudu-rabbit-admin` hace con RabbitMQ. Todas las rutas exigen
`ROLE_ADMIN`.

| Método | Ruta | Operación |
|---|---|---|
| `GET` | `/api/v1/admin/kafka/cluster` | Brokers, controlador y `clusterId` |
| `GET` | `/api/v1/admin/kafka/topics` | Lista con particiones, RF e `internal` |
| `GET` | `/api/v1/admin/kafka/topics/{topic}` | Líder, réplicas e ISR por partición + configuraciones |
| `POST` | `/api/v1/admin/kafka/topics` | Crear tópico (particiones, RF, retención, cleanup policy) |
| `PATCH` | `/api/v1/admin/kafka/topics/{topic}/config` | Modificar configuraciones (incremental) |
| `DELETE` | `/api/v1/admin/kafka/topics/{topic}` | Borrar tópico |
| `GET` | `/api/v1/admin/kafka/groups` | Listar consumer groups |
| `GET` | `/api/v1/admin/kafka/groups/{groupId}` | Estado, miembros y **LAG por partición** |

Errores mapeados: 404 si el tópico o el grupo no existe, 400 si la petición no
valida, 403 sin rol, 500 solo ante fallos inesperados.

---

## 8. Parámetros por tópico y su justificación

| Tópico | Particiones | RF | Retención | `cleanup.policy` | `min.insync.replicas` | Justificación |
|---|---|---|---|---|---|---|
| `heypudu.live.events` | 3 | 2 | 7 días | `delete` | 1 | Tres particiones permiten paralelismo por sala; una semana cubre el histórico de la demo |
| `heypudu.posts.events` | 2 | 2 | 3 días | `delete` | 1 | Menos volumen que las salas; 3 días bastan para métricas |
| `*.DLT` | = original | 2 | 30 días | `delete` | 1 | Mismas particiones para conservar la partición del mensaje; retención larga para reprocesar |

`RF=2` con dos brokers da tolerancia a la caída de uno. `min.insync.replicas=1`
es deliberado: permite seguir publicando si un broker se reinicia, a cambio de
aceptar que en ese lapso solo confirma el líder.

---

## 9. Operación: comandos útiles

```bash
# Tópicos y configuración
docker exec heypudu-broker1 kafka-topics --bootstrap-server broker1:9092 --list
docker exec heypudu-broker1 kafka-topics --bootstrap-server broker1:9092 \
  --describe --topic heypudu.live.events

# Grupos y LAG
docker exec heypudu-broker1 kafka-consumer-groups --bootstrap-server broker1:9092 --list
docker exec heypudu-broker1 kafka-consumer-groups --bootstrap-server broker1:9092 \
  --describe --group live-audit-group

# Leer el histórico desde el inicio (evidencia de retención)
docker exec heypudu-broker1 kafka-console-consumer --bootstrap-server broker1:9092 \
  --topic heypudu.live.events --from-beginning --max-messages 5

# Inspeccionar mensajes no procesables
docker exec heypudu-broker1 kafka-console-consumer --bootstrap-server broker1:9092 \
  --topic heypudu.posts.events.DLT --from-beginning --max-messages 1

# Publicar un mensaje de prueba
echo '{}' | docker exec -i heypudu-broker1 kafka-console-producer \
  --bootstrap-server broker1:9092 --topic heypudu.posts.events
```

Desde HTTP (con un `idToken` de un usuario `ADMIN`):

```bash
curl -H "Authorization: Bearer $TOKEN" \
  https://<api-id>.execute-api.us-east-1.amazonaws.com/api/v1/admin/kafka/groups/live-audit-group
```

---

## 10. Compose de Kafka

| Archivo | Contenido | Uso |
|---|---|---|
| `docker-compose.kafka.yml` | ZooKeeper + 2 brokers + `kafka-init` + Kafka-UI (`:8090`) | Desarrollo local |
| `docker-compose.live.prod.yml` | ZooKeeper + 2 brokers + `kafka-init` + `ms-live` + `ms-analytics` + `ms-kafka-admin` + MediaMTX + Caddy | Producción (EC2 de salas) |
| `kafka/init-topics.sh` | Declaración idempotente de los dos tópicos y sus DLT | Arranque de ambos entornos |

Las imágenes están **fijadas en Confluent 7.9.0** (Kafka 3.9) porque Kafka 4.x
eliminó ZooKeeper. Los brokers exponen `INTERNAL` (para los servicios de la
misma EC2) y `EXTERNAL` en 9192/9193 (para `ms-posts` desde la otra instancia).

Kafka-UI en local: `http://localhost:8090`.

---

## 11. Evidencias verificadas

| Prueba | Resultado |
|---|---|
| Sala en vivo completa (crear, escuchar, reaccionar) | `ROOM_CREATED`, `LISTENER_JOINED`/`LEFT` y varias `REACTION` en `heypudu.live.events` |
| Publicación nueva | `POST_CREATED` en `heypudu.posts.events`, `LAG=0` en `posts-analytics-group` |
| Mensaje inválido (`{}`) | Recuperado en `heypudu.posts.events.DLT`, offset confirmado y partición desbloqueada |
| Auditoría | `live-audit-group` con las 3 particiones asignadas y `LAG=0` |
| Administrador | Target group `heypudu-kafka-admin-tg` healthy; `/api/v1/admin/kafka/*` responde 401 sin token |
| Tópicos | `heypudu.live.events` (3/RF2/7d), `heypudu.posts.events` (2/RF2/3d) y sus dos DLT |

---

## 12. Trazabilidad

| Commit | Cambio |
|---|---|
| `040e25e` | Consulta interna `followers/check` en `ms-users` |
| `63c7b0e` | Migración de KRaft a ZooKeeper + 2 brokers y segundo tópico |
| `1795150` | Productor en `ms-posts` y consumidor `posts-analytics-group` |
| `115fb83` | `ms-kafka-admin` |
| `72f2196` | Reintentos con backoff y DLT |
| `d5bb8b5` | Sufijo `.DLT` en el publicador de mensajes muertos |
| `c363210` | Merge a `main` |

Rutas clave del repositorio `heyPudu-backend`:

```text
kafka/init-topics.sh
docker-compose.kafka.yml
docker-compose.live.prod.yml
ms-live/src/main/java/com/heypudu/ms_live/{config/KafkaConfig,messaging/*}
ms-posts/src/main/java/com/heypudu/ms_posts/{config/KafkaProducerConfig,messaging/Post*}
ms-analytics/src/main/java/com/heypudu/ms_analytics/{config/Kafka*,listener/*,metrics/*,audit/*}
ms-kafka-admin/src/main/java/com/heypudu/ms_kafka_admin/{config,controller,service,dto}
```

---

## 13. Cumplimiento de la pauta EP5

| Requisito del enunciado | Dónde se satisface |
|---|---|
| Productores y consumidores conectados a tópicos Kafka | `ms-live`, `ms-posts` (productores); `ms-analytics` (3 grupos) |
| Microservicio administrador de Kafka (crear, modificar y eliminar tópicos y configuraciones) | `ms-kafka-admin`, endpoints de §7 |
| Compose con **ZooKeeper y brokers** | `docker-compose.kafka.yml` y `docker-compose.live.prod.yml` |
| Compose con **Kafka-UI** | Servicio `kafka-ui` en `docker-compose.kafka.yml` (`:8090`) |
| RabbitMQ sin afectar lo previo | `docker-compose.rabbit.yml`, `ms-heypudu-rabbit-admin`, colas y DLQ intactas |
| Filtros JWT del IDaaS | `OAuth2 Resource Server` en los siete microservicios; `ROLE_ADMIN` en el administrador |
| Frontend con login y JWT en las llamadas | Amplify + `AuthContext` + interceptor de `httpClient` |
| `.gitignore` por tecnología | `.gitignore` del backend y del frontend; `live-prod.env` y `*.pem` excluidos |
| Código compila y responde a pruebas básicas | `compileJava`/`build` en los siete servicios; tests de `ms-users` y `ms-live` (pendiente: `ms-analytics`) |
| Frontend sin errores de compilación | `npm run build` y `npm run lint` |

Pendiente en la pauta: pruebas automatizadas de `ms-analytics` y activar los
workflows de CI/CD (hoy están en `ms-*/.github/workflows`, ruta que GitHub no
ejecuta).
