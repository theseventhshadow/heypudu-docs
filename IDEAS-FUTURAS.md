# Ideas futuras — heyPudú!

**Proyecto:** heyPudú!
**Versión del documento:** 1.0
**Fecha:** 23-11-2026
**Estado de referencia:** EP5 desplegada (Kafka con ZooKeeper y dos brokers, `heypudu.live.events` y `heypudu.posts.events` con DLT, `ms-live`, `ms-analytics`, `ms-kafka-admin`, MediaMTX con TLS, pantallas de salas en vivo operativas con F4/F5 parciales).
**Propósito:** reunir funcionalidades y mejoras que no forman parte del alcance entregado, con su esfuerzo, impacto y dependencias, para decidir qué construir después de la demo.

> **Este documento no es un plan de ejecución.** Cuando una idea se apruebe, se convierte en fases dentro de su documento correspondiente (`PLAN-IMPLEMENTACION-KAFKA.md` si toca mensajería) y su estado se refleja en `estado-proyecto-heypudu.txt`..

## Leyenda

| Marca | Significado |
|---|---|
| `[IDEA]` | Propuesta sin aprobar ni estimar en detalle. |
| **S** | Hasta 1 día de trabajo. |
| **M** | 2 a 5 días. |
| **L** | 1 a 2 semanas o más. |
| **Impacto** | Valor percibido por el usuario o por la evaluación. |

## 1. Resumen priorizado

| # | Idea | Línea | Esfuerzo | Impacto | Reutiliza |
|---|---|---|---|---|---|
| 1 | PWA y controles de reproducción del sistema | Producto | S | Alto | Reproductor global |
| 2 | Continuar escuchando y temporizador | Producto | S | Medio | Reproductor global |
| 3 | Hashtags y páginas de tema | Descubrimiento | S/M | Medio | Feed y búsqueda |
| 4 | Tarjetas para compartir (Open Graph) | Crecimiento | S | Medio | Rutas actuales |
| 5 | Insignias por hitos | Retención | S/M | Medio | Kafka (`POST_CREATED`, `user.followed`) |
| 6 | En tendencia con ventanas temporales | Descubrimiento | M | Alto | Kafka Streams/ksqlDB, `ms-analytics` |
| 7 | Panel del creador | Creador | M | Alto | `live_events_audit` |
| 8 | Salas programadas | Creador | M | Medio | RabbitMQ y notificaciones |
| 9 | Grabar la sala y publicarla | Creador | M | Alto | MediaMTX, `room.closed`, `ms-posts` |
| 10 | Notificaciones en tiempo real | Producto | M | Medio | Notificaciones y SSE |
| 11 | Moderación en vivo de la sala | Moderación | M | Medio | `ms-live` |
| 12 | Comentarios de voz | Producto | M/L | Medio | URLs prefirmadas de audio |
| 13 | Transcripción y búsqueda por contenido | Descubrimiento | L | Alto | S3, evento `POST_CREATED` |
| 14 | Co-conductores en salas | Creador | L | Alto | MediaMTX (requiere mezclador) |
| 15 | Recomendación personalizada | Descubrimiento | L | Alto | Kafka, eventos de reproducción nuevos |
| 16 | Propinas o suscripciones | Monetización | L | Alto | Fuera del alcance académico |
| 17 | Kafka Streams para tendencias | Plataforma | S/M | Alto | Kafka |
| 18 | Patrón outbox | Plataforma | M | Medio | `ms-posts`, `ms-live` |
| 19 | Reproducción histórica de eventos | Plataforma | S/M | Medio | Retención de 7 días |
| 20 | Pruebas de caos y failover | Plataforma | S | Alto | `RF=2`, DLT |
| 21 | Schema Registry y contratos versionados | Plataforma | M | Medio | Kafka |
| 22 | Productor idempotente y transacciones | Plataforma | S | Medio | Kafka |
| 23 | Observabilidad con métricas y trazas | Plataforma | M | Alto | Actuator, Micrometer |
| 24 | Rate limiting por usuario | Plataforma | S/M | Medio | API y microservicios |
| 25 | Tests y CI/CD | Calidad | M | Alto | Deuda ya registrada |
| 26 | Seguridad de endpoints internos | Seguridad | S | Alto | API Gateway, Cognito |

---

## 2. Ganancias rápidas

### 2.1 PWA y controles del sistema `[IDEA]` — S

**Qué es:** instalar la web como aplicación, reproducir audio con la pantalla bloqueada y controlar desde la barra del sistema.

**Por qué encaja:** el reproductor global ya existe; el salto de calidad percibida es inmediato y no toca backend.

**Alcance:** `manifest.json`, service worker, `navigator.mediaSession` (`play`, `pause`, `seekbackward`, `seekforward`), iconos y pantalla de instalación.

**Criterio de aceptación:** el audio sigue sonando al bloquear el móvil y los controles del sistema funcionan; la app es instalable.

### 2.2 Continuar escuchando y temporizador `[IDEA]` — S

**Qué es:** recordar la posición de cada audio y ofrecer "reanudar"; detener la reproducción tras 5, 15 o 30 minutos.

**Alcance:** `localStorage` por `postId`, barra de progreso reanudable y selector de temporizador en el reproductor.

**Criterio de aceptación:** al volver a un audio se ofrece continuar desde el segundo guardado; el temporizador detiene el audio.

### 2.3 Hashtags y páginas de tema `[IDEA]` — S/M

**Qué es:** etiquetar publicaciones y navegar por tema (`/tema/:tag`).

**Alcance:** extracción de etiquetas al crear el post, tablas `hashtags` y `post_hashtags` (migración nueva en `heypudu_posts`), endpoint de listado y filtro en el feed.

**Criterio de aceptación:** una etiqueta agrupa publicaciones de varios autores y se puede seguir desde el buscador.

### 2.4 Tarjetas para compartir (Open Graph) `[IDEA]` — S

**Qué es:** que un enlace a un briefcast o a una sala muestre título, autor y portada al compartirlo.

**Alcance:** metadatos por ruta y una imagen por defecto; si se quiere imagen dinámica, una función serverless en Vercel.

**Criterio de aceptación:** el enlace se previsualiza correctamente en WhatsApp, X y Discord.

### 2.5 Insignias por hitos `[IDEA]` — S/M

**Qué es:** reconocimientos visibles en el perfil (primer audio, 10 seguidores, primera sala, 100 reacciones recibidas).

**Por qué encaja:** es el ejemplo más claro de un consumidor de Kafka nuevo sin tocar los existentes.

**Alcance:** grupo `achievements-group` sobre `heypudu.posts.events` y los eventos de follows; tabla `user_badges`; entrega idempotente por `eventId`.

**Criterio de aceptación:** un usuario recibe la insignia una sola vez aunque el evento se reprocese.

---

## 3. Mejoras medianas

### 3.1 En tendencia con ventanas temporales `[IDEA]` — M

**Qué es:** ranking de salas y audios por reacciones y oyentes en ventanas de 1, 5 y 60 minutos.

**Por qué encaja:** convierte los eventos que ya se publican en un producto visible y demuestra procesamiento con estado.

**Alcance:** topología de Kafka Streams (o ksqlDB) con ventanas `tumbling` y `suppress`, almacén materializado y endpoint `/api/v1/analytics/trending`; la UI muestra "En tendencia" en el feed.

**Criterio de aceptación:** una ráfaga de reacciones aparece en la ventana de 1 minuto y decae sola al pasar la ventana.

### 3.2 Panel del creador `[IDEA]` — M

**Qué es:** métricas históricas de sus salas y audios: oyentes máximos, reacciones por minuto, duración media y horarios con más audiencia.

**Alcance:** endpoints de agregación sobre `heypudu_analytics.live_events_audit`, gráficos en React y exportación CSV opcional.

**Criterio de aceptación:** tras una sala de prueba, el panel muestra las cifras que ya reporta `/stats` y su histórico.

### 3.3 Salas programadas `[IDEA]` — M

**Qué es:** anunciar una sala con fecha y hora, con cuenta atrás y aviso al comenzar.

**Alcance:** estado `SCHEDULED` en `ms-live`, `scheduledAt`, planificador, notificación a seguidores reutilizando RabbitMQ y evento `ROOM_SCHEDULED`.

**Criterio de aceptación:** los seguidores reciben el aviso y la sala pasa a `LIVE` a la hora indicada.

### 3.4 Grabar la sala y publicarla `[IDEA]` — M

**Qué es:** al cerrar una sala, conservar el audio y ofrecerlo como publicación.

**Alcance:** grabación de MediaMTX, subida a S3 y creación de post mediante el endpoint interno de `ms-posts`; la UI pide confirmación antes de publicar.

**Criterio de aceptación:** una sala de prueba genera un audio reproducible en el feed con la duración correcta.

### 3.5 Notificaciones en tiempo real `[IDEA]` — M

**Qué es:** campana con contador actualizado sin recargar.

**Alcance:** endpoint SSE en `ms-users`, emisión al persistir una notificación y reconexión con `Last-Event-ID`; respaldo por sondeo.

**Criterio de aceptación:** al crear una sala de un usuario seguido, el seguidor ve el aviso en menos de dos segundos.

### 3.6 Moderación en vivo `[IDEA]` — M

**Qué es:** chat de sala y acciones del creador: silenciar, expulsar y filtrar palabras.

**Alcance:** chat por SSE o WebSocket, lista de expulsados en memoria o base de datos, y validación de que solo el creador modera. El audio sigue en MediaMTX.

**Criterio de aceptación:** un oyente expulsado pierde el acceso al chat y al `read` del WHEP.

### 3.7 Comentarios de voz `[IDEA]` — M/L

**Qué es:** responder a un briefcast con audio corto.

**Alcance:** reutiliza las URLs prefirmadas de audio, límite de 60 segundos, transcodificación y las mismas reglas de moderación. Suma almacenamiento y reportes.

**Criterio de aceptación:** un comentario de voz se reproduce en el hilo y puede reportarse y eliminarse.

---

## 4. Ideas ambiciosas

### 4.1 Transcripción y búsqueda por contenido `[IDEA]` — L

**Qué es:** encontrar un audio por lo que se dice, no solo por el título.

**Alcance:** trabajo asíncrono disparado por `POST_CREATED`, transcripción (AWS Transcribe o Whisper en una instancia aparte), almacenamiento del texto e índice `tsvector` en PostgreSQL.

**Coste y riesgo:** pago por minuto de audio; el modelo autoalojado no cabe en la instancia actual. Empezar solo con los audios nuevos, no con el histórico.

**Criterio de aceptación:** una frase dicha en un audio aparece en los resultados de búsqueda.

### 4.2 Co-conductores en salas `[IDEA]` — L

**Qué es:** dos o más personas conduciendo la misma sala.

**Restricción técnica:** MediaMTX **reenvía** pero **no mezcla** audio. Publicar dos pistas en el mismo path no produce una mezcla; haría falta un mezclador (FFmpeg, Janus o similar) o un path por invitado y mezcla en el cliente.

**Alcance:** invitaciones, autorización de `publish` para varios usuarios y la capa de mezcla. Es un cambio de arquitectura del SFU, no un ajuste.

**Criterio de aceptación:** dos emisores se escuchan entre sí y el oyente recibe una sola pista mezclada.

### 4.3 Recomendación personalizada `[IDEA]` — L

**Qué es:** feed ordenado por afinidad y no solo por fecha.

**Requisito previo:** hoy no se registran eventos de reproducción. Sin señal de escucha no hay recomendación posible.

**Alcance:** evento `POST_PLAYED`, agregados por usuario, similitud por co-escucha y un job periódico que materialice el orden del feed.

**Criterio de aceptación:** dos usuarios con gustos distintos reciben feeds medibles y distintos.

### 4.4 Propinas o suscripciones `[IDEA]` — L

**Qué es:** apoyar económicamente a un creador.

**Por qué queda fuera:** implica pasarela de pagos, cumplimiento, impuestos y soporte. No aporta a la evaluación y añade riesgo legal.

---

## 5. Ideas centradas en Kafka

### 5.1 Kafka Streams o ksqlDB para tendencias `[IDEA]` — S/M

Agregaciones por ventana con estado y `suppress`, tal como se describe en 3.1. Es el complemento académico más directo a lo ya construido: hoy hay productores y consumidores, pero no procesamiento con estado.

### 5.2 Patrón outbox `[IDEA]` — M

**Problema:** si la base de datos confirma y Kafka falla, el evento se pierde; si Kafka confirma y la transacción falla, se publica un evento falso.

**Solución:** tabla `outbox` en la misma transacción y un publicador que la vacía con reintentos e idempotencia.

**Criterio de aceptación:** con el broker caído, la publicación se crea y el evento sale al recuperarse, sin duplicados.

### 5.3 Reproducción histórica `[IDEA]` — S/M

Un grupo de consumo nuevo con `auto.offset.reset=earliest` que reconstruye métricas desde el inicio del tópico. Aprovecha la retención de 7 días y sirve como demostración de la diferencia frente a RabbitMQ.

### 5.4 Pruebas de caos y failover `[IDEA]` — S

Apagar un broker y verificar que la producción y el consumo continúan con `RF=2`; publicar un mensaje inválido y comprobar su llegada a `.DLT`; reiniciar un consumidor y confirmar idempotencia por `eventId`.

**Criterio de aceptación:** informe breve con los tres escenarios y su evidencia.

### 5.5 Schema Registry y contratos versionados `[IDEA]` — M

**Problema:** los DTO se comparten por JSON sin contrato formal; un cambio de campo rompe consumidores.

**Solución:** Registry con Avro o JSON Schema y compatibilidad hacia atrás. Es la evolución natural del `schemaVersion` que ya llevan los eventos.

### 5.6 Productor idempotente y transacciones `[IDEA]` — S

Activar `enable.idempotence` y, si se adopta 5.2, transacciones `consume-process-produce` para el consumidor que reinyecta eventos.

---

## 6. Plataforma y calidad

### 6.1 Observabilidad `[IDEA]` — M

Micrometer + Prometheus + Grafana con paneles por servicio, latencia del feed, lag de los grupos de consumo y salud de MediaMTX. Añadir un identificador de correlación en logs. Es la mejora con mejor relación esfuerzo/impresión en una revisión técnica.

### 6.2 Rate limiting `[IDEA]` — S/M

Límites por usuario en reacciones, reportes y creación de salas (por ejemplo, con Bucket4j y Redis, o un filtro en memoria por instancia). Evita abuso y protege la instancia.

### 6.3 Tests y CI/CD `[IDEA]` — M

Sigue pendiente y es la deuda de mayor riesgo: solo `ms-users` tiene pruebas y los cuatro workflows están vacíos. Testcontainers para PostgreSQL y Kafka, matriz de build por servicio y publicación de imágenes.

### 6.4 Seguridad de endpoints internos `[IDEA]` — S

Token de servicio con `client_credentials`, rol dedicado y bloqueo de `/api/v1/internal/**` en API Gateway. Ya está registrado como pendiente en `estado-proyecto-heypudu.txt` (3.1).

---

## 7. Recomendación para el cierre inmediato

Con la demo encima, el orden con mejor retorno es:

1. **PWA y Media Session** (S): calidad percibida inmediata, cero backend.
2. **En tendencia con ventana temporal** (M): hace visible Kafka más allá del evento crudo y se explica en una frase.
3. **Panel del creador con dos gráficos** (M): reutiliza `ms-analytics` y demuestra que los datos ya guardados sirven para algo.

Todo lo demás debería quedar documentado como trabajo futuro. Intentar una idea L antes de la entrega resta tiempo a la estabilidad y a la evidencia de la EP5.

## 8. Descartadas

| Idea | Motivo |
|---|---|
| Detección automática de copyright | Requiere un catálogo licenciado (Content ID, Audible Magic); un clasificador no prueba titularidad. Coste y falsos positivos altos. Se evaluó el 23-11-2026 y se descartó. |
| Publicaciones de texto | Descartado por el equipo: la red es solo de audio. |
| Monetización con pagos | Fuera del alcance académico y con carga legal. |

## 9. Registro de cambios

| Fecha | Cambio |
|---|---|
| 23-11-2026 | Creación del documento con 26 ideas, estimaciones y recomendación de cierre. |
