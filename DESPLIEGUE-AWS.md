# heyPudú! — Despliegue en AWS

Registro de la infraestructura y configuración realizada para desplegar el proyecto.

> **Seguridad:** este documento no contiene contraseñas, tokens ni cadenas de conexión completas.
> Los secretos reales viven únicamente en el archivo `.env` de la instancia EC2, que está excluido de Git.

---

## 1. Arquitectura desplegada

```
Frontend (Vercel)
        │  HTTPS + JWT (Cognito)
        ▼
API Gateway HTTP API  (f02rmdid97)
        │
        ▼
Application Load Balancer  (heypudu-alb)
        │  HTTP :8081-:8085 (red privada)
        ▼
EC2  (Docker Compose, 5 contenedores)
  ├── ms-auth          :8081
  ├── ms-users         :8082
  ├── ms-posts         :8083
  ├── ms-interactions  :8084
  └── ms-heypudu-rabbit-admin :8085
        │
        ▼
Neon PostgreSQL (externo, SSL)     +     AWS S3 (audio, portadas, avatares)

EC2 RabbitMQ (Docker Compose, red privada)
  ├── rabbit1           :5672
  └── rabbit2           :5672

La EC2 backend se conecta a RabbitMQ mediante la IP privada o DNS privado de
la EC2 RabbitMQ. RabbitMQ no comparte la red Docker de la EC2 backend.
```

---

## 2. Cuenta y región

| Elemento | Valor |
|---|---|
| Cuenta | AWS Academy (VocLabs) |
| Región | `us-east-1` |
| Limitación | `rds:CreateDBInstance` denegado por política `Pvoclabs2` |

### Consecuencia

No fue posible usar Amazon RDS. Se optó por **Neon PostgreSQL** como base de datos
administrada externa, manteniendo el diseño de *database-per-service* mediante
**schemas separados** dentro de una misma base.

---

## 3. Base de datos — Neon PostgreSQL

| Elemento | Valor |
|---|---|
| Proveedor | Neon |
| Host | `ep-holy-dew-b7vpg1u6-pooler.c-13.us-east-1.aws.neon.tech` |
| Puerto | `5432` |
| Base de datos | `neondb` |
| Usuario | `neondb_owner` |
| SSL | `sslmode=require` |

### Schemas por microservicio

| Microservicio | Schema |
|---|---|
| `ms-auth` | `heypudu_auth` |
| `ms-users` | `heypudu_users` |
| `ms-posts` | `heypudu_posts` |
| `ms-interactions` | `heypudu_interactions` |

### Formato de URL JDBC utilizado

```
jdbc:postgresql://HOST/neondb?sslmode=require&channel_binding=require&currentSchema=heypudu_auth
```

Cada microservicio usa la misma URL cambiando únicamente `currentSchema`.

Los schemas y tablas **no se crean manualmente**: Flyway los genera al arrancar
cada contenedor (`baseline-on-migrate: true`).

### Migraciones existentes

| Microservicio | Migraciones |
|---|---|
| `ms-auth` | `V1__init_auth_schema.sql` |
| `ms-users` | `V1__init_users-schema.sql`, `V2__init_follows_table.sql`, `V3__init_notifications_table.sql` |
| `ms-posts` | `V1__init_posts_schema.sql`, `V2__allow_audio_description.sql`, `V3__init_post_reports.sql`, `V4__allow_repeat_reports.sql`, `V5__add_author_name.sql` |
| `ms-interactions` | `V1__init_likes_table.sql`, `V2__init_comments_table.sql`, `V3__init_comment_reports.sql`, `V4__allow_repeat_reports.sql` |

> Flyway advierte que PostgreSQL 18.6 (Neon) es más nuevo que la versión soportada (17).
> Es solo una advertencia: las migraciones se aplican correctamente.

> En producción `logging.level.root` es `WARN`, así que los mensajes `INFO` de Flyway
> (`Migrating schema ...`) **no aparecen** en los logs. Solo se ve la advertencia de
> versión. Un arranque estable con `ddl-auto: validate` es la prueba de que la
> migración se aplicó: si faltara una columna mapeada, Hibernate abortaría el arranque.

---

## 4. Instancia EC2

| Elemento | Valor |
|---|---|
| AMI | Amazon Linux 2023 |
| Tipo | `t3.small` |
| Almacenamiento | 30 GB gp3 |
| Acceso | SSH con key pair `.pem`, usuario `ec2-user` |
| IP | IP privada + Elastic IP para administración |

### Puertos del Security Group de la EC2

| Puerto | Origen | Uso |
|---|---|---|
| `22` | IP del administrador | SSH |
| `8081` | SG del ALB | `ms-auth` |
| `8082` | SG del ALB | `ms-users` |
| `8083` | SG del ALB | `ms-posts` |
| `8084` | SG del ALB | `ms-interactions` |
| `8085` | SG del ALB | `ms-heypudu-rabbit-admin` |

Los puertos `8081–8084` **no** están abiertos a Internet.

### Security Group de la EC2 RabbitMQ

La EC2 RabbitMQ usa un Security Group separado. El acceso se limita así:

| Puerto | Origen | Uso |
|---|---|---|
| `5672` | Security Group `backend` (`sg-03921fd5c90ae52ec`) | AMQP desde los microservicios |
| `4369` | Solo comunicación interna de la EC2 RabbitMQ | Descubrimiento Erlang |
| `25672` | Solo comunicación interna de la EC2 RabbitMQ | Distribución del clúster |
| `15672` | No se expone públicamente | RabbitMQ Management mediante túnel SSH |

Como la IP pública de AWS Academy puede cambiar, la interfaz Management no se
autoriza por una IP fija ni se abre a Internet. La EC2 RabbitMQ no necesita
Elastic IP. La administración inicial se realizará mediante AWS Systems
Manager Session Manager, usando un IAM Role con
`AmazonSSMManagedInstanceCore`.

Para acceder a Management desde el equipo local, se crea un túnel SSH a
través de la EC2 backend:

```bash
ssh -i clave.pem -L 15672:<IP_PRIVADA_RABBITMQ>:15672 ec2-user@<IP_PUBLICA_BACKEND>
```

Luego se abre `http://localhost:15672` en el equipo local.

La alternativa para administrar la instancia sin SSH directo es Session
Manager; no se abre el puerto `22` públicamente para RabbitMQ.

### Instalación de Docker

```bash
sudo dnf update -y
sudo dnf install -y docker
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
```

Tras `usermod`, es necesario cerrar y reabrir la sesión SSH.

### Instalación manual de Docker Compose

La imagen de Amazon Linux 2023 no incluía Compose; se instaló como plugin del CLI:

```bash
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version
```

Resultado: `Docker Compose version v5.6.1`.

> Esta versión **no soporta** `docker compose --env-file`. Se usa el archivo `.env`
> automático en el directorio del proyecto.

---

## 5. Código en la EC2

```bash
cd ~
git clone https://github.com/theseventhshadow/heyPudu-backend.git
cd heyPudu-backend
```

Archivos relevantes del repositorio:

| Archivo | Propósito |
|---|---|
| `docker-compose.prod.yml` | Ejecución de los 5 microservicios en producción |
| `docker-compose.yml` | Entorno local con PostgreSQL en contenedor |
| `.env.production.example` | Plantilla de variables (sin secretos) |
| `.gitignore` | Excluye `.env` y `.env.production` |
| `init-db.sql` | Inicialización de la BD local |

---

## 6. Imágenes Docker

Se decidió **compilar fuera de EC2** para no consumir CPU/RAM de la instancia
(`t3.small`) y reducir tiempos de despliegue.

### Registro

Docker Hub, usuario `unalmaermitana`.

| Imagen | Microservicio |
|---|---|
| `unalmaermitana/heypudu-ms-auth:latest` | `ms-auth` |
| `unalmaermitana/heypudu-ms-users:latest` | `ms-users` |
| `unalmaermitana/heypudu-ms-posts:latest` | `ms-posts` |
| `unalmaermitana/heypudu-ms-interactions:latest` | `ms-interactions` |
| `unalmaermitana/heypudu-ms-heypudu-rabbit-admin:latest` | `ms-heypudu-rabbit-admin` |

### Build y push (desde el equipo local)

```bash
cd C:\Users\angel\Documents\Proyectos\heypudu\heyPudu-backend

docker login

docker build -t unalmaermitana/heypudu-ms-auth:latest ./ms-auth
docker build -t unalmaermitana/heypudu-ms-users:latest ./ms-users
docker build -t unalmaermitana/heypudu-ms-posts:latest ./ms-posts
docker build -t unalmaermitana/heypudu-ms-interactions:latest ./ms-interactions
docker build -t unalmaermitana/heypudu-ms-heypudu-rabbit-admin:latest ./ms-heypudu-rabbit-admin

docker push unalmaermitana/heypudu-ms-auth:latest
docker push unalmaermitana/heypudu-ms-users:latest
docker push unalmaermitana/heypudu-ms-posts:latest
docker push unalmaermitana/heypudu-ms-interactions:latest
docker push unalmaermitana/heypudu-ms-heypudu-rabbit-admin:latest
```

> Los `Dockerfile` de cada microservicio usan build multi-stage con
> `eclipse-temurin:25-jdk` y `eclipse-temurin:25-jre`, usuario no root y `EXPOSE` propio.

### Despliegue en EC2

```bash
cd ~/heyPudu-backend
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml ps
```

---

## 7. Variables de entorno en EC2

Archivo: `~/heyPudu-backend/.env`

### Base de datos

```env
DB_URL_AUTH=jdbc:postgresql://HOST/neondb?sslmode=require&channel_binding=require&currentSchema=heypudu_auth
DB_URL_USERS=jdbc:postgresql://HOST/neondb?sslmode=require&channel_binding=require&currentSchema=heypudu_users
DB_URL_POSTS=jdbc:postgresql://HOST/neondb?sslmode=require&channel_binding=require&currentSchema=heypudu_posts
DB_URL_INTERACTIONS=jdbc:postgresql://HOST/neondb?sslmode=require&channel_binding=require&currentSchema=heypudu_interactions

DB_USERNAME_AUTH=neondb_owner
DB_USERNAME_USERS=neondb_owner
DB_USERNAME_POSTS=neondb_owner
DB_USERNAME_INTERACTIONS=neondb_owner

DB_PASSWORD_AUTH=<secreto>
DB_PASSWORD_USERS=<secreto>
DB_PASSWORD_POSTS=<secreto>
DB_PASSWORD_INTERACTIONS=<secreto>
```

### Cognito

```env
AWS_REGION=us-east-1
COGNITO_USER_POOL_ID=<user-pool-id>
COGNITO_ISSUER_URI=https://cognito-idp.us-east-1.amazonaws.com/<user-pool-id>
COGNITO_JWK_SET_URI=https://cognito-idp.us-east-1.amazonaws.com/<user-pool-id>/.well-known/jwks.json
```

### S3

```env
S3_AVATARS_BUCKET=<bucket-avatars>
S3_AUDIO_BUCKET=<bucket-audio>
S3_COVERS_BUCKET=<bucket-covers>
```

### Comunicación interna

Definida en `docker-compose.prod.yml`, no en `.env`:

| Variable | Valor |
|---|---|
| `CLIENTS_USERS_BASE_URL` (auth) | `http://ms-users:8082` |
| `CLIENTS_AUTH_BASE_URL` (users) | `http://ms-auth:8081` |
| `CLIENTS_POSTS_BASE_URL` (users) | `http://ms-posts:8083` |
| `CLIENTS_USERS_BASE_URL` (posts) | `http://ms-users:8082` |
| `CLIENTS_INTERACTIONS_BASE_URL` (posts) | `http://ms-interactions:8084` |
| `CLIENTS_POSTS_BASE_URL` (interactions) | `http://ms-posts:8083` |
| `RABBITMQ_HOST` | IP o DNS privado de la EC2 RabbitMQ |
| `RABBIT_USER` / `RABBIT_PASSWORD` | Credenciales del vhost RabbitMQ |
| `RABBIT_VHOST` | `/` por defecto |

Todos los servicios usan `SPRING_PROFILES_ACTIVE=prod`.

### Acceso a S3

Se recomienda asignar un **IAM Role** a la instancia EC2 con permisos mínimos sobre
los tres buckets, en lugar de guardar claves AWS en variables de entorno.

---

## 8. Docker Compose de producción

Archivo: `docker-compose.prod.yml`

Características:

- Descarga imágenes desde Docker Hub (no compila).
- No incluye PostgreSQL.
- Publica los puertos `8081–8085` para el ALB.
- Red interna dedicada: `heypudu-internal`.
- `restart: unless-stopped`.
- Variables sensibles resueltas desde `.env`.

---

## 9. Application Load Balancer

| Elemento | Valor |
|---|---|
| Nombre | `heypudu-alb` |
| Tipo | Application Load Balancer |
| Scheme | Internet-facing |
| IP type | IPv4 |
| Listener | HTTP :80 |
| DNS | `heypudu-alb-201143386.us-east-1.elb.amazonaws.com` |
| Security Group | `heypudu-alb-sg` |

### Security Group del ALB

| Puerto | Origen |
|---|---|
| `80` | `0.0.0.0/0` |

### Target groups

| Nombre | Puerto | Health check | Estado |
|---|---|---|---|
| `heypudu-auth-tg` | `8081` | `/actuator/health` | Healthy |
| `heypudu-users-tg` | `8082` | `/actuator/health` | Healthy |
| `heypudu-posts-tg` | `8083` | `/actuator/health` | Healthy |
| `heypudu-interactions-tg` | `8084` | `/actuator/health` | Healthy |
| `heypudu-rabbit-admin-tg` | `8085` | `/actuator/health` | Healthy |

Tipo: **Instances**, protocolo HTTP, registrando la EC2 en el puerto correspondiente.

### Reglas del listener HTTP:80

| Prioridad | Path | Target group |
|---|---|---|
| 1 | `/api/v1/posts/*/likes` | `heypudu-interactions-tg` |
| 2 | `/api/v1/posts/*/comments` | `heypudu-interactions-tg` |
| 3 | `/api/v1/users/me/likes` | `heypudu-interactions-tg` |
| 4 | `/api/v1/comments/*/reports` | `heypudu-interactions-tg` |
| 5 | `/api/v1/admin/comment-reports` | `heypudu-interactions-tg` |
| 6 | `/api/v1/admin/comment-reports/*` | `heypudu-interactions-tg` |
| 7 | `/api/v1/admin/comments/*` | `heypudu-interactions-tg` |
| 8 | `/api/v1/admin/posts/*` | `heypudu-posts-tg` |
| 9 | `/api/v1/admin/users/*` | `heypudu-users-tg` |
| 10 | `/api/v1/admin/rabbit/*` | `heypudu-rabbit-admin-tg` |
| 15 | `/api/v1/posts` | `heypudu-posts-tg` |
| 20 | `/api/v1/users/*` | `heypudu-users-tg` |
| 30 | `/api/v1/posts/*` | `heypudu-posts-tg` |
| 40 | `/api/v1/comments/*` | `heypudu-interactions-tg` |
| 50 | `/api/v1/auth/*` | `heypudu-auth-tg` |
| default | — | `heypudu-auth-tg` |

Reglas aprendidas:

- En el ALB, **número menor = mayor prioridad**. Las reglas específicas deben
  evaluarse antes que las generales.
- `POST /api/v1/posts` (crear publicación) usa la ruta exacta `/api/v1/posts`,
  que **no coincide** con `/api/v1/posts/*`. Requiere una regla propia.
- `/api/v1/users/by-cognito/*/avatar` queda cubierta por `/api/v1/users/*`.
- Las llamadas entre microservicios usan nombres de Docker (`http://ms-users:8082`),
  por lo que no pasan por el ALB.

---

## 10. API Gateway

| Elemento | Valor |
|---|---|
| Tipo | HTTP API |
| ID | `f02rmdid97` |
| Región | `us-east-1` |
| URL base | `https://f02rmdid97.execute-api.us-east-1.amazonaws.com` |
| Integración | HTTP URI → ALB |

### Rutas

Se usa **una sola ruta comodín**:

```text
ANY /{proxy+}
```

Con la integración:

```text
http://heypudu-alb-201143386.us-east-1.elb.amazonaws.com/{proxy}
```

Y el parameter mapping:

```text
proxy → $request.path.proxy
```

Ventaja: API Gateway no reescribe el path y el ALB decide el microservicio.
Las rutas específicas por servicio (`/api/v1/auth/{proxy+}`, etc.) se eliminaron
porque todas compartían una única integración y terminaban enviando cualquier
petición a `ms-posts`.

### Punto crítico: conservar el path

La URL de integración **debe** incluir `{proxy}`:

```text
http://heypudu-alb-201143386.us-east-1.elb.amazonaws.com/{proxy}
```

Si se configura solo el dominio, API Gateway envía `/` al ALB y los servicios
responden `500` con `No static resource`. Si se usa una integración única con
prefijo fijo (`/api/v1/posts/{proxy}`), todas las rutas llegan al servicio
equivocado.

### CORS configurado

```text
Access-Control-Allow-Origin:  https://heypudu.vercel.app
Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS
Access-Control-Allow-Headers: Authorization, Content-Type, Accept
Access-Control-Max-Age:       0
```

El preflight `OPTIONS` responde `200 OK` correctamente.

### Verificación realizada

```bash
curl.exe -i "https://f02rmdid97.execute-api.us-east-1.amazonaws.com/api/v1/users/me"
```

Respuesta: `401 Unauthorized` con `www-authenticate: Bearer`.

Esto confirma que API Gateway → ALB → `ms-users` funciona y que la autorización
JWT está activa.

---

## 11. Frontend en Vercel

| Elemento | Valor |
|---|---|
| URL | `https://heypudu.vercel.app` |
| Framework | React + Vite + TypeScript |
| Auth | Amplify + Cognito |
| Cliente HTTP | Axios |

### Variable de entorno

```env
VITE_API_BASE_URL=https://f02rmdid97.execute-api.us-east-1.amazonaws.com/api
```

Los servicios del frontend usan rutas `/v1/...`, por lo que la URL final queda:

```text
https://f02rmdid97.execute-api.us-east-1.amazonaws.com/api/v1/users/me
```

### Cambios de frontend incluidos en este despliegue

- Capa de integración con Axios y JWT de Cognito (se envía el ID token, que incluye `email`).
- Servicios tipados: `authService`, `usersService`, `postsService`, `interactionsService`, `upload`.
- Sincronización de usuario (`POST /v1/auth/sync`) al iniciar sesión.
- Perfil propio y perfil público reales, ambos con la foto como fondo del recuadro.
- Publicaciones reales en el perfil propio y en el perfil público.
- Feed personalizado con paginación y estado de likes.
- Creación de publicaciones exclusivamente de tipo `AUDIO`, con texto descriptivo opcional.
- Edición y eliminación de publicaciones (esta última también desde el menú de la tarjeta).
- Grabación con `MediaRecorder` y medición real de duración.
- Reproductor de audio global con barra de progreso.
- Likes persistentes con estado optimista y rollback.
- Comentarios paginados con autores enriquecidos y contador sincronizado.
- Reporte de comentarios y de publicaciones con motivo.
- Búsqueda real de personas y briefcasts con debounce.
- Panel `/admin` con:
  - comentarios reportados y publicaciones reportadas en dos columnas;
  - candidatos a baneo (10 reportes acumulados);
  - acciones de escuchar, eliminar, descartar, banear y desbanear;
  - carga resiliente con `Promise.allSettled`.
- Tarjetas con portada, extracto, fecha y duración.
- Manejo defensivo de respuestas de API (`normalizePage`) para tolerar respuestas
  paginadas o arreglos directos.

### Protección del panel admin

```text
RequireAuth → RequireAdmin → AdminPage
```

`RequireAdmin` exige el grupo Cognito `admin`. Si el token no lo contiene, redirige a `/`.

---

## 12. Endpoints de moderación

### ms-interactions

| Método | Ruta | Autorización |
|---|---|---|
| `POST` | `/api/v1/comments/{commentId}/reports` | Autenticado |
| `GET` | `/api/v1/admin/comment-reports` | `ROLE_ADMIN` |
| `PUT` | `/api/v1/admin/comment-reports/{reportId}/{status}` | `ROLE_ADMIN` |
| `DELETE` | `/api/v1/admin/comments/{commentId}` | `ROLE_ADMIN` |
| `GET` | `/api/v1/internal/comment-reports/counts` | Interno |

### ms-posts

| Método | Ruta | Autorización |
|---|---|---|
| `POST` | `/api/v1/posts/{postId}/reports` | Autenticado |
| `GET` | `/api/v1/admin/posts/reports` | `ROLE_ADMIN` |
| `PUT` | `/api/v1/admin/posts/reports/{reportId}/{status}` | `ROLE_ADMIN` |
| `GET` | `/api/v1/admin/posts/audio` | `ROLE_ADMIN` |
| `DELETE` | `/api/v1/admin/posts/{postId}` | `ROLE_ADMIN` |
| `GET` | `/api/v1/internal/posts/reports/counts` | Interno |

La eliminación administrativa borra interacciones, audio en S3, portada en S3 y el registro.

### ms-users

| Método | Ruta | Autorización |
|---|---|---|
| `GET` | `/api/v1/internal/users/by-cognito/{cognitoSub}/summary` | Interno |
| `GET` | `/api/v1/internal/users/by-cognito/{cognitoSub}/following/ids` | Interno |
| `PUT` | `/api/v1/internal/users/by-cognito/{cognitoSub}/post-count?delta=N` | Interno |
| `GET` | `/api/v1/users/by-cognito/{cognitoSub}/avatar` | Público (302 a S3) |
| `GET` | `/api/v1/admin/users/ban-candidates?threshold=10` | `ROLE_ADMIN` |
| `PUT` | `/api/v1/admin/users/{userId}/ban` | `ROLE_ADMIN` |
| `PUT` | `/api/v1/admin/users/{userId}/unban` | `ROLE_ADMIN` |

El endpoint de avatar redirige a una URL prefirmada vigente. Se usa como `src` de
`<img>`, por eso no exige token.

### Reglas de los reportes

Motivos: `SPAM`, `HARASSMENT`, `HATE_SPEECH`, `INAPPROPRIATE_CONTENT`, `OTHER`.

Estados: `OPEN`, `RESOLVED`, `DISMISSED`.

Cada tabla tiene un **índice único parcial** sobre los reportes abiertos:

```sql
CREATE UNIQUE INDEX uq_post_reports_open
    ON post_reports (post_id, reporter_id) WHERE status = 'OPEN';
```

Consecuencias:

- Un usuario no puede tener dos reportes abiertos sobre el mismo contenido.
- Tras un descarte puede volver a reportar, generando una fila nueva.
- El historial completo queda registrado (motivo, fecha, estado y `resolved_by`).

### Candidatos a baneo

`GET /api/v1/admin/users/ban-candidates?threshold=10` agrega en `ms-users` los
conteos que exponen `ms-posts` y `ms-interactions`, suma por `cognitoSub` y
devuelve solo los usuarios que alcanzan el umbral.

- Los reportes `DISMISSED` **no** cuentan.
- El resultado se ordena de mayor a menor.
- El umbral llega por parámetro; el frontend usa 10.


---

## 12.1 Convención de identidad

El proyecto mezcla dos identificadores y esto causó varios errores:

| Identificador | Origen | Usado por |
|---|---|---|
| `cognitoSub` | claim `sub` del JWT | `ms-auth`, `ms-posts` (authorId), `ms-interactions` (userId) |
| `id` interno | tabla `users` | `ms-users`, perfiles públicos, follows |

Reglas:

- `ms-posts` y `ms-interactions` operan siempre con `cognitoSub`.
- `ms-users` expone endpoints internos `by-cognito/...` para resolver desde `cognitoSub`.
- El frontend compara autoría de comentarios con `profile.cognitoSub`.

Las URLs prefirmadas **no** se almacenan en base de datos: caducan y exceden
columnas `varchar(500)`.

---

## 13. Verificaciones realizadas

| Verificación | Resultado |
|---|---|
| `gradlew compileJava` en los 4 microservicios | Correcto |
| `docker compose config` en producción | Correcto |
| `docker compose pull` en EC2 | Correcto |
| `docker compose up -d` | 4 contenedores `Up` |
| `/actuator/health` en los 4 servicios | `{"status":"UP"}` |
| Target groups del ALB | 4 Healthy |
| `GET /api/v1/users/me` sin token | `401 Unauthorized` |
| Preflight CORS `OPTIONS` | `200 OK` |
| `npm run lint` (frontend) | Correcto |
| `npm run build` (frontend) | Correcto |
| Login + `POST /auth/sync` | `200`, crea usuario y perfil |
| Editar perfil + subir avatar | Correcto tras CORS en el bucket |
| Crear publicación AUDIO con descripción | Correcto tras migración V2 |
| Publicación visible en feed y perfil | Correcto |
| Reproductor de audio | Funcional |

> Los tests Gradle no pueden ejecutarse: los proyectos tienen configuración
> incompleta de dependencias JUnit/Spring Boot Test. La compilación de producción
> sí está validada.

---

## 13.1 Problemas resueltos y su causa

| Síntoma | Causa | Solución |
|---|---|---|
| `Cannot read properties of undefined (reading 'split')` en `/perfil` | `name` nulo | guardas con `?? ''` |
| `Cannot read properties of undefined (reading 'length')` en `/admin` | respuesta sin `content` | `normalizePage` |
| `500` con `path: /api/v1/posts/posts/audio` | integración única con prefijo fijo | ruta `ANY /{proxy+}` |
| `500` con `No static resource` | API Gateway truncaba el path | integración con `{proxy}` |
| `503` en preflight | targets `Unhealthy` tras detener la EC2 | esperar health checks |
| SSH e Instance Connect caídos | OOM por 4 JVMs en 1.9 GB | swap 2 GB + límites |
| `OutOfMemoryError: Metaspace` | `-XX:MaxMetaspaceSize=96m` insuficiente | quitar el flag |
| `Unable to load credentials` | EC2 sin IAM Role | asignar `LabInstanceRole` |
| Error CORS al subir avatar | bucket S3 sin CORS | configuración CORS en S3 |
| `El JWT no contiene el claim 'email'` | access token sin `email` | enviar ID token |
| `value too long for type character varying(500)` | URL prefirmada guardada | no almacenar URLs |
| `violates check constraint chk_posts_content_by_type` | V1 exigía `content IS NULL` en AUDIO | migración V2 |
| Feed vacío | no incluía publicaciones propias | añadir `userId` a los autores |
| `No static resource api/v1/users/.../following/ids` | ruta pública inexistente | endpoint interno por `cognitoSub` |
| `500` en `/users/{id}/followers` | Spring Data generaba `SELECT new User(*)` por devolver `Page<User>` desde `FollowRepository` | mover las consultas a `UserRepository` |
| `500` con `/posts/author/undefined` | `cognitoSub` aún no expuesto en el perfil público | desplegar `ms-users` y validar antes de llamar |
| Textos con `?` o caracteres rotos | archivos escritos en cp1252 o con `U+FFFD` | reescritura en UTF-8 |
| `400` al eliminar una publicación | faltaba `DELETE /internal/posts/{id}/interactions` | nuevo controlador interno |
| `400` al re-reportar tras un descarte | restricción única total | índice único parcial sobre `OPEN` |

---

## 14. Estado pendiente

1. **Eliminar mi cuenta.** `DELETE /api/v1/users/me` existe, sin interfaz.
2. **Likes propias más allá de 100.** El feed marca likes con `size=100`.
3. **Auditoría de baneos.** El motivo se valida pero no se guarda; tampoco se
   revocan sesiones activas (`AdminUserGlobalSignOut`).
4. **Estado del usuario en escrituras.** `ms-posts` y `ms-interactions` solo validan
   el JWT, no si el usuario está baneado.
5. **Editar comentarios.** Descartado por decisión del equipo.
6. **Respuestas anidadas y reacciones en comentarios.** No implementadas.
7. **Umbral de candidatos a baneo.** Fijo en 10 desde el frontend.
8. **Rotar la contraseña de Neon** y revocar tokens de Cognito expuestos en la depuración.
9. **Automatizar despliegue** con GitHub Actions (build → push Docker Hub → SSH EC2).
10. **Reactivar y ampliar pruebas** de backend.
11. **Limpiar `ms-auth/bin/`** del repositorio (artefacto de build versionado).
12. **`data/briefcasts.ts`** ya no se usa; puede eliminarse.
13. **Endpoints internos expuestos.** La ruta comodín `ANY /{proxy+}` del API
    Gateway deja accesible `/api/v1/internal/**` desde internet; conviene
    bloquearla en el gateway y protegerla con un token de servicio.
14. **Validación de claves S3.** El backend no comprueba el prefijo ni la
    pertenencia de `avatarKey`, `audioKey` y `coverImageKey`.
15. **Avatar en S3 al borrar la cuenta.** Se anonimiza el perfil pero el objeto
    anterior queda huérfano en el bucket.
16. **Salas de audio en vivo y Kafka.** Aún no desplegadas: faltan `ms-live`
    y `ms-analytics` en `docker-compose.prod.yml`, reglas del ALB para
    `/api/v1/live/*` y `/api/v1/analytics/*`, el broker Kafka, MediaMTX y el
    bloqueo de `/api/v1/internal/**`. La arquitectura y el reparto de
    instancias se detallan en la sección 16. La guía de fases es
    `PLAN-IMPLEMENTACION-KAFKA.md` (fases 3 a 8).


---

## 15. Comandos de operación diaria

```bash
# Ver estado
docker compose -f docker-compose.prod.yml ps

# Ver logs de un servicio
docker compose -f docker-compose.prod.yml logs -f --tail=100 ms-posts

# Buscar errores
docker compose -f docker-compose.prod.yml logs ms-auth \
  | grep -E "ERROR|Exception|Caused by" | tail -40

# Actualizar imágenes publicadas
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d

# Reiniciar un servicio
docker compose -f docker-compose.prod.yml restart ms-users

# Probar health desde la EC2
curl http://localhost:8081/actuator/health
curl http://localhost:8082/actuator/health
curl http://localhost:8083/actuator/health
curl http://localhost:8084/actuator/health
```

---

## 16. Salas en vivo (Fase 8): capacidad, MediaMTX y estabilidad de IP

Esta sección fija la arquitectura de despliegue para `ms-live`, `ms-analytics`,
Kafka y MediaMTX, y el criterio para manejar el cambio de IP pública de las
instancias de AWS Academy.

### 16.1 Capacidad

La EC2 backend actual es `t3.small` (2 GB) y ya ejecuta 5 contenedores
(≈1,9 GB). **No admite más microservicios.** Consumo estimado de la demo
(audio, decenas de oyentes):

| Componente | RAM típica |
|---|---|
| `ms-live` (Spring Boot) | 300–450 MB |
| `ms-analytics` (Spring Boot) | 250–350 MB |
| MediaMTX (audio WebRTC) | 100–250 MB |
| SO + Docker | 200–300 MB |
| **Total** | **≈0,9–1,3 GB** |

### 16.2 Reparto de instancias

**Opción A (elegida para la demo): tercera EC2 `t3.small`.**

```
EC2 1 (actual, t3.small)          EC2 2 (RabbitMQ)        EC2 3 (nueva, t3.small)
ms-auth :8081                     rabbit1 :5672           ms-live      :8086
ms-users :8082                     rabbit2 :5672           ms-analytics :8087
ms-posts :8083                                             MediaMTX     :8889/8189
ms-interactions :8084                                      Kafka        :9092 *
ms-rabbit-admin :8085
```

\* Kafka puede quedarse en la EC2 3 o moverse a una cuarta instancia según D7.

Ventajas: una sola instancia nueva, menos horas de laboratorio y comunicación
interna directa. MediaMTX es ligero y cabe junto a los dos microservicios con
`mem_limit` por contenedor.

**Opción B (más aislada):** tercera EC2 solo para los microservicios y cuarta
`t3.micro` solo para MediaMTX. Útil para la defensa, pero añade instancias y
consume horas del pool free-tier (las 750 h mensuales de `t3.micro` son
**compartidas**, no por instancia).

### 16.3 Security Groups de la EC2 nueva

| Puerto | Origen | Uso |
|---|---|---|
| `8086` | SG del ALB | `ms-live` |
| `8087` | SG del ALB | `ms-analytics` |
| `8889/TCP` | `0.0.0.0/0` | WHIP/WHEP (señalización WebRTC) |
| `8189/UDP` | `0.0.0.0/0` | Medios WebRTC (ICE) |
| `9997/TCP` | SG de la EC2 nueva o VPC | API de control de MediaMTX |
| `9092` | SG del backend | Kafka (solo si se aloja aquí) |

Referenciar **Security Groups por ID**, nunca por IP, para que el stop/start
no rompa las reglas.

### 16.4 API Gateway no puede transportar el audio

La API Gateway existente (`ANY /{proxy+}` → ALB) **no sirve para MediaMTX**:

- WHIP/WHEP son HTTP y podrían proxearse, pero el **audio WebRTC viaja por
  UDP/ICE** (`8189/UDP`) y API Gateway solo enruta HTTP/WebSocket.
- Aunque se proxeara el SDP, los candidatos ICE apuntan a la IP pública del
  SFU; el navegador conecta **directamente** con MediaMTX.
- Forzar ICE-TCP + NLB es posible pero poco fiable en navegadores y añade
  complejidad innecesaria para la demo.

Por tanto: **API Gateway/ALB se mantienen para los microservicios** y
MediaMTX expone su propio endpoint público estable.

### 16.5 IP pública cambiante en AWS Academy

| Consumidor | ¿Afecta el cambio de IP pública? |
|---|---|
| API Gateway → ALB → backend | No (ALB tiene DNS estable) |
| `ms-live` → `ms-users` | No (red privada) |
| `ms-live` → RabbitMQ | No (red privada y SG por ID) |
| Navegador → MediaMTX | **Sí**: WHIP/WHEP necesitan URL pública estable |

Hechos relevantes:

- La **IP privada primaria se conserva** al detener/arrancar la instancia.
- La **IP pública sí cambia** al stop/start.
- En EC2 la IP pública es NAT 1:1: MediaMTX anuncia IPs privadas en ICE, por lo
  que la IP/dominio público debe declararse en `webrtcAdditionalHosts`.

**Solución:** Elastic IP **solo para el endpoint de MediaMTX** (o para la EC2 3
si comparte instancia). La EIP se mantiene asociada al detener/arrancar y
evita reconfigurar `MEDIAMTX_PUBLIC_URL` y `webrtcAdditionalHosts`.

- Verificar si la cuenta AWS Academy permite EIP; desde 2024 AWS cobra las
  IPv4 públicas (≈0,005 USD/h).
- Si no se permite EIP: usar **DNS dinámico** (DuckDNS/No-IP) y un script de
  arranque (`user-data` o systemd) que actualice el registro A con la IP
  actual. El backend consume ese dominio, no la IP.
- El backend **no necesita EIP**: entra por API Gateway/ALB.

Configuración derivada:

```env
MEDIAMTX_PUBLIC_URL=https://live.<dominio-o-dns-dinamico>
MEDIAMTX_SERVICE_TOKEN=<secreto-compartido>
```

```yaml
# mediamtx.yml
webrtcAdditionalHosts: [live.<dominio-o-dns-dinamico>]
webrtcAllowOrigins: ['https://heypudu.vercel.app']
authHTTPAddress: http://<IP-privada-ms-live>:8086/api/v1/internal/mediamtx/auth
```

### 16.6 Checklist de la Fase 8

- [x] `ms-live` y `ms-analytics` desplegables con `mem_limit` (`docker-compose.live.prod.yml`).
- [x] Reglas del ALB para `/api/v1/live/*` y `/api/v1/analytics/*` (prioridades 12 y 13).
- [x] **Bloquear `/api/v1/internal/**`**: regla prioridad 11 con respuesta fija 403 (verificado).
- [x] Kafka desplegado con `advertised.listeners` en IP privada y auto-create desactivado.
- [x] MediaMTX con HTTPS/WSS y `authHTTPAddress`/hooks hacia la IP privada de `ms-live`.
- [x] Elastic IP o DNS dinámico para el endpoint de MediaMTX.
- [x] `.env` de las EC2 actualizado (Cognito, DB, Kafka, RabbitMQ, MediaMTX).
- [ ] Verificación del flujo completo desde Vercel (requiere frontend F1–F5).
- [ ] `ms-analytics` fusionado en `develop` antes de desplegar.

---

## 17. Fase 8 — despliegue paso a paso

Artefactos ya preparados en el repo:

| Archivo | Uso |
|---|---|
| `docker-compose.live.prod.yml` | Kafka + MediaMTX + Caddy + `ms-live` + `ms-analytics` para la EC2 3 |
| `mediamtx/mediamtx.prod.yml` | Config de MediaMTX con auth/hooks hacia `ms-live:8086` |
| `caddy/Caddyfile` | TLS automático para `${MEDIAMTX_HOST}` → `mediamtx:8889` |
| `live-prod.env.example` | Variables a completar en `live-prod.env` (ignorado por Git) |

### 17.1 Comprobaciones previas (consola AWS, 10 min)

1. **Cupo de vCPU** → EC2 → *Limits* (o Service Quotas → EC2 → *Running On-Demand Standard instances*).
   Si ya estás en el tope, usar la opción de consolidar o subir la instancia actual a `t3.medium`.
2. **Elastic IP** → EC2 → *Elastic IPs* → *Allocate*. Si responde `UnauthorizedOperation`, la cuenta no permite EIP: usar dominio con DNS dinámico.
3. **Security Group** → confirmar que se pueden añadir reglas `8889/TCP` y `8189/UDP`.

### 17.2 Crear la EC2 3

- AMI: Amazon Linux 2023, tipo `t3.small`, misma VPC y subnet que la EC2 backend.
- Almacenamiento: 20 GB gp3.
- `user-data` mínimo (Docker + compose):

```bash
#!/bin/bash
dnf install -y docker git
systemctl enable --now docker
usermod -aG docker ec2-user
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
```

### 17.3 Security Group de la EC2 3

| Puerto | Origen |
|---|---|
| `22` | tu IP |
| `80`, `443` | `0.0.0.0/0` (Caddy / Let's Encrypt) |
| `8189/UDP` | `0.0.0.0/0` (medios WebRTC) |
| `8086`, `8087` | **SG del ALB** (por ID, no por IP) |
| `9092`, `9997` | sin reglas: solo red Docker / local |

### 17.4 Imágenes de `ms-live` y `ms-analytics`

Igual que los demás microservicios, se construyen y suben desde la máquina local:

```bash
docker build -t unalmaermitana/heypudu-ms-live:latest ./ms-live
docker push unalmaermitana/heypudu-ms-live:latest
docker build -t unalmaermitana/heypudu-ms-analytics:latest ./ms-analytics
docker push unalmaermitana/heypudu-ms-analytics:latest
```

MediaMTX también se publica como imagen (la EC2 **no** necesita `buildx`, que
en Amazon Linux 2023 no viene instalado y hace fallar `compose build`):

```bash
docker build -t unalmaermitana/heypudu-mediamtx:latest ./mediamtx
docker push unalmaermitana/heypudu-mediamtx:latest
```

El contenedor de MediaMTX monta `mediamtx/mediamtx.prod.yml` como
**plantilla** en `/mediamtx.yml.template`: MediaMTX no expande `${VAR}` en su
YAML, así que el entrypoint de la imagen (`mediamtx/docker-entrypoint.sh`)
aplica `envsubst` solo a `${MEDIAMTX_HOST}`, `${MEDIAMTX_SERVICE_TOKEN}` y
`${MEDIAMTX_ALLOWED_ORIGIN}` y escribe el `/mediamtx.yml` final antes de
arrancar. Las variables de los hooks (`$MTX_PATH`, `$MTX_QUERY`) no se tocan.

### 17.5 Arranque en la EC2 3

```bash
git clone https://github.com/theseventhshadow/heyPudu-backend.git
cd heyPudu-backend
cp live-prod.env.example live-prod.env   # completar valores reales
docker compose --env-file live-prod.env -f docker-compose.live.prod.yml up -d
docker compose --env-file live-prod.env -f docker-compose.live.prod.yml ps
```

Orden esperado: `kafka` (healthy) → `kafka-init` crea el tópico → `mediamtx`, `caddy`, `ms-live`, `ms-analytics`.

> Al republicar una imagen con la misma etiqueta (`:latest`), `up -d` **no** la
> descarga. Hay que hacer `docker compose ... pull <servicio>` (o
> `up -d --pull always`) antes de recrear.

Notas:
- `CLIENTS_USERS_BASE_URL` debe apuntar a la **IP privada de la EC2 1** (`http://10.x.x.x:8082`).
- `RABBITMQ_HOST` debe ser la **IP privada de la EC2 2**.
- El esquema `heypudu_analytics` lo crea Flyway al arrancar (el usuario de Neon debe poder crear esquemas).

### 17.6 DNS y TLS

1. Crear un registro `A` (o un CNAME a la EIP) para `live.<dominio>` apuntando a la IP pública de la EC2 3.
2. `MEDIAMTX_HOST=live.<dominio>` y `MEDIAMTX_PUBLIC_URL=https://live.<dominio>` en `live-prod.env`.
3. Caddy pide el certificado solo al arrancar; si el DNS aún no propaga, reiniciar el servicio:
   `docker compose --env-file live-prod.env -f docker-compose.live.prod.yml restart caddy`

Si no se tiene dominio propio, `sslip.io` sirve como host con TLS válido sin
comprar nada: `35-170-42-143.sslip.io` resuelve a la EIP
`35.170.42.143`, y Caddy emite el certificado de Let's Encrypt igual que con un
dominio real. El `email` de ACME es opcional (el `Caddyfile` lo deja comentado).

### 17.7 ALB: destinos y reglas

1. Crear dos *Target Groups* (`http`, puerto 8086 y 8087) con la EC2 3 como destino.
2. En el listener HTTP del `heypudu-alb`, añadir reglas **antes** de la regla por defecto:

| Prioridad | Condición | Acción |
|---|---|---|
| 1 | Path `/api/v1/internal/*` | **Fixed response 403** |
| 10 | Path `/api/v1/live/*` | Forward → TG `ms-live-8086` |
| 11 | Path `/api/v1/analytics/*` | Forward → TG `ms-analytics-8087` |
| 12 | Path `/api/v1/mediamtx/*` (opcional) | Bloquear |

La regla 1 resuelve el pendiente de seguridad: el wildcard del API Gateway deja de exponer los endpoints internos, y los microservicios siguen hablándose por la red Docker / IP privada.

### 17.8 Verificación

```bash
# en la EC2 3
curl -s localhost:8086/actuator/health      # {"status":"UP"}
curl -s localhost:8087/actuator/health      # {"status":"UP"}
curl -sI https://live.<dominio> | head -1   # HTTP/2 404 (MediaMTX sin path) => TLS OK
```

Desde el navegador (Vercel): crear sala, publicar, escuchar desde otra cuenta y reaccionar. En Kafka:

```bash
docker exec heypudu-broker1 kafka-consumer-groups \
  --bootstrap-server broker1:9092 --describe --group live-analytics-group
docker exec heypudu-broker1 kafka-consumer-groups \
  --bootstrap-server broker1:9092 --describe --group live-audit-group
```

### 17.9 Limpieza al terminar la demo

- Detener la EC2 3 (ahorra horas del laboratorio) teniendo en cuenta que la IP pública cambiará salvo que haya EIP.
- Si se usó EIP y AWS Academy la permite, liberarla al final para evitar cargos de IPv4.
- `docker system prune` en la EC2 si se van a reconstruir imágenes.

### 17.10 Estado del despliegue (ejecutado)

Recursos creados en la cuenta `561816430875` (rol `voclabs`, `us-east-1`):

| Recurso | Valor |
|---|---|
| Security Group | `heypudu-live-sg` = `sg-0b2a5ba3e54516cb2` |
| Instancia | `heypudu-live` = `i-09ea2f39fef85c88b` (**t3.medium**, `10.0.7.159`, us-east-1a, Amazon Linux 2023, 20 GB gp3, swap de 2 GB) |
| Elastic IP | `35.170.42.143` (`eipalloc-0d43c4b1b8083fce5`) |
| Target Groups | `heypudu-live-tg` (`8086`), `heypudu-analytics-tg` (`8087`) y `heypudu-kafka-admin-tg` (`8088`), todos **healthy** |
| Reglas del listener :80 | `11` `/api/v1/internal/*` → 403 · `12` `/api/v1/live/*` → live TG · `13` `/api/v1/analytics/*` → analytics TG · `14` `/api/v1/admin/kafka/*` → kafka-admin TG |
| Host de MediaMTX | `35-170-42-143.sslip.io` (TLS de Let's Encrypt emitido por Caddy) |

Reglas de red relevantes:

- `heypudu-live-sg`: `22` desde la IP doméstica, `80` y `443` desde `0.0.0.0/0`, `8189/udp` desde `0.0.0.0/0`, `8086`, `8087` y `8088` desde el SG del ALB, `9192-9193` desde el SG del backend (listener externo de Kafka).
- SG del backend: `8082` desde `heypudu-live-sg` (para `ms-live` → `ms-users`).
- SG de RabbitMQ: `5672` desde `heypudu-live-sg`.

Comprobaciones hechas desde fuera de la instancia:

```text
https://35-170-42-143.sslip.io/             -> 404  (TLS OK, MediaMTX sin handler raíz)
https://35-170-42-143.sslip.io/<sala>/whep  -> 401  (auth HTTP contra ms-live activa)
ALB /api/v1/internal/...                    -> 403  (bloqueado por la regla 11)
ALB /api/v1/live/...                         -> 401  (llega a ms-live; exige JWT)
ALB /api/v1/analytics/...                    -> 401  (llega a ms-analytics)
```

En la instancia: `kafka` healthy, `kafka-init` creó el tópico de 3 particiones,
Flyway aplicó `V1` y `V2` en `heypudu_live`, `live-audit-group` con las tres
particiones asignadas y `{"status":"UP"}` en `8086` y `8087`.

`live-prod.env` se generó reutilizando las credenciales de producción de la
EC2 1 (Neon y RabbitMQ) y no se versiona (`live-prod.env` está en `.gitignore`).

---

## 18. Evaluación Parcial 5 — Kafka con ZooKeeper

La pauta de la EP5 exige **ZooKeeper + brokers**, **dos tópicos**, un
**microservicio administrador de Kafka** y **manejo de errores con reintentos**.
El clúster KRaft de un solo broker de la fase 8 no cumplía esos puntos, así que
se migró el despliegue completo.

### 18.1 Antes y después

| Aspecto | Fase 8 (KRaft) | Ahora (EP5) |
|---|---|---|
| Consenso | KRaft, 1 nodo `broker+controller` | **ZooKeeper 3.9 + 2 brokers** |
| Tópicos | 1 (`heypudu.live.events`) | **2** + sus DLT |
| Réplicas | RF=1 | **RF=2** |
| Consumidores | ACK manual | **`DefaultErrorHandler` + DLT** |
| Administración | `kafka-init` (script) | `kafka-init` **+ `ms-kafka-admin`** |
| Instancia | t3.small, 1,9 GB | **t3.medium, 3,8 GB + swap 2 GB** |

Kafka 4.x eliminó ZooKeeper, por eso las imágenes quedan fijadas en la línea
7.9.0 de Confluent (Kafka 3.9).

### 18.2 Topología

```
EC2 1 (t3.small)                        EC2 3 (t3.medium)
ms-posts :8083 ─── 9192/9193 ──────►    broker1 + broker2 ◄── ZooKeeper :2181
  (listener EXTERNAL)                     ▲        ▲
                                          │        │
                             ms-live :8086  ms-analytics :8087
                             ms-kafka-admin :8088
                                   │
                          MediaMTX + Caddy (TLS)
```

`ms-posts` corre en otra instancia y publica por el listener externo; el resto
usa el listener interno `broker1:9092,broker2:9092`.

### 18.3 Tópicos y grupos

| Tópico | Particiones | RF | Retención | Productor | Consumidores |
|---|---|---|---|---|---|
| `heypudu.live.events` | 3 | 2 | 7 días | `ms-live` | `live-analytics-group`, `live-audit-group` |
| `heypudu.posts.events` | 2 | 2 | 3 días | `ms-posts` | `posts-analytics-group` |
| `heypudu.live.events.DLT` | 3 | 2 | 30 días | `ms-analytics` | inspección manual |
| `heypudu.posts.events.DLT` | 2 | 2 | 30 días | `ms-analytics` | inspección manual |

Todos con `cleanup.policy=delete` y `min.insync.replicas=1` (tolera el reinicio
de un broker sin bloquear la publicación).

### 18.4 Cambios en la instancia

- Tipo cambiado de `t3.small` a **`t3.medium`** (stop → modify → start; la EIP
  y el registro en los target groups se mantienen).
- **Swap de 2 GB** en `/swapfile`, persistente en `/etc/fstab`, con
  `vm.swappiness=10`.
- Motivo: ZooKeeper (384m) + 2 brokers (700m cada uno) ya no caben en 1,9 GB
  junto a `ms-live`, `ms-analytics`, `ms-kafka-admin`, MediaMTX y Caddy.

### 18.5 Administrador de Kafka

`ms-kafka-admin` (puerto 8088) expone el `AdminClient` por REST con
`ROLE_ADMIN`:

| Método | Ruta |
|---|---|
| `GET` | `/api/v1/admin/kafka/cluster` |
| `GET` `POST` | `/api/v1/admin/kafka/topics` |
| `GET` `DELETE` | `/api/v1/admin/kafka/topics/{topic}` |
| `PATCH` | `/api/v1/admin/kafka/topics/{topic}/config` |
| `GET` | `/api/v1/admin/kafka/groups` · `/groups/{groupId}` |

Recursos asociados: target group `heypudu-kafka-admin-tg` (8088), regla `14`
del listener del ALB y `8088` abierto en `heypudu-live-sg` desde el SG del ALB.

### 18.6 Verificación realizada

| Prueba | Resultado |
|---|---|
| Sala en vivo (crear, escuchar, reaccionar) | `ROOM_CREATED`, `LISTENER_JOINED/LEFT` y `REACTION` en `heypudu.live.events` |
| Publicación nueva | `POST_CREATED` en `heypudu.posts.events`, LAG 0 en `posts-analytics-group` |
| Mensaje inválido (`{}`) en el tópico de publicaciones | Recuperado en `heypudu.posts.events.DLT`, offset confirmado y partición desbloqueada |
| `ms-kafka-admin` | Target **healthy**; `/api/v1/admin/kafka/*` responde `401` sin token (ruta correcta) |
| Grupos de consumo | `live-analytics-group`, `live-audit-group` y `posts-analytics-group` asignados |

Para el coste actualizado (t3.medium) ver `COSTES-AWS.md`.




