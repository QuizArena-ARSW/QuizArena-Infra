# Fase 6 · Despliegue en Microsoft Azure

Desplegar no es "subir el código". Hay **tres pasos** y conviene hacerlos en
orden, porque cada uno valida al siguiente:

1. **Containerizar** — empaquetar cada servicio en una imagen Docker.
2. **Externalizar la configuración** — hoy tu código tiene `localhost` y
   secretos escritos a mano; en la nube eso no sirve.
3. **Desplegar en Azure**.

> **No te saltes el paso 2.** Es el que más falla en la práctica: si las URLs y
> los secretos están fijos en el código, la imagen solo funciona en tu máquina.

---

## PASO 1 — Containerizar

Cada uno de los 4 microservicios Java (Identidad, Juego, Gateway, IA) y el
Frontend tiene su propio `Dockerfile` y `.dockerignore` en la raíz de su
repo. Los Dockerfiles de los servicios Java comparten la misma estructura
(multi-etapa Maven→JRE alpine; el puerto lo define una variable de entorno,
no el Dockerfile).

**Detalle del frontend:** el `nginx.conf` tiene una línea clave
(`try_files $uri $uri/ /index.html`). Sin ella, si el usuario recarga la página
estando en `/lobby`, Nginx devolvería 404, porque esa ruta solo existe dentro de
React. Es el error clásico al desplegar una SPA.

---

## PASO 2 — Externalizar la configuración

La idea es simple: todo lo que cambia entre entornos se lee de **variables
de entorno**, con un valor por defecto para desarrollo local:

```
${VARIABLE:valor_por_defecto}
```

Así la **misma imagen** funciona en tu PC y en Azure: solo cambian las
variables. Nunca recompilas para cambiar de entorno. Excepción deliberada:
los secretos reales (`JWT_SECRET`, contraseñas de BD) **no tienen valor por
defecto** en ningún servicio — si falta la variable, el servicio falla al
arrancar en vez de usar una clave conocida.

**Lo que se externalizó:** URLs entre servicios, credenciales de base de datos,
host y clave de Redis, la clave JWT, los orígenes CORS, el puerto y la API
key de Gemini (Servicio de IA).

**Sobre el frontend:** Vite incrusta las variables al **compilar**, no en
tiempo de ejecución. Por eso las URLs se pasan como `--build-arg` al construir
la imagen (el script de Azure ya lo hace).

---

## PASO 3 (intermedio) — Probar TODO containerizado en local

Antes de tocar Azure, valida que los contenedores funcionan. Usa
`docker-compose.full.yml` (ajusta las rutas de los `context` a tus repos si
tu estructura de carpetas es distinta):

```powershell
docker compose -f docker-compose.full.yml up --build
```

Abre `http://localhost:3001`. Si el sistema completo funciona así, la
containerización está bien y Azure será mucho menos doloroso.

> **Este archivo es también tu PLAN B.** Si el día de la sustentación Azure
> falla o se te acaban los créditos, levantas todo el sistema con un comando.
> Tenlo probado.

---

## PASO 4 — Desplegar en Azure

### Requisitos

1. **Azure CLI**: https://aka.ms/installazurecliwindows
2. Iniciar sesión: `az login`
3. Docker Desktop corriendo

### Ejecutar

Ajusta las rutas a tus repos al inicio de `desplegar-azure.ps1` si tu
estructura de carpetas es distinta, y corre:

```powershell
.\desplegar-azure.ps1
```

Tarda **20-30 minutos** (crear PostgreSQL y Redis es lento). Al final te
imprime las URLs.

### Qué crea

| Recurso | Para qué |
|---|---|
| Azure Container Registry | guarda tus imágenes Docker |
| Azure Container Apps | corre los 4 microservicios + el frontend |
| Azure Database for PostgreSQL ×2 | una base por servicio (Identidad y Juego) |
| Azure Cache for Redis | estado compartido entre instancias |

### Decisiones de arquitectura que verás en el script

**El Servicio de Identidad tiene ingress `internal`.** No se expone a internet:
solo lo alcanzan el Gateway y el Juego, desde dentro. Es más seguro y refuerza
el patrón de "punto de entrada único".

**El Servicio de Juego tiene ingress `external`.** Porque el WebSocket se
conecta directo desde el navegador (esa fue tu decisión de arquitectura).

**El Juego arranca con `--min-replicas 2`.** Esto es importante: en producción
corre con **2 instancias desde el primer momento**, compartiendo estado en Redis.
Es tu escalado horizontal funcionando de verdad, no una promesa.

**Los secretos van como `secretref:`.** La clave JWT y las contraseñas se
guardan como secretos de Container Apps, no como texto plano ni en el repo.

---

## AVISOS IMPORTANTES SOBRE COSTOS

Con **Azure for Students** (~$100 USD de crédito), esto alcanza de sobra para el
proyecto. **Pero** PostgreSQL y Redis cobran **por hora, aunque no los uses**.

**Recomendación seria:** cuando termines de probar o de presentar, borra todo:

```powershell
az group delete --name rg-quizarena --yes --no-wait
```

Y vuelve a desplegar cuando lo necesites (el script tarda ~25 min). No dejes los
recursos prendidos semanas: podrías quedarte sin crédito justo antes de la
sustentación.

**Revisa tu gasto** en el portal de Azure de vez en cuando (Cost Management).

---

## Qué decir en la sustentación

Esta fase te da un argumento fuerte:

> *"El sistema está desplegado en Azure Container Apps, con una base de datos
> gestionada por servicio y Azure Cache for Redis como estado compartido. El
> Servicio de Juego corre con dos réplicas desde el arranque y escala hasta
> cinco según la carga: el escalado horizontal no es una promesa de diseño, está
> activo en producción. El Servicio de Identidad no se expone a internet; solo
> es alcanzable internamente, y todo el tráfico externo entra por el Gateway. Los
> secretos se inyectan como variables de entorno, nunca están en el repositorio."*

Fíjate en lo que estás demostrando ahí: escalabilidad real, seguridad por capas,
independencia de despliegue y configuración externalizada. Eso es lo que separa
un proyecto que "funciona en mi máquina" de uno con criterio arquitectónico.

---

## Si algo falla

**El build de una imagen falla** → prueba primero en local:
`docker build -t prueba .` dentro del repo del servicio. Es más rápido depurar
ahí que en Azure.

**Un servicio arranca y se cae** → mira los logs:
```powershell
az containerapp logs show --resource-group rg-quizarena --name juego --follow
```

**El frontend carga pero no conecta** → casi seguro son las URLs o CORS. Verifica
que la imagen del frontend se construyó con los `--build-arg` correctos (las URLs
quedan incrustadas al compilar).
