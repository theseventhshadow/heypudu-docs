<#
.SYNOPSIS
    Abre un tunel SSH persistente hacia la EC2 de salas de heyPudu!

.DESCRIPTION
    Mantiene el puerto local 8090 enlazado con la Kafka UI de la instancia
    (127.0.0.1:8090). Si la conexion se cae -por un corte de internet, por
    ejemplo- el bucle la relanza automaticamente cada 5 segundos.

    Antes de conectar comprueba tu IP publica, porque el Security Group
    heypudu-live-sg solo permite el puerto 22 desde la IP domestica. Con
    -ArreglarSG la regla se actualiza sola usando la AWS CLI.

.PARAMETER ArreglarSG
    Anade la IP actual a la regla 22 de heypudu-live-sg y retira la anterior.

.PARAMETER SinBucle
    Abre el tunel una sola vez, sin reconectar automaticamente.

.EXAMPLE
    .\conectar-live.ps1

.EXAMPLE
    .\conectar-live.ps1 -ArreglarSG

.NOTES
    Ctrl+C detiene el bucle y cierra el tunel.
    Requiere haber arrancado la instancia antes de usarlo.
#>

param(
    [string]$Clave = (Join-Path $PSScriptRoot 'backhp.pem'),
    [string]$Servidor = '35.170.42.143',
    [string]$Usuario = 'ec2-user',
    [int]$PuertoLocal = 8090,
    [string]$GrupoSeguridad = 'sg-0b2a5ba3e54516cb2',
    [switch]$ArreglarSG,
    [switch]$SinBucle
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path $Clave)) {
    Write-Host "No se encuentra la clave: $Clave" -ForegroundColor Red
    exit 1
}

# ---- 1. IP publica actual ------------------------------------------------
$miIp = $null
try {
    $miIp = (Invoke-RestMethod 'https://checkip.amazonaws.com' -TimeoutSec 10).Trim()
    Write-Host "Tu IP publica es $miIp" -ForegroundColor Cyan
} catch {
    Write-Host "No se pudo obtener la IP publica; se continua sin comprobarla." -ForegroundColor Yellow
}

# ---- 2. Regla 22 del Security Group --------------------------------------
if ($miIp) {
    $aws = Get-Command aws -ErrorAction SilentlyContinue
    if (-not $aws) {
        $aws = Get-Command 'C:\Users\puc0\AppData\Local\AWSCLIV2\Amazon\AWSCLIV2\aws.exe' -ErrorAction SilentlyContinue
    }

    if ($aws) {
        try {
            $json = & $aws.Source ec2 describe-security-groups --group-ids $GrupoSeguridad --output json --no-cli-pager 2>$null | ConvertFrom-Json
            $permitidas = @()
            foreach ($g in $json.SecurityGroups) {
                foreach ($p in $g.IpPermissions) {
                    if ($p.FromPort -eq 22) {
                        foreach ($r in $p.IpRanges) { $permitidas += $r.CidrIp }
                    }
                }
            }

            if ($permitidas -contains "$miIp/32") {
                Write-Host "El Security Group ya permite tu IP." -ForegroundColor Green
            } elseif ($ArreglarSG) {
                & $aws.Source ec2 authorize-security-group-ingress --group-id $GrupoSeguridad --protocol tcp --port 22 --cidr "$miIp/32" --no-cli-pager | Out-Null
                foreach ($vieja in $permitidas) {
                    & $aws.Source ec2 revoke-security-group-ingress --group-id $GrupoSeguridad --protocol tcp --port 22 --cidr $vieja --no-cli-pager | Out-Null
                    Write-Host "Regla antigua retirada: $vieja" -ForegroundColor DarkGray
                }
                Write-Host "Regla 22 actualizada a $miIp/32." -ForegroundColor Green
            } else {
                Write-Host "ATENCION: el Security Group permite 22 desde: $($permitidas -join ', ')" -ForegroundColor Yellow
                Write-Host "Ejecuta este script con -ArreglarSG o actualiza la regla a mano." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "No se pudo comprobar el Security Group (AWS CLI sin credenciales vigentes)." -ForegroundColor Yellow
        }
    } else {
        Write-Host "AWS CLI no disponible: no se comprueba el Security Group." -ForegroundColor Yellow
    }
}

# ---- 3. Tunel ------------------------------------------------------------
$opciones = @(
    '-i', $Clave,
    '-o', 'ServerAliveInterval=20',
    '-o', 'ServerAliveCountMax=3',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-N',
    '-L', "${PuertoLocal}:localhost:8090",
    "$Usuario@$Servidor"
)

Write-Host ""
Write-Host "Abriendo tunel http://localhost:$PuertoLocal  ->  Kafka UI" -ForegroundColor Cyan
Write-Host "Ctrl+C para detenerlo." -ForegroundColor DarkGray
Write-Host ""

if ($SinBucle) {
    & ssh @opciones
    exit $LASTEXITCODE
}

$intentos = 0
while ($true) {
    & ssh @opciones
    $intentos++
    Write-Host "Tunel caido (intento $intentos). Reconectando en 5 s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}
