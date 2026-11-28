# Guion de demostración con Kafka UI — heyPudú!

**Proyecto:** heyPudú!
**Propósito:** ejecutar la demostración de Kafka de principio a fin **desde la interfaz web** (Kafka UI), sin depender de la terminal salvo para arrancar la infraestructura.
**Duración total:** 15–20 minutos.
**Documento de referencia:** `KAFKA-IMPLEMENTACION.md` (§6 errores y DLT, §9 operación, §10 compose).

---

## 0. Preparación (antes de entrar a la sala)

| Paso | Acción |
|---|---|
| 1 | Arrancar las instancias: `aws ec2 start-instances --instance-ids i-09ea2f39fef85c88b i-05b808f859f54a876 i-0f42928aad2cef8bb --no-cli-pager` |
| 2 | Esperar 1–2 minutos a que los servicios estén sanos |
| 3 | Abrir el túnel SSH: `ssh -i backhp.pem -N -L 8090:localhost:8090 ec2-user@35.170.42.143` |
| 4 | Abrir http://localhost:8090 y verificar que el clúster **heypudu** aparece en verde |

Comprobación rápida de que todo está arriba (en la EC2 3):

```bash
cd heyPudu-backend
docker compose --env-file live-prod.env -f docker-compose.live.prod.yml ps
```

Se espera: `zookeeper` y ambos brokers `healthy`, `heypudu-kafka-ui` y los `ms-*` en `Up`.

**Dejar preparadas estas pestañas del navegador:**

1. `Topics` → `heypudu.posts.events`
2. `Topics` → `heypudu.posts.events.DLT`
3. `Consumers` → `posts-analytics-group`

---

## 1. Demostración A — un mensaje inválido acaba en el DLT (5 min)

**Qué se demuestra:** el consumidor detecta un payload inválido, no reintenta en vano, lo publica en el tópico de mensajes muertos y **libera la partición**.

### Pasos

| # | Dónde | Acción |
|---|---|---|
| 1 | `Topics` → `heypudu.posts.events` | Observar en **Overview** las 2 particiones con ISR `[1,2]` y anotar el **Next Offset** de cada una |
| 2 | Misma pantalla | Pulsar **Produce Message** (arriba a la derecha) |
| 3 | Diálogo | **Partition**: `-1` (automático) · **Key**: vacío · **Value Serde**: **`String`** · **Value**: `{}` |
| 4 | Diálogo | **Produce Message** (botón del diálogo) y esperar el aviso *Message successfully sent* |
| 5 | `Topics` → `heypudu.posts.events.DLT` | Pestaña **Messages** → pulsar **Submit** (la lupa) |
| 6 | Lista de mensajes | Aparece un mensaje nuevo en la partición donde se envió, con su offset |
| 7 | Mensaje | Clic en la fila → panel de detalle → pestaña **Headers** |
| 8 | `Consumers` → `posts-analytics-group` | **Total lag: 0** y el offset de esa partición avanzó |

> El serde debe ser **String**. Con otro serde el `{}` puede serializarse de otra forma y no provocar el error esperado.
>
> **Qué se ve como payload del DLT:** no es el `{}` literal, sino el registro ya deserializado y vuelto a serializar con `JsonSerializer` en el productor de mensajes muertos:
>
> ```json
> {"eventId":null,"eventType":null,"postId":null,"authorCognitoSub":null,"postType":null,"occurredAt":null,"schemaVersion":0}
> ```
>
> Son 123 bytes y es evidencia útil: muestra exactamente el objeto que llegó vacío. Si se quisiera conservar el byte original habría que usar `ByteArraySerializer` en ese productor.
>
> **Línea base:** el tópico puede tener mensajes de pruebas anteriores (el 27-11-2026 había 1 en la partición 0). Anota cuántos hay antes de empezar para no confundirlos con el nuevo.

### Qué mirar en las cabeceras del mensaje del DLT

| Header | Valor esperado | Qué prueba |
|---|---|---|
| `kafka_dlt-exception-fqcn` | `org.springframework.kafka.listener.ListenerExecutionFailedException` | El contenedor envolvió el fallo del listener |
| `kafka_dlt-exception-cause-fqcn` | `java.lang.IllegalArgumentException` | **La excepción real** que descartó el mensaje |
| `kafka_dlt-exception-message` | `Listener method '...PostEventListener.onEvent(...)' threw exception; Evento de publicacion invalido: falta eventId, postId o eventType` | El motivo, no solo el hecho |
| `kafka_dlt-exception-stacktrace` | traza completa con `Caused by: java.lang.IllegalArgumentException` | Permite depurar sin buscar en los logs |
| `kafka_dlt-original-topic` | `heypudu.posts.events` | Trazabilidad del origen |
| `kafka_dlt-original-partition` | `0` o `1` | Partición original (se muestra en binario) |

### Frase para la exposición

> "Un mensaje con payload inválido no se reintenta, porque reintentar un JSON roto no lo arregla nunca. Se publica en `.DLT` con la excepción adjunta en las cabeceras, se confirma el offset y la partición sigue avanzando. Sin esto, la partición quedaría bloqueada para siempre y los mensajes válidos posteriores no se procesarían."

---

## 2. Demostración B — un duplicado no se cuenta dos veces (3 min)

**Qué se demuestra:** idempotencia en el consumidor mediante `eventId`.

### Pasos

| # | Dónde | Acción |
|---|---|---|
| 1 | `Topics` → `heypudu.posts.events` | **Produce Message** con **Partition #0**, **Key**: `22222222-2222-2222-2222-222222222222`, **Value Serde: String** y este valor |

```json
{"eventId":"11111111-1111-1111-1111-111111111111","eventType":"POST_CREATED","postId":"22222222-2222-2222-2222-222222222222","authorCognitoSub":"33333333-3333-3333-3333-333333333333","postType":"AUDIO","occurredAt":"2026-11-27T12:00:00Z","schemaVersion":1}
```

| # | Dónde | Acción |
|---|---|---|
| 2 | Diálogo | Marcar **☑ Keep contents** y volver a pulsar **Produce Message** sin cambiar nada |
| 3 | `Topics` → `heypudu.posts.events` → **Overview** | El **Next Offset** de la partición 0 sube **+2** (se escriben los dos mensajes) |
| 4 | `Consumers` → `posts-analytics-group` | **Total lag: 0**: ambos se consumieron |
| 5 | Terminal | Ver el descarte por duplicado en el log (nivel `DEBUG` ya activo) |

```bash
docker logs --tail 200 heypudu-ms-analytics 2>&1 | grep -i duplicado
```

Salida esperada (una sola línea, no dos):

```text
DEBUG ... c.h.m.listener.PostEventListener : Evento de publicacion ignorado por duplicado | eventId=11111111-1111-1111-1111-111111111111
```

### Valores verificados en la ejecución del 27-11-2026

| Momento | Partición 0 | Grupo `posts-analytics-group` |
|---|---|---|
| Antes | Next Offset **2** | offset 2, LAG 0 |
| Después de los dos envíos | Next Offset **4** | offset 4, LAG 0 |
| Log | — | una única línea `ignorado por duplicado` |

### Frase para la exposición

> "Kafka garantiza al menos una entrega, no exactamente una. El segundo mensaje se consume, pero `processedEvents.putIfAbsent` lo descarta porque ya vio ese `eventId`. Por eso cada evento lleva identidad propia; sin esto, cada reenvío del productor inflaría el contador."

**Nota:** el contador también se puede consultar en `GET /api/v1/analytics/posts/stats`, pero exige un `idToken` de Cognito. Para la demo es más rápido y más claro el log, que muestra el descarte por `eventId`.

---

## 3. Demostración C — tolerancia a la caída de un broker (4 min)

**Qué se demuestra:** con `RF=2` y `min.insync.replicas=1` el clúster sigue aceptando escrituras con un broker menos.

### Pasos

| # | Dónde | Acción |
|---|---|---|
| 1 | `Topics` → `heypudu.posts.events` → **Overview** | Anotar: 2 particiones, ISR de 2 réplicas, *URP* = 0 |
| 2 | Terminal (único paso fuera de la interfaz) | `docker stop heypudu-broker1` |
| 3 | `Topics` → `heypudu.posts.events` → **Overview** | Refrescar: la ISR baja a **1** y *URP* = 1; el liderazgo de las particiones que estaban en el broker 1 pasa al broker 2 |
| 4 | `Topics` → `heypudu.posts.events` → **Produce Message** | Enviar un mensaje válido: **se acepta igual** |
| 5 | Terminal | `docker start heypudu-broker1` |
| 6 | **Overview** | La ISR vuelve a **2** y *URP* = 0 |

### Valores verificados en la ejecución del 27-11-2026

Estado inicial:

```text
Partition: 0  Leader: 2  Replicas: 2,1  Isr: 2,1
Partition: 1  Leader: 1  Replicas: 1,2  Isr: 2,1
```

Con `heypudu-broker1` detenido:

```text
Partition: 0  Leader: 2  Replicas: 2,1  Isr: 2      <- la réplica 1 salió del ISR
Partition: 1  Leader: 2  Replicas: 1,2  Isr: 2      <- el liderazgo se movió al broker 2
```

Publicación con un broker caído (el productor apunta a `broker1:9092,broker2:9092`):

```text
WARN Couldn't resolve server broker1:9092 from bootstrap.servers as DNS
     resolution failed for broker1  ->  el cliente continúa con el broker 2
heypudu.posts.events:0:5      <- el mensaje se escribió igual
posts-analytics-group partition 0: CURRENT-OFFSET 5 = LOG-END-OFFSET 5, LAG 0
```

Tras `docker start heypudu-broker1`:

```text
Partition: 0  Leader: 2  Replicas: 2,1  Isr: 2,1
Partition: 1  Leader: 2  Replicas: 1,2  Isr: 2,1
```

> El liderazgo de las particiones no vuelve solo al broker original de inmediato: Kafka lo reequilibra con `auto.leader.rebalance` (cada 5 minutos). Lo que importa para la demo es que la **ISR vuelve a 2**.

### Frase para la exposición

> "Kafka UI no puede apagar procesos, pero sirve para ver el efecto: con un broker caído la réplica se queda fuera del ISR, y como `min.insync.replicas` es 1, la publicación no se bloquea. El cliente ni siquiera falla: registra un WARN porque no resuelve `broker1` y sigue con el broker 2. Al volver el broker, se resincroniza solo."

---

## 4. Demostración D (opcional) — releer el histórico (3 min)

**Qué se demuestra:** los eventos se pueden reprocesar; una cola clásica no permite esto.

| # | Dónde | Acción |
|---|---|---|
| 1 | Terminal | `docker stop heypudu-ms-analytics` (un grupo con miembros activos no permite reiniciar offsets) |
| 2 | `Consumers` → `posts-analytics-group` | Menú del grupo (**⋮**) → **Reset offsets** → elegir el tópico → *Earliest* |
| 3 | Terminal | `docker start heypudu-ms-analytics` |
| 4 | `Consumers` → `posts-analytics-group` | El LAG sube y baja a 0 mientras se reprocesa todo el tópico |

**Cuándo usarlo:** solo si sobra tiempo. Reiniciar offsets es irreversible para ese grupo.

---

## 5. Resumen de evidencias

| Demostración | Evidencia en pantalla | Requisito que cubre |
|---|---|---|
| A | `{}` en `heypudu.posts.events.DLT` + cabeceras con la excepción + LAG 0 | Manejo de errores con reintentos y tópico de mensajes muertos |
| B | Dos offsets consumidos y una sola línea `ignorado por duplicado` en el log | Idempotencia del consumidor por `eventId` |
| C | ISR de 2 a 1 y de vuelta, con publicación exitosa y WARN del cliente | Replicación (`RF=2`) y disponibilidad |
| D | LAG sube y vuelve a 0 tras reiniciar offsets | Retención y reprocesamiento |

---

## 6. Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| La pestaña **Messages** aparece vacía | La consulta no se ha ejecutado | Pulsar **Submit** (la lupa) y elegir *Oldest First* |
| `Produce Message` da error de serialización | Serde distinto de `String` | Cambiar **Value Serde** a `String` |
| El mensaje no aparece en el DLT | Todavía no se consumió | Esperar 1–2 s, refrescar; revisar `docker logs --tail 30 heypudu-ms-analytics` |
| La interfaz no carga en `localhost:8090` | Túnel cerrado o instancia detenida | Relanzar el `ssh -L`; verificar `docker ps` en la EC2 |
| `ssh: connect to host ... port 22: Connection timed out` | La IP doméstica cambió y `heypudu-live-sg` solo permite la anterior, o la instancia está detenida | Ver la IP con `https://checkip.amazonaws.com`, actualizar la regla `22` del SG y volver a intentar. Tras cortes de internet conviene relanzar el túnel con `-o ServerAliveInterval=30` |
| No aparece el clúster en la barra lateral | Los brokers aún arrancan | Esperar al `healthy` de `zookeeper` y ambos brokers |

---

## 7. Advertencias

1. **No usar "Purge messages"** en `heypudu.posts.events` ni en `heypudu.live.events`: borra el histórico y deja sin evidencia el resto de la exposición.
2. La interfaz corre con `DYNAMIC_CONFIG_ENABLED: "true"`: permite producir, borrar y purgar. Está publicada **solo en `127.0.0.1:8090`**, accesible por túnel; no abrirla al ALB sin autenticación.
3. Los contadores de `ms-analytics` están **en memoria**: se reinician si se reinicia el servicio (útil para el paso D, pero conviene decirlo si preguntan).
4. Al terminar, cerrar el túnel (`Ctrl+C`) y detener las instancias si no se van a usar.

---

## 8. Anexo — equivalentes por terminal

```bash
# Publicar el mensaje inválido
echo '{}' | docker exec -i heypudu-broker1 kafka-console-producer \
  --bootstrap-server broker1:9092 --topic heypudu.posts.events

# Leer el DLT
docker exec heypudu-broker1 kafka-console-consumer --bootstrap-server broker1:9092 \
  --topic heypudu.posts.events.DLT --from-beginning --max-messages 1

# Estado del grupo y LAG
docker exec heypudu-broker1 kafka-consumer-groups --bootstrap-server broker1:9092 \
  --describe --group posts-analytics-group

# ISR por partición
docker exec heypudu-broker1 kafka-topics --bootstrap-server broker1:9092 \
  --describe --topic heypudu.posts.events
```

---

## 9. Registro de cambios

| Fecha | Cambio |
|---|---|
| 27-11-2026 | Creación del guion con las cuatro demostraciones, evidencias y resolución de problemas. |
