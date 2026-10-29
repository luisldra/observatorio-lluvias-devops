# Guía de despliegue: Jenkins + Firebase Hosting + Render + Neon

## Arquitectura

```mermaid
flowchart LR
  dev[Desarrollador] -->|push| gh[(GitHub<br/>develop · qa · main)]
  gh -->|escaneo periódico| jk[Jenkins local<br/>Docker]
  jk -->|firebase deploy| fb[Firebase Hosting<br/>3 sitios]
  jk -->|Deploy Hook + commit| rd[Render<br/>3 servicios Docker]
  rd -->|JDBC + SSL| neon[(Neon PostgreSQL<br/>ramas dev · qa · prod)]
  user[Usuario] -->|HTTPS| fb
  fb -.->|VITE_API_URL| rd
```

| Ambiente | Rama Git | Frontend (Firebase) | API (Render) | BD (Neon) |
|---|---|---|---|---|
| DEV | `develop` | sitio `…-dev` | servicio `observatorio-api-dev` | rama `dev` |
| QA | `qa` | sitio `…-qa` | servicio `observatorio-api-qa` | rama `qa` |
| PDN | `main` | sitio `…-prod` | servicio `observatorio-api-prod` | rama `main` |

Flujo de promoción: `develop` → (merge) → `qa` → (merge + aprobación manual en Jenkins) → `main`.

## Dónde vive cada configuración

| Dato | Dónde | ¿Secreto? |
|---|---|---|
| URLs de frontend y API por ambiente | `deploy/{dev,qa,prod}.env` | No |
| Sitios de Firebase | `.firebaserc` | No |
| Cuenta de servicio de Firebase (JSON) | Jenkins Credentials `firebase-service-account` | **Sí** |
| Deploy Hooks de Render | Jenkins Credentials `render-deploy-hook-{dev,qa,prod}` | **Sí** |
| Usuario/clave de la BD | Variables de entorno del servicio en Render | **Sí** |

Ningún secreto se guarda en el repositorio.

---

## Paso 1. GitHub

1. Crear un repositorio **público** (por ejemplo `observatorio-lluvias-devops`).
2. Subir el código y crear las ramas:
   ```bash
   git remote add origin https://github.com/<usuario>/observatorio-lluvias-devops.git
   git push -u origin main
   git checkout -b qa && git push -u origin qa
   git checkout -b develop && git push -u origin develop
   ```

## Paso 2. Neon (PostgreSQL)

1. Crear una cuenta en https://neon.tech (plan gratuito) y un proyecto `observatorio`.
2. La rama por defecto (`main`) será **PDN**. Crear las ramas `dev` y `qa` desde *Branches → New branch*.
3. De cada rama, copiar en *Connection Details* (conexión directa, no la *pooled*):
   - host (`ep-xxxx.region.aws.neon.tech`), base de datos, usuario y contraseña.
4. La URL JDBC tiene la forma `jdbc:postgresql://<host>/<base>?sslmode=require`.
   Neon muestra por defecto `postgresql://usuario:clave@ep-xxx-pooler.../neondb?sslmode=require&channel_binding=require`;
   para Spring Boot: anteponer `jdbc:`, quitar `usuario:clave@` (van en variables aparte), quitar `-pooler` del host
   y dejar solo `?sslmode=require`.

Las tablas se crean solas al arrancar la API (`ddl-auto=update`).

## Paso 3. Render (API)

Crear **tres** servicios (*New → Web Service → repositorio de GitHub*) con estos valores:

| Campo | DEV | QA | PDN |
|---|---|---|---|
| Name | `observatorio-api-dev` | `observatorio-api-qa` | `observatorio-api-prod` |
| Branch | `develop` | `qa` | `main` |
| Language | Docker | Docker | Docker |
| Root Directory | `backend` | `backend` | `backend` |
| Instance Type | Free | Free | Free |
| Health Check Path | `/actuator/health` | igual | igual |
| **Auto-Deploy** | **Off** | **Off** | **Off** |

Con *Auto-Deploy* en **Off**, solo Jenkins despliega y solo después de que pasen las pruebas.

Variables de entorno de cada servicio (*Environment*):

```
SPRING_DATASOURCE_URL=jdbc:postgresql://<host-de-la-rama>/<base>?sslmode=require
SPRING_DATASOURCE_USERNAME=<usuario>
SPRING_DATASOURCE_PASSWORD=<clave>
APP_CORS_ORIGINS=https://<sitio-firebase-del-mismo-ambiente>.web.app
APP_ENV=dev   # qa / prod según el servicio
```

Luego, en *Settings → Deploy Hook*, copiar la URL de cada servicio. Esa URL es secreta y va a Jenkins en el paso 5.

La URL pública de cada API (`https://observatorio-api-dev.onrender.com` o similar) va en `deploy/<ambiente>.env` → `API_URL`.

> Plan gratuito: la API se suspende tras ~15 min sin tráfico y la primera petición tarda ~1 min. Antes de una demo, abra `/actuator/health` para despertarla.

## Paso 4. Firebase Hosting

1. En https://console.firebase.google.com crear el proyecto (plan Spark, gratuito).
2. *Hosting → Comenzar*, y luego *Agregar otro sitio* hasta tener tres: por ejemplo `observatorio-dev-<sufijo>`, `observatorio-qa-<sufijo>` y `observatorio-prod-<sufijo>`.
3. Editar `.firebaserc`: poner el ID del proyecto y los IDs de los tres sitios en lugar de los `CAMBIAR-*`.
4. Editar `deploy/<ambiente>.env` → `FRONTEND_URL=https://<id-sitio>.web.app`.
5. Cuenta de servicio para Jenkins:
   - Google Cloud Console (mismo proyecto) → *IAM y administración → Cuentas de servicio → Crear*.
   - Roles: **Firebase Hosting Admin**, **API Keys Viewer** y **Service Usage Consumer**
     (sin este último `firebase deploy` falla con `Permission denied to get service [firebasehosting.googleapis.com]`).
   - *Claves → Agregar clave → JSON*. Guarde el archivo **fuera del repositorio**.

## Paso 5. Jenkins (local con Docker)

```bash
cd jenkins
docker compose up -d --build
docker exec jenkins-observatorio cat /var/jenkins_home/secrets/initialAdminPassword
```

1. Abrir http://localhost:8081 y pegar la contraseña.
2. Elegir *Select plugins to install → None*; los plugins ya vienen en la imagen.
3. Crear el usuario administrador.
4. *Manage Jenkins → Credentials → System → Global → Add Credentials*:
   - `firebase-service-account`: tipo *Secret file*, con el JSON del paso 4.
   - `render-deploy-hook-dev`, `render-deploy-hook-qa` y `render-deploy-hook-prod`: tipo *Secret text*, con la URL del Deploy Hook de cada servicio.
5. *New Item → Multibranch Pipeline* llamado `observatorio`:
   - *Branch Sources → Add source → Git*, con la URL HTTPS del repositorio (público, no necesita credenciales).
   - *Scan Multibranch Pipeline Triggers → Periodically if not otherwise run → 1 minute*.
   - Guardar. Jenkins detecta `develop`, `qa` y `main` y lanza un build por rama.

Como Jenkins está en `localhost`, GitHub no puede enviarle webhooks. Por eso Jenkins consulta el repositorio cada minuto.

## Paso 6. Primer despliegue y promoción

1. Hacer commit de `.firebaserc` y `deploy/*.env` con los valores reales en `develop` y hacer push. Jenkins despliega en DEV.
2. Merge de `develop` en `qa` y push. Jenkins despliega en QA y ejecuta `scripts/acceptance-test.sh`.
3. Merge de `qa` en `main` y push. Jenkins se detiene en **Aprobación PDN**; hay que pulsar *Desplegar a PDN* en la vista del build.

Qué hace el pipeline en cada push:

| Etapa | Qué ejecuta | Si falla |
|---|---|---|
| Instalar dependencias | `npm ci` y `mvn dependency:resolve` | Se detiene |
| Análisis básico | `npm audit` (críticas, solo producción) y `mvn validate` | Se detiene |
| Pruebas automatizadas | Vitest y JUnit en paralelo, con reporte JUnit | Se detiene |
| Empaquetado | `mvn package` y `npm run build` | Se detiene |
| Deploy | Deploy Hook de Render con el commit exacto; espera a que `/actuator/info` muestre ese commit; recompila el frontend con su `VITE_API_URL`; `firebase deploy` | Se detiene; el frontend no cambia |
| Pruebas de humo | Frontend, health, `/api/dashboard/summary` y CORS | Build en rojo |
| Aceptación (solo QA) | Registro y consulta de lluvia, incidente con cambio de estado, deslizamiento y resumen | Build en rojo |

## Reversión (rollback)

- **Recomendada:** `git revert <commit>` en la rama del ambiente y push. Así se vuelve a pasar por el pipeline completo.
- **Urgente:**
  - Render: *Events → Rollback* al deploy anterior.
  - Firebase: *Hosting → sitio → Historial de versiones → Revertir*.

## Costos y limpieza

| Servicio | Plan | Posibles cargos |
|---|---|---|
| Firebase Hosting | Spark (gratis) | Ninguno; no requiere tarjeta |
| Render | Free | Ninguno; cambiar de plan sí genera cobro mensual |
| Neon | Free | Ninguno dentro de los límites; no requiere tarjeta |
| Jenkins | Local (Docker) | Ninguno |

Al terminar el curso:
1. Render: *Settings → Delete Web Service* en los tres servicios.
2. Neon: *Project settings → Delete project*.
3. Firebase: *Configuración del proyecto → Borrar proyecto*. Antes, eliminar la clave de la cuenta de servicio en IAM.
4. Jenkins: `cd jenkins && docker compose down -v`.
5. Eliminar de Jenkins y de su equipo el JSON de la cuenta de servicio.
