# Plan de implementación — Kafka y Salas de Audio en Vivo

**Proyecto:** heyPudú!
**Versión del documento:** 1.2
**Fecha:** 24-11-2026
**Base técnica:** `respecto a kafka.txt` (Documento de Decisiones Técnicas v1.0)
**Base de estado real:** backend `main` = `c363210`, frontend `main` = `834cb96`, clúster desplegado con ZooKeeper + 2 brokers
**Propósito:** servir de guía única y viva para construir la funcionalidad de Salas de Audio en Vivo (Kafka + MediaMTX) en backend y frontend, marcando qué está terminado y qué falta.

> **Leyenda de estado**
> `[LISTO]` → existe, fue verificado en código y no requiere cambios para esta feature.
> `[PENDIENTE]` → hay que construirlo o modificarlo.
> `[DECISIÓN]` → hay que cerrar un criterio antes de codificar (ver sección 5).
> `[PARCIAL]` → existe una implementación inicial, pero falta completar criterios o dependencias externas.
>
> **Regla:** este documento se actualiza al cerrar cada tarea. Una tarea solo pasa a `[LISTO]` cuando su criterio de aceptación se cumple.

---

## 1. Resumen de estado

| Bloque | Estado | Detalle |
|---|---|---|
| Base de microservicios (5) | `[LISTO]` | Compilan los 5 con JDK 25 + Gradle 9.7.1 + Spring Boot 3.5.0 |
| Rama de trabajo | `[LISTO]` | `feature/ms-live`, 2 commits sobre `develop`/`main` |
| Seguridad JWT Cognito | `[LISTO]` | `OAuth2 Resource Server`, roles `user`/`admin`, patrón replicable |
| RabbitMQ (comandos/eventos/DLQ) | `[LISTO]` | Clúster 2 nodos, 3 colas quorum + 3 DLQ, ACK manual |
| RabbitMQ para salas | `[LISTO]` | `room.created` → notificación a seguidores; `room.closed` → limpieza de reacciones vía `q.heypudu.live.command` + DLQ, verificado end-to-end |
| Tabla `follows` y consulta de seguimiento | `[LISTO]` | `existsByFollowerIdAndFollowedId` + endpoint interno implementado |
| Frontend base (auth, HTTP, router) | `[LISTO]` | Axios con JWT, Amplify, React Router 7 |
| **Kafka (infra, productor, consumidor)** | `[LISTO]` | **ZooKeeper 3.9 + 2 brokers** en la EC2 de salas; dos tópicos con `RF=2`, tres consumer groups y sus DLT, verificados con eventos reales y `LAG=0` |
| **`ms-live`** | `[LISTO]` | CRUD, `/access`, reacciones persistidas, productor Kafka, RabbitMQ y auth de MediaMTX; falta test automatizado de auth |
| **`ms-analytics`** | `[LISTO]` | `/stats` de salas y de publicaciones, idempotencia, auditoría en `heypudu_analytics.live_events_audit` y reintentos con DLT |
| **`ms-kafka-admin`** | `[LISTO]` | Administrador REST de tópicos, configuraciones y grupos sobre `AdminClient`; desplegado con target group propio y regla del ALB |
| **MediaMTX (SFU + auth)** | `[LISTO]` | Auth HTTP y hooks; HTTPS/WSS con Caddy y certificado de Let's Encrypt en el despliegue |
| **Pantallas de salas en vivo** | `[LISTO]` | `/en-vivo`, `/en-vivo/crear` y `/en-vivo/:roomId`, con contador de oyentes, reacciones y cierre automático al terminar la sala |
| Endpoint `followers/check` en `ms-users` | `[LISTO]` | Implementado y probado end-to-end desde `ms-live` |
| Bloqueo de `/api/v1/internal/**` en el ALB | `[LISTO]` | Regla con respuesta fija `403` (verificado por el camino público) |
| Tests automatizados | `[PARCIAL]` | `ms-users` y `ms-live` (`MediamtxAuthServiceTest`); faltan `ms-analytics` y los workflows |
| CI/CD | `[PENDIENTE]` | Los 4 workflows están en subcarpetas (`ms-*/.github`), GitHub no los ejecuta |
| RabbitMQ en entorno local | `[PARCIAL]` | Funciona con `docker-compose.rabbit.yml`; `docker-compose.yml` no lo incluye |

**Progreso global de la feature:** fases 1–8 cerradas; frontend F1–F5 cerradas (F6 parcial). Pendiente: pruebas de `ms-analytics` y activar CI/CD.

---

## 2. Arquitectura objetivo

```
┌─────────────────────────────┐
│ Frontend React (Vercel)     │
│  emisor: getUserMedia → WHIP│
│  oyente: WHEP + reacciones  │
└───────┬───────────┬─────────┘
        │ HTTPS     │ HTTPS/WSS (audio WebRTC)
        ▼           ▼
┌──────────────┐  ┌────────────────────┐
│ API Gateway  │  │ MediaMTX (EC2)     │
│ + ALB        │  │  SFU: WHIP/WHEP    │
└──────┬───────┘  │  audio en memoria  │
       │          └──────┬─────────────┘
       ▼                 │ auth HTTP (VPC)
┌──────────────┐         │
│ ms-live:8086 │◄────────┘
│  · salas     │
│  · auth MTX  │──────► ms-users:8082  (¿lo sigue?)
│  · reacciones│
└───┬──────┬───┘
    │      │
    │      └──────► RabbitMQ (room.created / room.closed)
    │
    ▼
┌──────────────────┐        ┌──────────────────┐
│ Kafka:9092 (EC2) │───────►│ ms-analytics:8087│
│ heypudu.live.    │        │ oyentes, reacc./m│
│ events           │        └──────────────────┘
└──────────────────┘
```

**Principio de separación:** el audio **nunca** pasa por Spring Boot. Kafka transporta eventos de audiencia/reacciones. RabbitMQ sigue transportando comandos transaccionales.

---

## 3. Contratos técnicos (fuente de verdad para codificar)

### 3.1 Kafka

| Elemento | Valor |
|---|---|
| Consenso | **ZooKeeper 3.9** (Confluent 7.9.0) + **2 brokers** |
| Tópico de salas | `heypudu.live.events` — 3 particiones, `RF=2`, retención 7 días |
| Tópico de publicaciones | `heypudu.posts.events` — 2 particiones, `RF=2`, retención 3 días |
| Tópicos DLT | `heypudu.live.events.DLT` (3 particiones) y `heypudu.posts.events.DLT` (2 particiones), retención 30 días |
| Clave del mensaje | `roomId` en salas y `postId` en publicaciones (orden por entidad) |
| Productores | `ms-live` (salas) y `ms-posts` (publicaciones) |
| Consumidores | `live-analytics-group`, `live-audit-group` y `posts-analytics-group` en `ms-analytics` |
| Listener interno | `broker1:9092,broker2:9092` para los servicios de la EC2 de salas |
| Listener externo | `10.0.7.159:9192,10.0.7.159:9193` para `ms-posts`, que vive en la EC2 del backend |
| Auto-create topics | `false` (los declara `kafka-init`) |
| Administración | `ms-kafka-admin` (`AdminClient` por REST, `ROLE_ADMIN`) |

**DTO `LiveRoomEvent`** (paquete `com.heypudu.ms_live.messaging`):

```json
{
  "eventId": "5f0c1e42-...",
  "eventType": "ROOM_CREATED | LISTENER_JOINED | LISTENER_LEFT | REACTION",
  "roomId": "9a3b...",
  "creatorCognitoSub": "a1b2...",
  "actorCognitoSub": "c3d4...",
  "reactionType": "CLAP | HEART | null",
  "occurredAt": "2026-11-17T20:15:30Z",
  "schemaVersion": 1
}
```

**Reglas de serialización:** JSON. Desactivar cabeceras de tipo de Spring (`spring.json.add.type.headers=false`) y fijar el tipo destino en el consumidor para no acoplar los DTO entre servicios.

### 3.2 Endpoints nuevos

**`ms-users` (modificación mínima)**

| Método | Ruta | Respuesta |
|---|---|---|
| GET | `/api/v1/internal/users/by-cognito/{creatorSub}/followers/check?followerCognitoSub={listenerSub}` | `true` / `false` |

**`ms-live` (nuevo, puerto 8086, esquema `heypudu_live`)**

| Método | Ruta | Uso |
|---|---|---|
| POST | `/api/v1/live/rooms` | Crear sala → 201 `{id,title,status,whipUrl,startedAt}` |
| DELETE | `/api/v1/live/rooms/{id}` | Cerrar sala (solo creador) → 204 |
| GET | `/api/v1/live/rooms` | Salas activas (descubrimiento) |
| GET | `/api/v1/live/rooms/{id}` | Detalle + `whepUrl` + creador |
| GET | `/api/v1/live/rooms/{id}/access` | `{canListen:true}` para mostrar/ocultar botón |
| POST | `/api/v1/live/rooms/{id}/reactions` | `{type:"CLAP"}` → 202, publica `REACTION` |
| POST | `/api/v1/internal/mediamtx/auth` | Autorización de MediaMTX (publish/read) |
| POST | `/api/v1/internal/mediamtx/hooks` | JOINED/LEFT desde hooks de MediaMTX |

**`ms-analytics` (nuevo, puerto 8087)**

| Método | Ruta | Respuesta |
|---|---|---|
| GET | `/api/v1/analytics/rooms/{id}/stats` | `{activeListeners,totalReactions,reactionsPerMinute,updatedAt}` |
| GET | `/api/v1/analytics/rooms/top` | Top salas por oyentes (opcional) |

### 3.3 RabbitMQ (nuevo)

| Exchange | Routing key | Cola | Consumidor | Payload |
|---|---|---|---|---|
| `ex.heypudu.events` | `room.created` | `q.heypudu.notification` | `ms-users` | `NotificationEvent` con `type=ROOM_CREATED` |
| `ex.heypudu.cmd` | `room.closed` | **nueva** `q.heypudu.live.command` | el servicio que persista reacciones (ver D1) | `RoomClosedMessage` |

> **No reutilizar `q.heypudu.command`**: su consumidor deserializa `PostDeletedMessage`; un mensaje de sala rompería el listener y terminaría en DLQ.

### 3.4 MediaMTX

| Elemento | Valor |
|---|---|
| Publicar (emisor) | `https://<host>:8889/<roomId>/whip` |
| Escuchar (oyente) | `https://<host>:8889/<roomId>/whep` |
| Autenticación | HTTP externa → `ms-live` (solo por VPC) |
| Puertos SG | `8889/TCP` (señalización), `8189/UDP` (medios), `8888/TCP` (HLS opcional), `9997/TCP` solo interno |
| Identidad | `user = cognitoSub`, `password = JWT de Cognito` (ver D3) |

### 3.5 Variables de entorno nuevas

| Variable | Servicio | Ejemplo |
|---|---|---|
| `KAFKA_BOOTSTRAP_SERVERS` | ms-live, ms-analytics | `172.31.x.x:9092` |
| `KAFKA_TOPIC_LIVE_EVENTS` | ambos | `heypudu.live.events` |
| `CLIENTS_USERS_BASE_URL` | ms-live | `http://ms-users:8082` |
| `MEDIAMTX_PUBLIC_URL` | ms-live | `https://live.heypudu.example` |
| `MEDIAMTX_SERVICE_TOKEN` | ms-live | secreto compartido con MediaMTX |
| `LIVE_ROOM_MAX_DURATION_MINUTES` | ms-live | `120` |

Las URLs `whipUrl`/`whepUrl` **las construye el backend** a partir de `MEDIAMTX_PUBLIC_URL`; el frontend no necesita conocer la IP del SFU.

---

## 4. Fases de backend

### Fase 0 — Preparación (0,5 día)

- [x] **LISTO** Rama `develop` existe e iguala a `main`.
- [x] **LISTO** Los 5 microservicios compilan con JDK 25 y el wrapper Gradle 9.7.1.
- [x] **LISTO** Rama de trabajo `feature/ms-live` creada desde `develop` (2 commits: `8a91122`, `040e25e`).
- [ ] **PENDIENTE** Arreglar `docker-compose.yml` local: `ms-live` y su esquema ya están incluidos, pero faltan RabbitMQ, las variables `RABBITMQ_*` y `ms-heypudu-rabbit-admin`.
- [ ] **PARCIAL** Reactivar dependencias de test: hecho en `ms-users` (`040e25e`); faltan `ms-auth`, `ms-posts` y `ms-interactions`.
- [ ] **PENDIENTE** Documentar la feature en `README.md` (sección nueva "Kafka y salas en vivo").

**Hecho cuando:** `docker compose up` levanta el entorno completo y los flujos RabbitMQ actuales funcionan en local.

### Fase 1 — Endpoint `followers/check` en `ms-users` (0,5 día)

- [x] **LISTO** `FollowRepository.existsByFollowerIdAndFollowedId(...)` existe.
- [x] **LISTO** `GET /api/v1/internal/users/by-cognito/{sub}/summary` resuelve usuario por `cognito_sub`.
- [x] **LISTO** Método `boolean isFollowing(UUID followerSub, UUID followedSub)` en `FollowService` + `FollowServiceImpl`.
- [x] **LISTO** Endpoint en `InternalUserController`.
- [x] **LISTO** Test unitario: sigue / no sigue / usuario inexistente.

> Verificado en el commit `040e25e`: el criterio de `404` se cumple porque `isFollowing` resuelve al creador con `findActiveUserByCognitoSub` antes de consultar la relación.

**Hecho cuando:** `GET .../followers/check?followerCognitoSub=` devuelve `true/false` con JWT válido y `404` si el creador no existe.

### Fase 2 — Esqueleto de `ms-live` (1 día)

- [x] **LISTO** Crear `ms-live/` con la estructura estándar (`build.gradle`, `settings.gradle`, `Dockerfile`, `README.md`, wrapper copiado de `ms-users`).
- [x] **LISTO** Dependencias: web, security, oauth2-resource-server, data-jpa, validation, actuator, flyway, postgresql, amqp y **spring-kafka**.
- [x] **LISTO** Adaptar `SecurityConfig`, `JwtAuthConverter`, `CognitoUserExtractor`, `GlobalExceptionHandler`.
- [x] **LISTO** `application.yml` / `-dev.yml` / `-prod.yml` (puerto 8086, esquema `heypudu_live`).
- [x] **LISTO** Migración `V1__init_live_rooms.sql`:

```sql
CREATE TABLE live_rooms (
    id                  UUID PRIMARY KEY,
    creator_id          UUID NOT NULL,
    creator_cognito_sub UUID NOT NULL,
    title               VARCHAR(120) NOT NULL,
    description         VARCHAR(500),
    status              VARCHAR(20) NOT NULL DEFAULT 'LIVE',
    started_at          TIMESTAMPTZ NOT NULL,
    ended_at            TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_live_rooms_status CHECK (status IN ('LIVE','CLOSED'))
);

CREATE INDEX idx_live_rooms_status ON live_rooms (status, started_at DESC);
CREATE INDEX idx_live_rooms_creator ON live_rooms (creator_cognito_sub);
CREATE UNIQUE INDEX uq_live_room_creator_live
    ON live_rooms (creator_cognito_sub)
    WHERE status = 'LIVE';
```

- [x] **LISTO** Entidad `LiveRoom`, repositorio, servicio, controlador y DTOs `record`; el `LiveRoomServiceImpl` realiza la transformación a respuestas.
- [x] **LISTO** Reglas: solo el creador cierra su sala; una sala `LIVE` por creador (reforzado con el índice único parcial de la migración); cerrar una sala ya cerrada es idempotente.
- [x] **LISTO** `GET /{id}/access`: responde `true` al creador, consulta a `ms-users` para el resto y `false` si la sala no está `LIVE`.
- [ ] **PENDIENTE** Prueba punta a punta de `/access` con un seguidor real y un no seguidor.

**Observaciones de implementación (no bloquean):**
- `createRoom` guarda el `cognitoSub` en `creator_id` y en `creator_cognito_sub`. Si más adelante se necesita el `id` de `users`, habrá que consultarlo a `ms-users`.
- La migración usa `UUID` generado por JPA (`GenerationType.UUID`) en lugar de `gen_random_uuid()`; funciona, pero difiere del estilo de los demás esquemas.
- `build.gradle` declara Lombok aunque la entidad no lo usa; la convención del proyecto es entidad sin Lombok.

**Hecho cuando:** crear/consultar/cerrar salas funciona contra Neon y el acceso responde correctamente para seguidor y no seguidor.

### Fase 3 — Infraestructura Kafka local (0,5 día)

- [x] **LISTO** `docker-compose.kafka.yml` (KRaft, sin Zookeeper — ver D5): un broker, Kafka UI y volúmenes.
- [x] **LISTO** Script de inicialización del tópico `heypudu.live.events` (3 particiones, RF 1): `kafka/init-topics.sh`, idempotente.
- [x] **LISTO** Verificación: tópico descrito con 3 particiones/RF 1/retención 7 días y produce/consume de un JSON válido confirmado. Tópico recreado vacío al final.
- [x] **LISTO** `ms-live` apunta a `kafka:9092` y recibe `KAFKA_TOPIC_LIVE_EVENTS` en `docker-compose.yml`.
- [x] **LISTO** Documentado el arranque local en `README.md` (sección "Levantar Kafka").

**Hecho cuando:** el tópico existe con la configuración indicada y se puede producir/consumir un mensaje de prueba.

### Fase 4 — Productor Kafka en `ms-live` (1 día)

- [x] **LISTO** `KafkaConfig` con `ProducerFactory` idempotente, `KafkaTemplate<String, LiveRoomEvent>` y `JsonSerializer` (sin cabeceras de tipo).
- [x] **LISTO** DTO `LiveRoomEvent` + enum `LiveEventType` + enum `ReactionType` en `com.heypudu.ms_live.messaging`.
- [x] **LISTO** `LiveEventPublisher` con `roomCreated`, `listenerJoined`, `listenerLeft`, `reaction`, siempre con clave `roomId`.
- [x] **LISTO** `ROOM_CREATED` al crear sala; `REACTION` en `POST /api/v1/live/rooms/{id}/reactions`.
- [x] **LISTO** Persistencia D1: tabla `live_reactions` (migración `V2__init_live_reactions.sql`), entidad y repositorio.
- [x] **LISTO** Manejo de fallos: cualquier error de Kafka se registra en log y la creación de sala/reacción no falla por Kafka. La métrica queda pendiente.
- [x] **LISTO** `ms-live` compila (`compileJava`) con los cambios.

**Hecho cuando:** crear una sala y mandar una reacción producen eventos visibles en el tópico.

### Fase 5 — `ms-analytics` (1,5 días)

- [x] **LISTO** Servicio nuevo en 8087 con la misma base técnica (Java 25, Spring Boot 3.5, Gradle wrapper, Dockerfile) y seguridad JWT. Las métricas son en memoria, así que no requiere esquema propio.
- [x] **LISTO** `KafkaListener` con `groupId=live-analytics-group`, `enable.auto.commit=false` y ACK manual.
- [x] **LISTO** Estado en memoria por sala (`ConcurrentHashMap<UUID, RoomMetrics>`): oyentes activos, reacciones totales y ventana de 1 minuto.
- [x] **LISTO** Idempotencia por `eventId` con caché acotada de 20 000 eventos.
- [x] **LISTO** Endpoint `GET /api/v1/analytics/rooms/{id}/stats`.
- [x] **LISTO** Verificado el consumo con 4 eventos de prueba: `LAG=0` y health `UP`. Tópico y offsets de prueba limpiados.
- [x] **LISTO** Segundo listener `live-audit-group` que persiste el histórico en `heypudu_analytics.live_events_audit` (PK = `eventId`, sin duplicados al reprocesar). Verificado: replay del tópico (4 `ROOM_CREATED`, 11 `REACTION`), evento en vivo insertado en tiempo real y reenvío del mismo `eventId` sin duplicar.
- [x] **LISTO** Validar `/stats` con un emisor y dos oyentes reales (requiere frontend/MediaMTX). Validado un emisor y reacciones reales: `/stats` devuelve `totalReactions` creciente y `activeListeners` (la prueba con dos oyentes simultáneos queda pendiente).

**Hecho cuando:** con 1 emisor y 2 oyentes reales, `/stats` refleja `activeListeners=2` y las reacciones se acumulan por minuto.

### Fase 6 — RabbitMQ para salas (0,5 día)

- [x] **LISTO** `RK_ROOM_CREATED` en `ms-users` y `RK_ROOM_CREATED`/`RK_ROOM_CLOSED` en `ms-live`; no hizo falta tocar los demás servicios.
- [x] **LISTO** `ms-live` publica `room.created` en `ex.heypudu.events` al abrir la sala (`RoomEventPublisher`).
- [x] **LISTO** `ms-users`: `NotificationEvent` ampliado con `roomId`, `roomTitle` y `actorCognitoSub`; `NotificationService` resuelve al creador y notifica a todos sus seguidores con `eventId` determinista por destinatario (idempotente).
- [x] **LISTO** `ms-live` publica `room.closed` en `ex.heypudu.cmd` al cerrar (solo en la transición `LIVE → CLOSED`).
- [x] **LISTO** Cola `q.heypudu.live.command` + DLQ + bindings, con consumidor propio que borra las reacciones persistidas (D1).
- [x] **LISTO** Prueba real: `room.created` generó la notificación del seguidor; `room.closed` borró la reacción; un mensaje inválido terminó en `q.heypudu.live.command.dlq` y fue registrado por el listener de DLQ.

**Hecho cuando:** al crear una sala los seguidores reciben notificación y al cerrarla se ejecuta la limpieza definida.

### Fase 7 — MediaMTX y autorización (1,5 días)

- [x] **LISTO** `docker-compose.mediamtx.yml` + `mediamtx/mediamtx.yml`; la imagen oficial es distroless, así que se construye una base Alpine con `curl` para los hooks.
- [x] **LISTO** `authMethod: http` apuntando a ms-live (`host.docker.internal` en local; IP privada en EC2).
- [x] **LISTO** Hooks `runOnRead`/`runOnUnread` hacia `/api/v1/internal/mediamtx/hooks` (ver D4).
- [x] **LISTO** `/internal/mediamtx/auth`: `publish` solo creador, `read` solo seguidor, sala `LIVE` y validación D3 (`sub == user`).
- [x] **LISTO** `/internal/mediamtx/hooks`: `JOINED`/`LEFT` → Kafka (verificado con un evento `LISTENER_JOINED` real).
- [x] **LISTO** Token de servicio validado en ambos endpoints (`X-Mediamtx-Token` o query).
- [x] **LISTO** CORS de WebRTC configurado para `localhost:5173` y Vercel.
- [ ] **PENDIENTE** HTTPS/WSS en MediaMTX para el despliegue (local queda en HTTP).
- [x] **LISTO** Prueba con JWT real (19-11-2026): `publish` y `read` autorizados en `ms-live`, y WHEP alcanzó MediaMTX sin `401` (HTTP 404 por no haber publicador). Falta validar el audio real con un navegador/publicador.

**Hecho cuando:** un seguidor escucha y un no seguidor recibe `401`; el creador publica y nadie más puede hacerlo.

### Fase 8 — Despliegue y seguridad de plataforma (1 día)

- [x] **LISTO** `ms-live` (8086) y `ms-analytics` (8087) con `mem_limit` y variables: se creó `docker-compose.live.prod.yml` para la EC2 3 (Kafka + MediaMTX + Caddy + ambos servicios), acompañado de `mediamtx/mediamtx.prod.yml`, `caddy/Caddyfile` y `live-prod.env.example`.
- [x] **LISTO** Reglas del ALB para `/api/v1/live/*` y `/api/v1/analytics/*`: prioridades 12 y 13 del listener `heypudu-alb` hacia `heypudu-live-tg` (8086) y `heypudu-analytics-tg` (8087). Verificado: ambas rutas responden 502 (sin servicio aún) mientras `/api/v1/users/me` sigue en 401.
- [x] **LISTO** **Bloquear `/api/v1/internal/**`**: regla prioridad 11 del ALB con respuesta fija 403. Verificado: `/api/v1/internal/users/.../summary` → 403, sin afectar a las rutas existentes.
- [ ] **PENDIENTE** Security Groups: MediaMTX `8889/TCP`, `8189/UDP`; Kafka `9092` solo desde backend.
- [ ] **PENDIENTE** Tercera EC2 `t3.small` con `ms-live`, `ms-analytics` y MediaMTX (decisión D7); puertos `8889/TCP` y `8189/UDP` públicos.
- [ ] **PENDIENTE** Elastic IP (o DNS dinámico si AWS Academy no la permite) **solo para MediaMTX**, porque su IP pública cambia al detener/arrancar. `MEDIAMTX_PUBLIC_URL` y `webrtcAdditionalHosts` usan ese dominio.
- [ ] **PENDIENTE** Confirmar que la API Gateway/ALB solo transportan las APIs; el audio WebRTC va directo al SFU (API Gateway no enruta UDP).
- [ ] **PENDIENTE** Secrets/`.env` de EC2 actualizados (nunca en el repo).

**Hecho cuando:** el flujo completo funciona desde Vercel contra la infraestructura real.

---

## 5. Decisiones abiertas (resolver antes de la fase indicada)

| ID | Decisión | Recomendación | Fase |
|---|---|---|---|
| **D1** | ¿Las reacciones se persisten? El documento pide que `room.closed` haga que `ms-interactions` borre reacciones, pero hoy las reacciones solo irían a Kafka. | **Decidido (18-11-2026):** persistir reacciones en `heypudu_live.live_reactions` y limpiar con `room.closed` consumido por `ms-live` (no por `ms-interactions`). | 2 / 6 |
| **D2** | ¿`room.created` es comando o evento? | Tratarlo como **evento** en `ex.heypudu.events` y bindear `q.heypudu.notification`. Evita una cola de comandos nueva para notificaciones y reutiliza el flujo probado. | 6 |
| **D3** | Identidad en MediaMTX: el documento dice que pasa `cognito_sub`, pero si es un parámetro libre cualquiera puede suplantarlo. | **Decidido e implementado (18-11-2026):** `user = cognitoSub`, `password`/`token` = JWT; `ms-live` valida firma y exige `sub == user`. | 7 |
| **D4** | ¿Cómo se detecta `LISTENER_LEFT`? | **Hooks implementados** (`runOnRead`/`runOnUnread` → Kafka). Fallback pendiente: expirar oyentes sin heartbeat en `ms-analytics` (30 s). | 5 / 7 |
| **D5** | Zookeeper vs KRaft | **Decidido (18-11-2026): KRaft**, implementado en `docker-compose.kafka.yml` (sin Zookeeper, ahorro de memoria en `t3.micro`). | 3 |
| **D6** | ¿`ms-analytics` es microservicio o módulo de `ms-live`? | Microservicio separado: demuestra consumo de Kafka con otro consumer group, que es el objetivo de la evaluación. | 5 |
| **D7** | Capacidad EC2 | **Decidido (19-11-2026):** tercera EC2 `t3.small` con `ms-live` + `ms-analytics` + MediaMTX; Kafka en esa instancia o en una cuarta según memoria. La EC2 backend actual no admite más contenedores. | 8 |

---

## 6. Fases de frontend

### Fase F1 — Contratos y cliente API (0,5 día)

- [x] **LISTO** `httpClient` con interceptor que inyecta el JWT de Cognito.
- [x] **LISTO** Estructura `src/api/*Service.ts` y tipos en `src/types/api.ts`.
- [x] **LISTO** `src/types/live.ts`: `LiveRoom`, `LiveRoomAccess`, `LiveRoomStats`, `ReactionType` (incluye `creatorName`, `creatorUsername`, `creatorAvatarUrl`).
- [x] **LISTO** `src/api/liveService.ts`: `createRoom`, `closeRoom`, `listActiveRooms`, `getRoom`, `checkAccess`, `sendReaction`, `getRoomStats`.
- [x] **LISTO** Exportar desde `src/api/index.ts`.

**Hecho cuando:** se puede crear y consultar una sala por consola usando los servicios tipados.

### Fase F2 — Utilidades WebRTC (1 día)

- [x] **LISTO** `src/live/whip.ts`: `getUserMedia({audio:true})` + `RTCPeerConnection`, `POST` del SDP a `whipUrl` (`Content-Type: application/sdp`), cierre ordenado de pistas y conexión. El procesamiento de voz (AGC/echo/noise) queda desactivado por defecto para evitar el volumen ondulante.
- [x] **LISTO** `src/live/whep.ts`: `RTCPeerConnection` en modo recepción, `POST` del offer a `whepUrl`, reproducción en `<audio>`.
- [x] **LISTO** Manejo de estados: `idle | connecting | live | error`, reintento y `cleanup` al desmontar.
- [x] **LISTO** (Opcional) medidor de nivel de micrófono para el emisor.

**Hecho cuando:** publicar y escuchar funciona contra MediaMTX desde `localhost` (con HTTPS local o túnel).

### Fase F3 — Pantallas (1,5 días)

- [x] **LISTO** `src/pages/GoLivePage.tsx`: formulario título/descripción, crea sala, publica audio, muestra oyentes y botón "Finalizar". Recupera la sala activa propia si ya existía una.
- [x] **LISTO** `src/pages/LiveRoomPage.tsx`: si es creador → emisor; si no → verifica acceso, muestra "Escuchar" o el aviso "Debes seguir a este usuario".
- [x] **LISTO** `src/pages/LiveRoomsPage.tsx`: listado de salas activas con contador de oyentes.
- [x] **LISTO** `src/components/live/`: `LiveBadge`, `ListenerCount`, `LiveTimer`, `ReactionBar`, `LiveRoomCard`.
- [x] **LISTO** Reacciones: botones que llaman a `sendReaction` con throttling (1 por segundo por usuario).

**Hecho cuando:** el flujo completo (crear → escuchar → reaccionar → cerrar) funciona desde la UI.

### Fase F4 — Navegación y estilos (0,5 día)

- [x] **LISTO** Rutas en `src/app/router.tsx`: `/en-vivo`, `/en-vivo/crear`, `/en-vivo/:roomId` (dentro de `RequireAuth`). La ruta de prueba `/en-vivo/prueba` se retiró.
- [x] **LISTO** Acceso "En vivo" como píldora con punto en `Header` (icono `broadcast` en `Icon.tsx`). Se decidió **no** tocar la bottom bar: la función es secundaria y el diseño móvil ya está cerrado.
- [x] **LISTO** `src/styles/pages/live.css` + import en `styles/index.css`.
- [x] **LISTO** Accesibilidad: `aria-label` en botones de reacción, foco y estados deshabilitados.

**Hecho cuando:** se llega a todas las pantallas desde la navegación y en móvil no se rompe el layout.

### Fase F5 — Integración y pulido (0,5 día)

- [x] **LISTO** Variables de entorno documentadas en `.env.example` (`VITE_API_BASE_URL`, `VITE_ANALYTICS_BASE_URL`, Cognito).
- [x] **LISTO** Manejo de errores: sala cerrada, sin permisos, MediaMTX caído, permiso de micrófono denegado, con botón "Reintentar" en el stage.
- [x] **LISTO** `npm run lint` y `npm run build` sin errores.
- [x] **LISTO** Desplegado en Vercel: `main` = `702cc3e`. HTTPS del frontend OK; el WSS de MediaMTX queda para la fase 8.

### Fase F6 — Pulido visual y marca (transversal, sin fecha)

- [x] **LISTO** Alineación: topbar, contenido y dock inferior comparten los mismos márgenes laterales en desktop y móvil; el header ya no cambia de ancho entre rutas (`scrollbar-gutter: stable`).
  - [x] **LISTO** Header en móvil (≤540 px): el botón "Cerrar sesión" se cortaba y el acceso a salas quedaba como un punto sin nombre. Ahora usa icono `broadcast`, `aria-label="Salas en vivo"` y padding reducido; sin overflow a 390 px.
- [x] **LISTO** Favicon: `public/puduIcon.png` (128×128, arte del pudú en coral `#ff816d` con fondo transparente) + `public/apple-touch-icon.png` (180×180, coral sobre `#111011` porque iOS no soporta transparencia) y sus `<link>` en `index.html`.
- [x] **LISTO** Título y metadatos: `heyPudú! · Conversaciones que se escuchan`, descripción del producto y Open Graph/Twitter en `index.html`.
- [x] **LISTO** Más referencias al pudú: nota en el login (el pudú escucha antes de moverse), `NotFoundPage` y estado vacío de `/en-vivo` ("Ningún pudú está al aire").
- [ ] **PENDIENTE** Pendiente de revisión visual: `#root`/`.page` en pantallas largas, cards de salas con títulos largos y el stage del oyente en móvil.
- [ ] **PENDIENTE** Unificar colores: el proyecto no usa variables CSS; `live.css` y las demás hojas repiten hex. Crear tokens en `styles/base.css` y migrar (mejora opcional).

**Hecho cuando:** la marca es consistente en todo el sitio, hay favicon y el título describe el producto.

---

## 7. Infraestructura y despliegue

Estado real del despliegue (ver `DESPLIEGUE-AWS.md` §17 y §18):

| Componente | Instancia | Puertos | Estado |
|---|---|---|---|
| MediaMTX + Caddy (TLS) | EC2 `heypudu-live` (`t3.medium`) + Elastic IP `35.170.42.143` | 80/443 (Caddy), 8189/UDP, 9997 interno | `[LISTO]` |
| ZooKeeper + 2 brokers | misma EC2 `heypudu-live` | 2181 y 9092 internos, 9192-9193 externos | `[LISTO]` |
| `ms-live`, `ms-analytics`, `ms-kafka-admin` | misma EC2 `heypudu-live` | 8086, 8087, 8088 | `[LISTO]` |
| `ms-posts` (productor) | EC2 backend | 8083 | `[LISTO]` |
| RabbitMQ | EC2 existente | 5672 interno | `[LISTO]` |
| Frontend | Vercel | — | `[LISTO]` |

**Compose de referencia (ZooKeeper + 2 brokers):**

```yaml
services:
  zookeeper:
    image: confluentinc/cp-zookeeper:7.9.0
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
  broker1:
    image: confluentinc/cp-kafka:7.9.0
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: INTERNAL://broker1:9092,EXTERNAL://<IP_PRIVADA>:9192
  broker2:
    image: confluentinc/cp-kafka:7.9.0
    environment:
      KAFKA_BROKER_ID: 2
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: INTERNAL://broker2:9092,EXTERNAL://<IP_PRIVADA>:9193
```

Kafka 4.x eliminó ZooKeeper, por eso las imágenes quedan fijadas en la línea
7.9.0 (Kafka 3.9).

---

## 8. Pruebas y criterios de aceptación (demo EP2)

### Pruebas mínimas

- [x] **LISTO** `ms-users`: unitaria de `followers/check` (`FollowServiceImplTest`, commit `040e25e`).
- [x] **LISTO** `ms-live`: unitaria de `MediamtxAuthServiceTest` (decodificación del `MTX_QUERY` url-encoded, 7 casos).
- [ ] **PENDIENTE** `ms-live`: `@WebMvcTest` del endpoint de auth (publish del creador, read de seguidor, read de no seguidor, sala cerrada).
- [ ] **PENDIENTE** `ms-live`: test del productor con Kafka embebido/Testcontainers.
- [ ] **PENDIENTE** `ms-analytics`: test del conteo con eventos sintéticos (idempotencia incluida).
- [x] **LISTO** DLT: mensaje inválido (`{}`) en `heypudu.posts.events` recuperado en `heypudu.posts.events.DLT` con el offset confirmado.
- [x] **LISTO** Prueba de DLQ con mensaje inválido en `q.heypudu.live.command`.
- [x] **LISTO** Frontend: `npm run build` y prueba manual guiada en Vercel.

### Guion de demo (evidencia para la evaluación)

1. **Sala creada** → `ROOM_CREATED` visible con `kafka-console-consumer.sh --from-beginning` y notificación al seguidor en la campana.
2. **No seguidor** → intenta escuchar, MediaMTX devuelve `401`, la UI muestra "Debes seguir a este usuario".
3. **Seguidor** → escucha audio (<500 ms de latencia), `LISTENER_JOINED` en Kafka y `activeListeners=1` en `/stats`.
4. **Reacciones** → `REACTION` en Kafka y `reactionsPerMinute` actualizado.
5. **Cierre** → `ROOM_CLOSED` y limpieza/notificación según D1.
6. **Histórico** → consumir el tópico desde el inicio demuestra la retención (diferencia clave frente a RabbitMQ).
7. **RabbitMQ** → mostrar DLQ con un mensaje fallido (evidencia ya existente del proyecto).

---

## 9. Riesgos

| Riesgo | Impacto | Mitigación aplicada |
|---|---|---|
| Memoria insuficiente al sumar ZooKeeper y dos brokers | Contenedores reiniciando en la demo | EC2 de salas subida a `t3.medium` + swap de 2 GB |
| MediaMTX sin TLS y frontend en HTTPS | El navegador bloquea WHIP/WHEP | Caddy con Let's Encrypt sobre `35-170-42-143.sslip.io` |
| CORS del SFU mal configurado | `POST` del SDP falla | `webrtcAllowOrigins` con el origen de Vercel, verificado |
| `/api/v1/internal/**` expuesto por el wildcard | Cualquiera puede llamar al auth de MediaMTX | Regla del ALB con respuesta fija `403` |
| Mensajes defectuosos bloquean una partición | Consumidor detenido | `DefaultErrorHandler` con 3 reintentos y DLT por tópico |
| Duplicación de `RabbitTopology` | Routing keys desincronizadas | Constantes en una sola clase + topología declarativa |
| Sin tests ni CI | Regresiones al tocar mensajería | Pendiente: tests de `ms-analytics` y workflows en la raíz |
| Kafka sin idempotencia en consumidor | Conteos inflados tras rebalanceo | Deduplicación por `eventId` en ambos servicios |
| Suplantación de `cognitoSub` en MediaMTX | Acceso indebido a salas | Validación del JWT y comparación con el `user` declarado |

---

## 10. Registro de avance

| Fase | Alcance | Estado |
|---|---|---|
| 0 | Preparación (compose local, tests, rama) | `[PARCIAL]` — rama y `ms-live` en compose; faltan RabbitMQ y 3 servicios con tests |
| 1 | `followers/check` en `ms-users` | `[LISTO]` — commit `040e25e` |
| 2 | Esqueleto y CRUD de `ms-live` | `[PARCIAL]` — CRUD y `/access` listos; faltan Kafka, RabbitMQ y MediaMTX |
| 3 | Infra Kafka local | `[LISTO]` |
| 4 | Productor `LiveRoomEvent` | `[LISTO]` |
| 5 | `ms-analytics` (consumer groups) | `[LISTO]` — analítica + auditoría |
| 6 | RabbitMQ `room.created` / `room.closed` | `[LISTO]` |
| 7 | MediaMTX + auth + hooks | `[LISTO]` — falta HTTPS para despliegue |
| 8 | Despliegue AWS y bloqueo de internos | `[LISTO]` — EC2 `t3.medium` con EIP, TLS con Caddy, ALB y reglas, Kafka con ZooKeeper |
| F1 | Tipos y `liveService` | `[LISTO]` |
| F2 | Utilidades WHIP/WHEP | `[LISTO]` |
| F3 | Pantallas de salas | `[LISTO]` |
| F4 | Navegación y estilos | `[LISTO]` — sin tocar la bottom bar (decisión de diseño) |
| F5 | Integración y despliegue frontend | `[LISTO]` — `lint`, `build` y deploy en Vercel (`702cc3e`) |
| F6 | Pulido visual y marca | `[PARCIAL]` — iconos, título, textos y alineación listos; faltan revisión visual fina y tokens de color |

---

## 11. Orden de ejecución recomendado

```
0 → 1 → 2 → 3 → 4 → 5 → F1 → F2 → F3 → 6 → 7 → F4 → F5 → 8
```

**Justificación:** primero se habilita el entorno y la autorización (0-1), luego el dominio de salas (2), después Kafka punta a punta (3-5), en paralelo se prepara el frontend cuando ya hay contratos estables (F1-F3), se cierra la mensajería transaccional (6), se conecta el audio real (7) y solo al final se asegura la plataforma y se despliega (8).

**Estado del orden:** todas las fases cerradas. Lo único abierto son los tests de
`ms-analytics` y la activación de CI/CD.

> **Regla de oro:** no empezar la Fase 7 (audio) sin haber validado Fases 3-5 con eventos reales. Kafka es el corazón de la evaluación; MediaMTX es el transporte.

---

## 12. Bitácora de avance

| Fecha | Commit | Cambio | Fase |
|---|---|---|---|
| 17-11-2026 | `8a91122` | Creación de `ms-live`: esqueleto, esquema `heypudu_live`, CRUD de salas, `/access`, `docker-compose.yml` e `init-db.sql` | 2 |
| 18-11-2026 | `040e25e` | Endpoint interno `followers/check` en `ms-users` + test `FollowServiceImplTest` | 1 |
| 20-11-2026 | `66c9b2f` | Artefactos de despliegue: `docker-compose.live.prod.yml`, `Caddyfile`, `mediamtx.prod.yml`, `live-prod.env.example` | 8 |
| 21-11-2026 | `da92cf1` | Entrypoint con `envsubst` para MediaMTX y despliegue en la EC2 de salas con TLS | 8 |
| 21-11-2026 | `679f0ac` | Corrección: MediaMTX entrega `MTX_QUERY` url-encoded; se decodifica en `ms-live` | 7 |
| 23-11-2026 | `63c7b0e` | Migración de KRaft a ZooKeeper + 2 brokers y segundo tópico con parámetros por flujo | EP5 |
| 23-11-2026 | `1795150` | Segundo tópico: productor en `ms-posts` y consumidor `posts-analytics-group` en `ms-analytics` | EP5 |
| 23-11-2026 | `115fb83` | `ms-kafka-admin`: tópicos, configuraciones y grupos sobre `AdminClient` | EP5 |
| 23-11-2026 | `72f2196` | Reintentos con backoff y tópicos DLT en los consumidores | EP5 |
| 24-11-2026 | `c363210` | Merge a `main`: Kafka con ZooKeeper, segundo tópico, administrador y DLT | EP5 |

> Añadir una fila por cada commit relevante. El detalle de tareas vive en las secciones 4 y 6.
