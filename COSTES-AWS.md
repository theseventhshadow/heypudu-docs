# Costes AWS — heyPudú!

Registro del consumo del laboratorio de AWS Academy para comparar día a día
hasta la demo. **Los importes son estimaciones** con precios on-demand de
`us-east-1`; el gasto real es el que muestre el panel del laboratorio.

- **Demo:** jueves 26 de noviembre de 2026
- **Crédito total:** 50 USD

---

## Corte del 21-11-2026 (sábado)

| Concepto | Valor |
|---|---|
| Crédito total | 50,00 USD |
| Consumido | 17,00 USD |
| **Disponible** | **33,00 USD** |
| Días hasta la demo | 5 |

---

## Inventario facturable

| Recurso | Detalle | Coste unitario |
|---|---|---|
| EC2 `heypuduback` | t3.small (`i-05b808f859f54a876`) | 0,0208 USD/h |
| EC2 `heypudu-rabbitmq` | t3.small (`i-0f42928aad2cef8bb`) | 0,0208 USD/h |
| EC2 `heypudu-live` | t3.small (`i-09ea2f39fef85c88b`) | 0,0208 USD/h |
| ALB `heypudu-alb` | base 2 AZ | 0,0225 USD/h + LCU |
| IPv4 públicas | `35.170.42.143` (EIP) + 2 del ALB | 0,005 USD/h cada una |
| EBS | 36 GB gp3 en total | 0,08 USD/GB-mes |
| NAT Gateway | ninguno | — |
| S3 | 42,7 MB en 3 buckets (medido 21-11) | 0,023 USD/GB-mes + peticiones |

API Gateway, S3 y Cognito quedan en céntimos con el volumen actual.

### S3 (medido el 21-11-2026)

| Bucket | Objetos | Tamaño |
|---|---|---|
| `heypudu-audio-bucket` | 39 | 8,4 MB |
| `heypudu-avatar-bucket` | 4 | 4,8 MB |
| `heypudu-cover-bucket` | 24 | 29,5 MB |
| **Total** | **67** | **42,7 MB** |

Coste de almacenamiento ≈ **0,001 USD/mes**. Las peticiones (PUT con URL
prefirmada al subir, GET al reproducir) y la salida de datos son
despreciables a este volumen.


---

## Ritmo de gasto

| Estado | Coste por hora | Coste por día |
|---|---|---|
| Todo encendido | ≈ 0,109 USD/h | ≈ 2,62 USD |
| Instancias paradas (siguen ALB, IPs y EBS) | ≈ 0,047 USD/h | ≈ 1,13 USD |

El ALB y las direcciones IP se cobran aunque las instancias estén detenidas.
La Elastic IP no debe liberarse antes de la demo: cambiaría
`35-170-42-143.sslip.io`, el certificado de Caddy y `live-prod.env`.

---

## Proyección al 26-11 (120 h)

| Escenario | Coste estimado | Disponible al final |
|---|---|---|
| Todo encendido 24/7 | ≈ 13 USD | ≈ 20 USD |
| Apagado de noche, encendido ~4 h/día | ≈ 7 USD | ≈ 26 USD |
| Apagado salvo ensayo y demo (~12 h) | ≈ 6 USD | ≈ 27 USD |

Plan elegido: instancias apagadas cuando no se esté probando, todo encendido
el miércoles (ensayo) y el jueves (demo).

---

## Seguimiento diario

Anotar cada día el valor del panel del laboratorio (no hay API para
consultarlo):

| Fecha | Consumido (USD) | Disponible (USD) | Δ del día | Notas |
|---|---|---|---|---|
| 21-11-2026 | 17,00 | 33,00 | — | Corte inicial; 3 instancias encendidas |
| 22-11-2026 | | | | |
| 23-11-2026 | | | | |
| 24-11-2026 | | | | |
| 25-11-2026 | | | | Ensayo general |
| 26-11-2026 | | | | Demo |

---

## Comprobaciones rápidas

Estado de las instancias:

```bash
aws ec2 describe-instances --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,State:State.Name,Type:InstanceType}" --output table
```

Contenedores de cada instancia (tras arrancar el laboratorio):

```bash
ssh -i backhp.pem ec2-user@<ip> "docker compose ps"     # EC2 1 y 3, con su -f y env
```

Orden de arranque recomendado: EC2 2 (RabbitMQ) → EC2 1 (backend) → EC2 3
(salas en vivo). Comprobar después que `CLIENTS_USERS_BASE_URL` y
`RABBITMQ_HOST` siguen apuntando a `10.0.14.103` y `10.0.139.232`.

Al terminar el curso: borrar instancias y ALB, y **liberar la Elastic IP**.
