# QuizArena · Infraestructura

Todo lo necesario para levantar QuizArena completo, tanto en local como en
Microsoft Azure: el `docker-compose` de desarrollo/demo, el script de
despliegue a la nube y el stack de observabilidad (Prometheus + Grafana).

No contiene código de aplicación — cada microservicio y el frontend viven
en su propio repo (ver la lista completa en `LEEME.md` o en el `README` de
cada uno). Este repo asume que todos están clonados como carpetas hermanas:

```
QuizArena-GameService/
QuizArena-IdentityService/
QuizArena-ApiGateway/
QuizArena-IAService/
QuizArena-Frontend/
QuizArena-Infra/          <- este repo
```

---

## `docker-compose.full.yml` — todo el sistema en un comando

Levanta las 2 bases de datos PostgreSQL, Redis, los 4 microservicios y el
frontend, todo containerizado:

```powershell
docker compose -f docker-compose.full.yml up -d --build
```

Abre `http://localhost:3001`. Los datos (usuarios, bancos, historial)
persisten entre corridas en los volúmenes nombrados (`pg_identidad`,
`pg_juego`, `redis_data`) — `docker compose down` (sin `-v`) los conserva.

Variables opcionales, se leen de un `.env` en esta carpeta (ver
`.env.example`): `MAIL_USERNAME`/`MAIL_PASSWORD`/`MAIL_FROM` (verificación
de correo), `GEMINI_API_KEY`/`GEMINI_MODEL` (generación de preguntas con
IA), `JWT_SECRET` (si no se define, usa un valor de desarrollo fijo — solo
para local, nunca para producción).

Este compose es también el **plan B para la demo**: si Azure falla o se
acaban los créditos, el sistema completo funciona igual en local.

---

## `desplegar-azure.ps1` — despliegue en la nube

Crea de cero todo lo necesario en Azure (Container Registry, 2 PostgreSQL,
Redis Cache, entorno de Container Apps, y los 5 Container Apps) y despliega
la versión actual de cada repo.

```powershell
az login
.\desplegar-azure.ps1
```

Tarda 20-30 minutos (crear PostgreSQL y Redis es lo lento). Requisitos:
Azure CLI, Docker Desktop corriendo, y las rutas `$RUTA_*` al inicio del
script apuntando a tus repos (por defecto asume la estructura de carpetas
hermanas de arriba).

Genera un `JWT_SECRET` y una contraseña de PostgreSQL **aleatorios en cada
corrida** (nunca hardcodeados) y los inyecta como secretos de Container
Apps — nunca quedan en texto plano ni en el repo. Ver `FASE6.md` para el
detalle de las decisiones de arquitectura del despliegue (ingress interno
vs externo, por qué el Juego arranca con 2 réplicas, etc.) y qué decir de
esto en la sustentación.

**Cuentas Azure for Students:** `az acr build` está bloqueado
(`TasksOperationsNotAllowed`) — por eso el script construye las imágenes
con `docker build` local y las sube con `docker push`. La región confirmada
sin restricciones es `brazilsouth`.

### Apagar todo (evitar cobros)

PostgreSQL y Redis cobran por hora aunque no se usen:

```powershell
az group delete --name rg-quizarena --yes --no-wait
```

---

## `observabilidad/`

Prometheus + Grafana con un dashboard preconfigurado
(`quizarena-dashboard.json`): latencia p50/p95/p99, jugadores conectados
por instancia, salas activas, KPIs de negocio. Apunta el scrape config de
Prometheus a `http://localhost:8081/actuator/prometheus` de cada instancia
del Servicio de Juego que quieras monitorear.

```powershell
docker compose up -d
```

Grafana: `http://localhost:3000` (admin/admin).

---

## Archivos de este repo

```
docker-compose.full.yml    sistema completo containerizado (local)
desplegar-azure.ps1        despliegue a Azure Container Apps
.env.example                plantilla de variables para docker-compose.full.yml
FASE6.md                    guia y razonamiento detras del despliegue en Azure
observabilidad/             Prometheus + Grafana (docker-compose aparte)
```
