# heyPudú! — documentación y seguimiento

Repositorio de documentos de trabajo del proyecto **heyPudú!**: estado, planes,
despliegue en AWS y control de gasto del laboratorio.

El código vive en repositorios aparte:

- `heyPudu-backend` — microservicios Spring Boot.
- `heyPudu-frontend-web` — aplicación React + Vite.

## Contenido

| Archivo | Qué contiene |
|---|---|
| [`estado-proyecto-heypudu.txt`](./estado-proyecto-heypudu.txt) | Estado del proyecto: qué está hecho y qué falta. |
| [`contexto general.txt`](./contexto%20general.txt) | Contexto general del proyecto, arquitectura y decisiones de partida. |
| [`contexto de rabbitmq.txt`](./contexto%20de%20rabbitmq.txt) | Notas sobre el clúster RabbitMQ: topología, colas y flujos. |
| [`respecto a kafka.txt`](./respecto%20a%20kafka.txt) | Notas sobre Kafka: tópico, grupos de consumo y eventos. |
| [`PLAN-IMPLEMENTACION-KAFKA.md`](./PLAN-IMPLEMENTACION-KAFKA.md) | Plan de implementación de las salas de audio en vivo con Kafka. |
| [`KAFKA-IMPLEMENTACION.md`](./KAFKA-IMPLEMENTACION.md) | Cómo está implementado Kafka: funciones, productores, consumidores, DLT, administración, operación y cumplimiento de la pauta EP5. |
| [`DEMO-KAFKA-UI.md`](./DEMO-KAFKA-UI.md) | Guion paso a paso de la demostración con Kafka UI: mensaje inválido hasta el DLT, duplicado idempotente, caída de un broker y reprocesamiento. |
| [`revision-integracion-heypudu.txt`](./revision-integracion-heypudu.txt) | Revisión de la integración entre microservicios y frontend. |
| [`DESPLIEGUE-AWS.md`](./DESPLIEGUE-AWS.md) | Despliegue completo en AWS: VPC, Security Groups, ALB, EC2, TLS y verificación. |
| [`COSTES-AWS.md`](./COSTES-AWS.md) | Consumo del crédito del laboratorio y seguimiento diario hasta la demo. |
| [`IDEAS-FUTURAS.md`](./IDEAS-FUTURAS.md) | Ideas y mejoras fuera del alcance entregado, con esfuerzo, impacto y dependencias. |
| [`EP5_DSY1107_Estudiante_encargo.pdf`](./EP5_DSY1107_Estudiante_encargo.pdf) | Enunciado y pauta de la Evaluación Parcial N°5 (Kafka). |
| [`aws-backups/`](./aws-backups) | Snapshots JSON de recursos de AWS (security groups, reglas y target groups) del 2026-11-20. |

## Notas

- Las claves SSH (`*.pem`) y los archivos de entorno **no** se versionan; están
  en `.gitignore`.
- Los dos repositorios de código están excluidos de este repositorio porque cada
  uno tiene su propio historial.
- Las credenciales de producción (Neon, RabbitMQ, Cognito, token de MediaMTX)
  solo existen como variables de entorno en las instancias y en los secrets de
  GitHub; no aparecen en estos documentos.
