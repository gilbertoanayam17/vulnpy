#!/usr/bin/env bash
#
# Sube un reporte de escaneo a DefectDojo usando la API v2 (/api/v2/import-scan/).
#
# Uso:
#   scripts/upload_defectdojo.sh [archivo] [tipo_de_escaneo]
#   scripts/upload_defectdojo.sh sca-results.json "Safety Scan"
#
# Variables (desde el entorno, o desde un .env en la raíz del repo si existe):
#   DEFECTDOJO_URL            URL de la instancia (por defecto https://demo.defectdojo.org)
#   DEFECTDOJO_API_KEY        API key v2 (se envía como "Authorization: Token <key>")
#   DEFECTDOJO_AUTH_HEADER    Alternativa: el valor completo del header, p. ej. "Token abc123..."
#   DEFECTDOJO_PRODUCT_TYPE   Tipo de producto (se crea si no existe)
#   DEFECTDOJO_PRODUCT        Producto (se crea si no existe)
#   DEFECTDOJO_ENGAGEMENT     Engagement (se crea si no existe)
#
# Las variables que ya existen en el entorno tienen prioridad sobre el .env,
# así en GitHub Actions mandan los secrets y en local manda el .env.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

# Carga el .env sin ejecutarlo como código (no se usa `source`).
if [[ -f "$ENV_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                       # tolera finales de línea de Windows
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; key="${key//[[:space:]]/}"; key="${key#export}"
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"  # quita espacios al inicio
    value="${value%"${value##*[![:space:]]}"}"  # quita espacios al final
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -z "${!key:-}" ]]; then
      export "$key=$value"
    fi
  done < "$ENV_FILE"
fi

REPORT_FILE="${1:-sca-results.json}"
SCAN_TYPE="${2:-Safety Scan}"

DEFECTDOJO_URL="${DEFECTDOJO_URL:-https://demo.defectdojo.org}"
DEFECTDOJO_URL="${DEFECTDOJO_URL%/}"
DEFECTDOJO_PRODUCT_TYPE="${DEFECTDOJO_PRODUCT_TYPE:-Research and Development}"
DEFECTDOJO_PRODUCT="${DEFECTDOJO_PRODUCT:-vulnpy}"
DEFECTDOJO_ENGAGEMENT="${DEFECTDOJO_ENGAGEMENT:-CI/CD - GitHub Actions}"

if [[ -n "${DEFECTDOJO_AUTH_HEADER:-}" ]]; then
  AUTH_HEADER="$DEFECTDOJO_AUTH_HEADER"
elif [[ -n "${DEFECTDOJO_API_KEY:-}" ]]; then
  AUTH_HEADER="Token $DEFECTDOJO_API_KEY"
else
  echo "ERROR: define DEFECTDOJO_API_KEY o DEFECTDOJO_AUTH_HEADER (en .env o como secret)." >&2
  exit 1
fi

if [[ ! -s "$REPORT_FILE" ]]; then
  echo "ERROR: el reporte '$REPORT_FILE' no existe o está vacío." >&2
  exit 1
fi

# Metadatos del pipeline (GitHub Actions los expone; en local quedan vacíos).
extra_fields=()
[[ -n "${GITHUB_RUN_ID:-}"   ]] && extra_fields+=(--form-string "build_id=${GITHUB_RUN_ID}")
[[ -n "${GITHUB_SHA:-}"      ]] && extra_fields+=(--form-string "commit_hash=${GITHUB_SHA}")
[[ -n "${GITHUB_REF_NAME:-}" ]] && extra_fields+=(--form-string "branch_tag=${GITHUB_REF_NAME}")
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  extra_fields+=(--form-string "source_code_management_uri=${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}")
fi

RESPONSE_FILE="$(mktemp)"
trap 'rm -f "$RESPONSE_FILE"' EXIT

echo "Subiendo '$REPORT_FILE' ($SCAN_TYPE) a $DEFECTDOJO_URL"
echo "  Producto:   $DEFECTDOJO_PRODUCT ($DEFECTDOJO_PRODUCT_TYPE)"
echo "  Engagement: $DEFECTDOJO_ENGAGEMENT"

HTTP_CODE="$(curl -sS -o "$RESPONSE_FILE" -w '%{http_code}' \
  -X POST "$DEFECTDOJO_URL/api/v2/import-scan/" \
  -H "Authorization: $AUTH_HEADER" \
  -H "Accept: application/json" \
  -F "file=@${REPORT_FILE}" \
  --form-string "scan_type=$SCAN_TYPE" \
  --form-string "product_type_name=$DEFECTDOJO_PRODUCT_TYPE" \
  --form-string "product_name=$DEFECTDOJO_PRODUCT" \
  --form-string "engagement_name=$DEFECTDOJO_ENGAGEMENT" \
  --form-string "auto_create_context=true" \
  --form-string "active=true" \
  --form-string "verified=false" \
  --form-string "minimum_severity=Info" \
  --form-string "scan_date=$(date -u +%Y-%m-%d)" \
  --form-string "test_title=SCA - Safety ($(date -u +%Y-%m-%dT%H:%MZ))" \
  "${extra_fields[@]}")"

if [[ "$HTTP_CODE" != 2* ]]; then
  echo "ERROR: DefectDojo respondió HTTP $HTTP_CODE" >&2
  cat "$RESPONSE_FILE" >&2; echo >&2
  exit 1
fi

TEST_ID="$(grep -oE '"test(_id)?"[[:space:]]*:[[:space:]]*[0-9]+' "$RESPONSE_FILE" | head -1 | grep -oE '[0-9]+$' || true)"
echo "OK (HTTP $HTTP_CODE)"
if [[ -n "$TEST_ID" ]]; then
  echo "Resultados: $DEFECTDOJO_URL/test/$TEST_ID"
fi
