#!/usr/bin/env sh
# Despliega API (Render) y frontend (Firebase Hosting) a un ambiente.
# Uso: ./scripts/deploy.sh dev|qa|prod
# Requiere en el entorno (inyectados por Jenkins Credentials, nunca en el repositorio):
#   RENDER_DEPLOY_HOOK              URL del Deploy Hook del servicio Render del ambiente
#   GOOGLE_APPLICATION_CREDENTIALS  ruta al JSON de la cuenta de servicio de Firebase
set -eu

ENVIRONMENT="${1:?Uso: ./scripts/deploy.sh dev|qa|prod}"
case "$ENVIRONMENT" in
  dev|qa|prod) ;;
  *) echo "Ambiente inválido: $ENVIRONMENT" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/deploy/$ENVIRONMENT.env"
: "${RENDER_DEPLOY_HOOK:?Falta RENDER_DEPLOY_HOOK}"
: "${GOOGLE_APPLICATION_CREDENTIALS:?Falta GOOGLE_APPLICATION_CREDENTIALS}"
COMMIT="${GIT_COMMIT:-$(git -C "$ROOT" rev-parse HEAD)}"
API_WAIT_SECONDS="${API_WAIT_SECONDS:-1200}"

# 1. API primero, para que el frontend nuevo nunca apunte a una API vieja.
echo "==> [$ENVIRONMENT] Solicitando despliegue de la API en Render (commit $COMMIT)"
curl -fsS -X POST "${RENDER_DEPLOY_HOOK}&ref=${COMMIT}" > /dev/null

echo "==> [$ENVIRONMENT] Esperando a que $API_URL sirva el commit $COMMIT (máx ${API_WAIT_SECONDS}s)"
elapsed=0
while :; do
  info="$(curl -fsS --max-time 30 "$API_URL/actuator/info" 2>/dev/null || true)"
  health="$(curl -fsS --max-time 30 "$API_URL/actuator/health" 2>/dev/null || true)"
  case "$info" in
    *"\"commit\":\"$COMMIT\""*)
      case "$health" in *'"status":"UP"'*) echo "    API lista con el commit esperado"; break ;; esac ;;
  esac
  if [ "$elapsed" -ge "$API_WAIT_SECONDS" ]; then
    echo "ERROR: la API no quedó disponible con el commit $COMMIT. Última respuesta info: $info" >&2
    exit 1
  fi
  sleep 20
  elapsed=$((elapsed + 20))
  echo "    ...esperando (${elapsed}s)"
done

# 2. Frontend compilado con la URL de la API de este ambiente.
echo "==> [$ENVIRONMENT] Compilando frontend con VITE_API_URL=$API_URL"
(cd "$ROOT/frontend" && VITE_API_URL="$API_URL" npm run build)

echo "==> [$ENVIRONMENT] Publicando en Firebase Hosting (target $FIREBASE_TARGET)"
(cd "$ROOT" && firebase deploy --only "hosting:$FIREBASE_TARGET" --non-interactive \
  --message "env=$ENVIRONMENT commit=$COMMIT build=${BUILD_NUMBER:-local}")

echo "==> [$ENVIRONMENT] Despliegue completado: $FRONTEND_URL"
