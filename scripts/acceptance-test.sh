#!/usr/bin/env sh
# Pruebas de aceptación de las operaciones principales. Escriben datos, por eso NO se ejecutan en PDN.
# Usan una fecha fija de pruebas (2000-01-01) para no mezclarse con los datos del día.
# Uso: ./scripts/acceptance-test.sh dev|qa
set -eu

ENVIRONMENT="${1:?Uso: ./scripts/acceptance-test.sh dev|qa}"
[ "$ENVIRONMENT" = "prod" ] && { echo "No se ejecutan pruebas de escritura en PDN" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/deploy/$ENVIRONMENT.env"

TEST_DATE="2000-01-01"
TAG="ACEPTACION-${BUILD_NUMBER:-local}-$(date +%s)"

fail() { echo "  FALLO: $1" >&2; exit 1; }
ok() { echo "  OK: $1"; }
post() { curl -fsS --max-time 30 -X "${3:-POST}" -H 'Content-Type: application/json' -d "$2" "$API_URL$1"; }

echo "==> Pruebas de aceptación [$ENVIRONMENT] etiqueta $TAG"

post /api/precipitations "{\"recordDate\":\"$TEST_DATE\",\"sector\":\"$TAG\",\"stationName\":\"Estación pruebas\",\"precipitationMm\":12.5,\"source\":\"pipeline\"}" > /dev/null \
  || fail "registrar precipitación"
curl -fsS "$API_URL/api/precipitations?date=$TEST_DATE" | grep -q "$TAG" || fail "consultar precipitación registrada"
ok "registrar y consultar precipitación"

traffic="$(post /api/traffic-incidents "{\"recordDate\":\"$TEST_DATE\",\"recordTime\":\"08:30:00\",\"sector\":\"$TAG\",\"locationDescription\":\"Av. Santander\",\"congestionLevel\":\"ALTO\",\"cause\":\"LLUVIA\",\"status\":\"REPORTADO\"}")" \
  || fail "registrar incidente de tráfico"
traffic_id="$(echo "$traffic" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')"
[ -n "$traffic_id" ] || fail "el incidente creado no devolvió id"
post "/api/traffic-incidents/$traffic_id/status" '{"status":"CERRADO"}' PATCH | grep -q '"status":"CERRADO"' \
  || fail "cambiar estado del incidente"
ok "registrar incidente y cambiar su estado"

post /api/landslides "{\"recordDate\":\"$TEST_DATE\",\"recordTime\":\"09:00:00\",\"sector\":\"$TAG\",\"locationDescription\":\"Ladera de pruebas\",\"severity\":\"MEDIA\",\"affectedArea\":\"VIA\",\"status\":\"REPORTADO\"}" > /dev/null \
  || fail "registrar deslizamiento"
ok "registrar deslizamiento"

summary="$(curl -fsS "$API_URL/api/dashboard/summary?date=$TEST_DATE")" || fail "consultar resumen"
case "$summary" in
  *'"trafficIncidents":0'*|*'"landslides":0'*|*'"precipitationRecords":0'*) fail "el resumen no refleja los registros: $summary" ;;
esac
ok "el resumen diario refleja los registros"

echo "==> Pruebas de aceptación [$ENVIRONMENT] superadas"
