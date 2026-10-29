#!/usr/bin/env sh
# Pruebas de humo de solo lectura (seguras para PDN).
# Uso: ./scripts/smoke-test.sh dev|qa|prod
set -eu

ENVIRONMENT="${1:?Uso: ./scripts/smoke-test.sh dev|qa|prod}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/deploy/$ENVIRONMENT.env"

fail() { echo "  FALLO: $1" >&2; exit 1; }
ok() { echo "  OK: $1"; }

echo "==> Pruebas de humo [$ENVIRONMENT]"

page="$(curl -fsS --max-time 30 "$FRONTEND_URL/")" || fail "el frontend $FRONTEND_URL no responde"
case "$page" in *'id="root"'*) ok "frontend responde por HTTPS" ;; *) fail "el frontend no contiene la app" ;; esac

# Render Free suspende la API por inactividad; el primer request puede tardar ~1-2 min en despertarla.
health=""
for attempt in 1 2 3; do
  health="$(curl -fsS --max-time 60 "$API_URL/actuator/health" 2>/dev/null)" && break
  echo "  ...API sin respuesta (intento $attempt/3), reintentando"
done
[ -n "$health" ] || fail "la API $API_URL no responde"
case "$health" in *'"status":"UP"'*) ok "API health UP" ;; *) fail "health: $health" ;; esac

curl -fsS --max-time 30 "$API_URL/api/dashboard/summary" > /dev/null || fail "GET /api/dashboard/summary"
ok "GET /api/dashboard/summary"

# CORS: la API de este ambiente debe aceptar al frontend de este mismo ambiente.
cors="$(curl -fsS --max-time 30 -o /dev/null -D - -X OPTIONS \
  -H "Origin: $FRONTEND_URL" -H "Access-Control-Request-Method: GET" \
  "$API_URL/api/precipitations" | tr -d '\r')" || fail "preflight CORS"
case "$cors" in
  *"ccess-control-allow-origin: $FRONTEND_URL"*) ok "CORS permite $FRONTEND_URL" ;;
  *) fail "CORS no permite $FRONTEND_URL (revisar APP_CORS_ORIGINS en Render)" ;;
esac

echo "==> Pruebas de humo [$ENVIRONMENT] superadas"
