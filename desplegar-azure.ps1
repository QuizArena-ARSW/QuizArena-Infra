# ==========================================================
# QuizArena - Despliegue en Microsoft Azure
#
# Requisitos previos:
#   1. Azure CLI instalado:  https://aka.ms/installazurecliwindows
#   2. Sesion iniciada:      az login
#   3. Docker Desktop corriendo
#
# Uso:
#   .\desplegar-azure.ps1
#
# IMPORTANTE SOBRE COSTOS:
#   Este script crea servicios GESTIONADOS (PostgreSQL y Redis) que consumen
#   credito POR HORA aunque no los uses. Con Azure for Students (~$100 USD)
#   alcanza de sobra para el proyecto, PERO:
#     -> Cuando termines de probar, BORRA todo con:
#          az group delete --name $RG --yes --no-wait
#     -> O al menos revisa el gasto en el portal periodicamente.
# ==========================================================

# ---------- Parametros (ajusta lo que quieras) ----------
$RG        = "rg-quizarena"                    # grupo de recursos
$UBICACION = "brazilsouth"                      # region (westus2/eastus/eastus2/southcentralus/westeurope estan restringidas para esta suscripcion de Azure for Students)
$SUFIJO    = Get-Random -Minimum 1000 -Maximum 9999   # para nombres unicos
$ACR       = "acrquizarena$SUFIJO"             # registro de imagenes (sin guiones)
$ENTORNO   = "env-quizarena"                   # entorno de Container Apps

$PG_IDENTIDAD = "pg-quizarena-identidad-$SUFIJO"
$PG_JUEGO     = "pg-quizarena-juego-$SUFIJO"
$REDIS        = "redis-quizarena-$SUFIJO"

$DB_USER = "quizarena"
# Generada aleatoria en cada corrida (no hardcodeada: evita dejar una
# contrasena real en texto plano en el repositorio). Se imprime al final
# del script — guardala si necesitas conectarte a la BD manualmente.
$DB_PASS = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object {[char]$_}) + "!1"

# Clave JWT: se genera aleatoria y se comparte entre Identidad y Gateway
$JWT_SECRET = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 48 | ForEach-Object {[char]$_})

# Credenciales SMTP (verificacion de correo al registrarse): se leen de .env
# local (no se suben al repo). Ver .env.example para el formato esperado.
$ENV_FILE = Join-Path $PSScriptRoot ".env"
$envVars = @{}
if (Test-Path $ENV_FILE) {
    Get-Content $ENV_FILE | ForEach-Object {
        if ($_ -match '^\s*([^#=]+)\s*=\s*(.*)\s*$') {
            $envVars[$matches[1].Trim()] = $matches[2].Trim()
        }
    }
}
$MAIL_USERNAME = $envVars["MAIL_USERNAME"]
$MAIL_PASSWORD = $envVars["MAIL_PASSWORD"]
$MAIL_FROM     = $envVars["MAIL_FROM"]
if (-not $MAIL_USERNAME -or -not $MAIL_PASSWORD) {
    Write-Host "ADVERTENCIA: no se encontro .env con MAIL_USERNAME/MAIL_PASSWORD. El envio de correos de verificacion no funcionara hasta que configures esos secretos manualmente en el Container App 'identidad'." -ForegroundColor Yellow
}

$GEMINI_API_KEY = $envVars["GEMINI_API_KEY"]
$GEMINI_MODEL   = if ($envVars["GEMINI_MODEL"]) { $envVars["GEMINI_MODEL"] } else { "gemini-flash-latest" }
if (-not $GEMINI_API_KEY) {
    Write-Host "ADVERTENCIA: no se encontro GEMINI_API_KEY en .env. El bono de generacion de preguntas con IA no funcionara hasta que configures ese secreto manualmente en el Container App 'ia'." -ForegroundColor Yellow
}

# Rutas a tus repos (AJUSTA si tu estructura es distinta)
$RUTA_IDENTIDAD = "..\QuizArena-IdentityService"
$RUTA_JUEGO     = "..\QuizArena-GameService"
$RUTA_GATEWAY   = "..\QuizArena-ApiGateway"
$RUTA_FRONTEND  = "..\QuizArena-Frontend"
$RUTA_IA        = "..\QuizArena-IAService"

Write-Host "=== QuizArena: despliegue en Azure ===" -ForegroundColor Magenta
Write-Host "Grupo de recursos: $RG" -ForegroundColor Gray

# ---------- 1. Grupo de recursos ----------
Write-Host "`n[1/8] Creando grupo de recursos..." -ForegroundColor Cyan
az group create --name $RG --location $UBICACION --output none

# ---------- 2. Registro de contenedores (ACR) ----------
Write-Host "[2/8] Creando Azure Container Registry..." -ForegroundColor Cyan
az acr create --resource-group $RG --name $ACR --sku Basic --admin-enabled true --output none
az acr login --name $ACR

# ---------- 3. Construir y subir las imagenes ----------
Write-Host "[3/8] Construyendo y subiendo imagenes (esto tarda varios minutos)..." -ForegroundColor Cyan

# NOTA: las cuentas Azure for Students (y otras suscripciones patrocinadas) suelen
# tener BLOQUEADO "ACR Tasks" (el motor detras de "az acr build"), con el error
# "TasksOperationsNotAllowed". Por eso construimos LOCAL con Docker y subimos con
# docker push (requiere Docker Desktop corriendo).
$ACR_SERVER_BUILD = az acr show --name $ACR --query loginServer -o tsv
az acr login --name $ACR

docker build -t "$ACR_SERVER_BUILD/quizarena/identidad:v1" $RUTA_IDENTIDAD
docker push "$ACR_SERVER_BUILD/quizarena/identidad:v1"
Write-Host "   - identidad OK" -ForegroundColor Green

docker build -t "$ACR_SERVER_BUILD/quizarena/juego:v1" $RUTA_JUEGO
docker push "$ACR_SERVER_BUILD/quizarena/juego:v1"
Write-Host "   - juego OK" -ForegroundColor Green

docker build -t "$ACR_SERVER_BUILD/quizarena/gateway:v1" $RUTA_GATEWAY
docker push "$ACR_SERVER_BUILD/quizarena/gateway:v1"
Write-Host "   - gateway OK" -ForegroundColor Green

docker build -t "$ACR_SERVER_BUILD/quizarena/ia:v1" $RUTA_IA
docker push "$ACR_SERVER_BUILD/quizarena/ia:v1"
Write-Host "   - ia OK" -ForegroundColor Green

# ---------- 4. Bases de datos PostgreSQL ----------
Write-Host "[4/8] Creando bases de datos PostgreSQL (tarda ~5 min)..." -ForegroundColor Cyan

az postgres flexible-server create `
  --resource-group $RG --name $PG_IDENTIDAD --location $UBICACION `
  --admin-user $DB_USER --admin-password $DB_PASS `
  --sku-name Standard_B1ms --tier Burstable --version 16 `
  --storage-size 32 --public-access 0.0.0.0 --yes --output none

az postgres flexible-server db create `
  --resource-group $RG --server-name $PG_IDENTIDAD --name identidad_db --output none

az postgres flexible-server create `
  --resource-group $RG --name $PG_JUEGO --location $UBICACION `
  --admin-user $DB_USER --admin-password $DB_PASS `
  --sku-name Standard_B1ms --tier Burstable --version 16 `
  --storage-size 32 --public-access 0.0.0.0 --yes --output none

az postgres flexible-server db create `
  --resource-group $RG --server-name $PG_JUEGO --name juego_db --output none

$DB_URL_IDENTIDAD = "jdbc:postgresql://$PG_IDENTIDAD.postgres.database.azure.com:5432/identidad_db?sslmode=require"
$DB_URL_JUEGO     = "jdbc:postgresql://$PG_JUEGO.postgres.database.azure.com:5432/juego_db?sslmode=require"

# ---------- 5. Azure Cache for Redis ----------
Write-Host "[5/8] Creando Azure Cache for Redis (tarda ~10 min)..." -ForegroundColor Cyan
az redis create --resource-group $RG --name $REDIS --location $UBICACION `
  --sku Basic --vm-size c0 --output none

$REDIS_HOST = "$REDIS.redis.cache.windows.net"
$REDIS_KEY  = az redis list-keys --resource-group $RG --name $REDIS --query primaryKey -o tsv

# ---------- 6. Entorno de Container Apps ----------
Write-Host "[6/8] Creando entorno de Container Apps..." -ForegroundColor Cyan
az extension add --name containerapp --upgrade --only-show-errors
az containerapp env create --resource-group $RG --name $ENTORNO --location $UBICACION --output none

$ACR_SERVER = az acr show --name $ACR --query loginServer -o tsv
$ACR_USER   = az acr credential show --name $ACR --query username -o tsv
$ACR_PASS   = az acr credential show --name $ACR --query "passwords[0].value" -o tsv

# ---------- 7. Desplegar los microservicios ----------
Write-Host "[7/8] Desplegando microservicios..." -ForegroundColor Cyan

# --- Identidad (interno: solo lo llaman el Gateway y el Juego) ---
az containerapp create --resource-group $RG --name identidad --environment $ENTORNO `
  --image "$ACR_SERVER/quizarena/identidad:v1" `
  --registry-server $ACR_SERVER --registry-username $ACR_USER --registry-password $ACR_PASS `
  --target-port 8082 --ingress internal `
  --min-replicas 1 --max-replicas 2 `
  --cpu 0.5 --memory 1Gi `
  --secrets "db-pass=$DB_PASS" "jwt=$JWT_SECRET" "mail-pass=$MAIL_PASSWORD" `
  --env-vars "PORT=8082" "DB_URL=$DB_URL_IDENTIDAD" "DB_USER=$DB_USER" `
             "DB_PASSWORD=secretref:db-pass" "JWT_SECRET=secretref:jwt" `
             "MAIL_USERNAME=$MAIL_USERNAME" "MAIL_PASSWORD=secretref:mail-pass" "MAIL_FROM=$MAIL_FROM" `
  --output none
$URL_IDENTIDAD = "http://identidad"   # nombre interno dentro del entorno

# --- IA (interno, bono: genera preguntas, no tiene base de datos propia) ---
az containerapp create --resource-group $RG --name ia --environment $ENTORNO `
  --image "$ACR_SERVER/quizarena/ia:v1" `
  --registry-server $ACR_SERVER --registry-username $ACR_USER --registry-password $ACR_PASS `
  --target-port 8083 --ingress internal `
  --min-replicas 1 --max-replicas 2 `
  --cpu 0.5 --memory 1Gi `
  --secrets "gemini-key=$GEMINI_API_KEY" `
  --env-vars "PORT=8083" "GEMINI_API_KEY=secretref:gemini-key" "GEMINI_MODEL=$GEMINI_MODEL" `
  --output none
$URL_IA = "http://ia"

# --- Juego (EXTERNO: el WebSocket se conecta directo desde el navegador) ---
# Escala a varias replicas: aqui es donde Redis demuestra su valor.
az containerapp create --resource-group $RG --name juego --environment $ENTORNO `
  --image "$ACR_SERVER/quizarena/juego:v1" `
  --registry-server $ACR_SERVER --registry-username $ACR_USER --registry-password $ACR_PASS `
  --target-port 8081 --ingress external `
  --min-replicas 2 --max-replicas 5 `
  --cpu 0.5 --memory 1Gi `
  --secrets "db-pass=$DB_PASS" "redis-key=$REDIS_KEY" "jwt=$JWT_SECRET" `
  --env-vars "PORT=8081" "SERVICIO_IDENTIDAD_URL=$URL_IDENTIDAD" `
             "DB_URL=$DB_URL_JUEGO" "DB_USER=$DB_USER" "DB_PASSWORD=secretref:db-pass" `
             "REDIS_HOST=$REDIS_HOST" "REDIS_PORT=6380" "REDIS_SSL=true" `
             "REDIS_PASSWORD=secretref:redis-key" "CORS_ORIGENES=*" "JWT_SECRET=secretref:jwt" `
  --output none

$FQDN_JUEGO = az containerapp show --resource-group $RG --name juego --query "properties.configuration.ingress.fqdn" -o tsv
if ([string]::IsNullOrWhiteSpace($FQDN_JUEGO)) {
    throw "No se pudo obtener el FQDN de 'juego'. Revisa el Container App manualmente antes de continuar (si sigues, el frontend quedaria con la URL del WebSocket rota)."
}

# --- Gateway (EXTERNO: punto de entrada del frontend) ---
az containerapp create --resource-group $RG --name gateway --environment $ENTORNO `
  --image "$ACR_SERVER/quizarena/gateway:v1" `
  --registry-server $ACR_SERVER --registry-username $ACR_USER --registry-password $ACR_PASS `
  --target-port 8080 --ingress external `
  --min-replicas 1 --max-replicas 3 `
  --cpu 0.5 --memory 1Gi `
  --secrets "jwt=$JWT_SECRET" `
  --env-vars "PORT=8080" "SERVICIO_IDENTIDAD_URL=$URL_IDENTIDAD" `
             "SERVICIO_JUEGO_URL=http://juego" "SERVICIO_IA_URL=$URL_IA" `
             "JWT_SECRET=secretref:jwt" "CORS_ORIGENES=*" `
  --output none

$FQDN_GATEWAY = az containerapp show --resource-group $RG --name gateway --query "properties.configuration.ingress.fqdn" -o tsv
if ([string]::IsNullOrWhiteSpace($FQDN_GATEWAY)) {
    throw "No se pudo obtener el FQDN de 'gateway'. Revisa el Container App manualmente antes de continuar (si sigues, el frontend quedaria con la URL de la API rota)."
}

# ---------- 8. Frontend ----------
Write-Host "[8/8] Construyendo y desplegando el frontend..." -ForegroundColor Cyan

# Las URLs del backend se incrustan al compilar la imagen (build local, ver nota del paso 3)
docker build -t "$ACR_SERVER/quizarena/frontend:v1" `
  --build-arg VITE_API_URL="https://$FQDN_GATEWAY" `
  --build-arg VITE_WS_URL="https://$FQDN_JUEGO/ws-juego" `
  $RUTA_FRONTEND
docker push "$ACR_SERVER/quizarena/frontend:v1"

az containerapp create --resource-group $RG --name quizarena --environment $ENTORNO `
  --image "$ACR_SERVER/quizarena/frontend:v1" `
  --registry-server $ACR_SERVER --registry-username $ACR_USER --registry-password $ACR_PASS `
  --target-port 80 --ingress external `
  --min-replicas 1 --max-replicas 2 `
  --cpu 0.25 --memory 0.5Gi `
  --output none

$FQDN_FRONTEND = az containerapp show --resource-group $RG --name quizarena --query "properties.configuration.ingress.fqdn" -o tsv

# ---------- Resumen ----------
Write-Host "`n=====================================================" -ForegroundColor Green
Write-Host " QuizArena desplegado" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host " Frontend : https://$FQDN_FRONTEND"
Write-Host " Gateway  : https://$FQDN_GATEWAY"
Write-Host " Juego    : https://$FQDN_JUEGO   (2 replicas, WebSocket)"
Write-Host " Identidad: interno (no expuesto)"
Write-Host " IA       : interno (no expuesto, bono de generacion de preguntas)"
Write-Host ""
Write-Host " El Servicio de Juego corre con 2 REPLICAS compartiendo estado" -ForegroundColor Yellow
Write-Host " en Redis: el escalado horizontal esta activo en produccion." -ForegroundColor Yellow
Write-Host ""
Write-Host " Para BORRAR todo y no gastar credito:" -ForegroundColor Red
Write-Host "   az group delete --name $RG --yes --no-wait" -ForegroundColor Red
Write-Host "=====================================================" -ForegroundColor Green
Write-Host ""
Write-Host " Contrasena de PostgreSQL (guardala si necesitas conectarte manualmente):" -ForegroundColor Yellow
Write-Host " $DB_PASS" -ForegroundColor Yellow
