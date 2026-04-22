#!/usr/bin/env bash
# ================================================================
# ETAPA 1.6 — Smoke tests end-to-end
# ================================================================
# Duas seções:
#
# Section A — testes que exigem só a infra (sem imagem real):
#   A1. Sem Origin                  → 403  (WAF bloqueia)
#   A2. Origin errado               → 403  (WAF bloqueia)
#   A3. Origin ok, sem API key      → 403  (API Gateway bloqueia)
#   A4. Cadeia completa, body inválido → 400 (Lambda valida)
#
# Section B — testes Rekognition end-to-end (precisa TEST_IMAGE):
#   B1. POST /face/index com imagem real    → 200 + faceId
#   B2. POST /face/search mesma imagem      → match com o mesmo faceId
#   B3. DELETE /face/{faceId}               → deleted=1
#   B4. POST /face/search após delete       → sem matches
#
# Como rodar a section B:
#   1. Tira uma selfie, salva em ~/face-test.jpg (ou use qualquer foto clara de rosto)
#   2. export TEST_IMAGE=~/face-test.jpg
#   3. bash lambda/scripts/06-smoke-tests.sh
#
# Sem TEST_IMAGE, só a section A roda.
# ================================================================
set -uo pipefail  # sem -e: queremos continuar mesmo com teste falhando

cd "$(dirname "$0")"
source ./_env.sh

INVOKE_URL="$(state_get api_invoke_url)"
API_KEY_VALUE="$(state_get api_key_value)"

if [ -z "${INVOKE_URL}" ] || [ -z "${API_KEY_VALUE}" ]; then
  echo "❌ state incompleto — rode 01 a 05 antes"
  exit 1
fi

echo "============================================"
echo " ETAPA 1.6 — Smoke tests"
echo "============================================"
echo "URL: ${INVOKE_URL}"
echo ""

PASS=0
FAIL=0
FAIL_NAMES=""

# ---- helper: roda um curl e compara HTTP status ----
# Uso: expect_http NOME ESPERADO_STATUS [opções curl]
expect_http() {
  local name="$1"
  local expect="$2"
  shift 2
  local body_file; body_file=$(mktemp)
  local got
  got=$(curl -s --max-time 15 -o "${body_file}" -w "%{http_code}" "$@") || got="000"
  local body; body=$(cat "${body_file}")
  rm -f "${body_file}"
  if [ "${got}" = "${expect}" ]; then
    echo "  ✅ ${name} → HTTP ${got}"
    PASS=$((PASS+1))
    echo "${body}"  # printa body pra referência (chamador captura)
  else
    echo "  ❌ ${name} → HTTP ${got} (esperava ${expect})"
    echo "     body: ${body}"
    FAIL=$((FAIL+1))
    FAIL_NAMES="${FAIL_NAMES} ${name}"
    echo ""  # empty on fail
  fi
}

# ================================================================
# Section A — testes básicos (sem imagem)
# ================================================================
echo "── Section A: infra (sem imagem) ──────────────────"

echo ""
echo "A1. sem Origin header:"
expect_http "A1_no_origin" "403" \
  -X POST "${INVOKE_URL}/face/search" \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: ${API_KEY_VALUE}" \
  -d '{"imageBase64":"x"}' > /dev/null

echo ""
echo "A2. Origin errado (evil.com):"
expect_http "A2_wrong_origin" "403" \
  -X POST "${INVOKE_URL}/face/search" \
  -H "Content-Type: application/json" \
  -H "Origin: https://evil.example.com" \
  -H "X-Api-Key: ${API_KEY_VALUE}" \
  -d '{"imageBase64":"x"}' > /dev/null

echo ""
echo "A3. Origin ok, sem X-Api-Key:"
expect_http "A3_no_api_key" "403" \
  -X POST "${INVOKE_URL}/face/search" \
  -H "Content-Type: application/json" \
  -H "Origin: ${ALLOWED_ORIGIN}" \
  -d '{"imageBase64":"x"}' > /dev/null

echo ""
echo "A4. cadeia completa + body base64 inválido:"
expect_http "A4_invalid_body" "400" \
  -X POST "${INVOKE_URL}/face/search" \
  -H "Content-Type: application/json" \
  -H "Origin: ${ALLOWED_ORIGIN}" \
  -H "X-Api-Key: ${API_KEY_VALUE}" \
  -d '{"imageBase64":"not_a_real_image"}' > /dev/null

# ================================================================
# Section B — Rekognition (exige TEST_IMAGE)
# ================================================================
echo ""
echo "── Section B: Rekognition end-to-end ──────────────"
TEST_IMAGE="${TEST_IMAGE:-}"
if [ -z "${TEST_IMAGE}" ] || [ ! -f "${TEST_IMAGE}" ]; then
  echo ""
  echo "  ⏭  SKIP: defina TEST_IMAGE=/path/pra/selfie.jpg pra testar"
  echo "     exemplo: export TEST_IMAGE=\$HOME/face-test.jpg"
else
  echo ""
  echo "  usando: ${TEST_IMAGE}"
  IMG_SIZE=$(wc -c < "${TEST_IMAGE}" | tr -d ' ')
  IMG_KB=$((IMG_SIZE/1024))
  echo "  tamanho: ${IMG_KB} KB"

  EXT_ID="smoketest-$(date +%s)-$$"
  PAYLOAD_FILE=$(mktemp)

  python3 - "${TEST_IMAGE}" "${EXT_ID}" > "${PAYLOAD_FILE}" <<'PYEOF'
import sys, json, base64
path, ext_id = sys.argv[1], sys.argv[2]
with open(path, 'rb') as f:
    b64 = base64.b64encode(f.read()).decode('ascii')
print(json.dumps({'imageBase64': b64, 'externalImageId': ext_id}))
PYEOF

  echo ""
  echo "B1. POST /face/index (external_image_id=${EXT_ID}):"
  INDEX_BODY=$(curl -s --max-time 20 \
    -X POST "${INVOKE_URL}/face/index" \
    -H "Content-Type: application/json" \
    -H "Origin: ${ALLOWED_ORIGIN}" \
    -H "X-Api-Key: ${API_KEY_VALUE}" \
    --data-binary "@${PAYLOAD_FILE}")
  echo "    resposta: ${INDEX_BODY}"
  FACE_ID=$(echo "${INDEX_BODY}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('faceId',''))" 2>/dev/null || echo "")
  if [ -n "${FACE_ID}" ]; then
    echo "  ✅ B1_index → faceId=${FACE_ID}"
    PASS=$((PASS+1))
  else
    echo "  ❌ B1_index → falhou (body: ${INDEX_BODY})"
    FAIL=$((FAIL+1))
    FAIL_NAMES="${FAIL_NAMES} B1_index"
  fi

  # Rebuild payload for search (sem externalImageId)
  PAYLOAD_SEARCH=$(mktemp)
  python3 - "${TEST_IMAGE}" > "${PAYLOAD_SEARCH}" <<'PYEOF'
import sys, json, base64
with open(sys.argv[1], 'rb') as f:
    b64 = base64.b64encode(f.read()).decode('ascii')
print(json.dumps({'imageBase64': b64}))
PYEOF

  echo ""
  echo "B2. POST /face/search com mesma imagem:"
  SEARCH_BODY=$(curl -s --max-time 20 \
    -X POST "${INVOKE_URL}/face/search" \
    -H "Content-Type: application/json" \
    -H "Origin: ${ALLOWED_ORIGIN}" \
    -H "X-Api-Key: ${API_KEY_VALUE}" \
    --data-binary "@${PAYLOAD_SEARCH}")
  echo "    resposta: ${SEARCH_BODY}"
  TOP_SIM=$(echo "${SEARCH_BODY}" | python3 -c "import json,sys; d=json.load(sys.stdin); m=d.get('matches',[]); print(m[0]['similarity'] if m else '')" 2>/dev/null || echo "")
  TOP_EXT=$(echo "${SEARCH_BODY}" | python3 -c "import json,sys; d=json.load(sys.stdin); m=d.get('matches',[]); print(m[0]['externalImageId'] if m else '')" 2>/dev/null || echo "")
  if [ -n "${TOP_SIM}" ] && [ "${TOP_EXT}" = "${EXT_ID}" ]; then
    echo "  ✅ B2_search → match=${EXT_ID} (sim=${TOP_SIM}%)"
    PASS=$((PASS+1))
  else
    echo "  ❌ B2_search → não encontrou o rosto recém-indexado"
    FAIL=$((FAIL+1))
    FAIL_NAMES="${FAIL_NAMES} B2_search"
  fi

  echo ""
  echo "B3. DELETE /face/${FACE_ID}:"
  if [ -z "${FACE_ID}" ]; then
    echo "  ⏭  SKIP (B1 falhou, sem faceId pra deletar)"
  else
    DEL_BODY=$(curl -s --max-time 15 \
      -X DELETE "${INVOKE_URL}/face/${FACE_ID}" \
      -H "Origin: ${ALLOWED_ORIGIN}" \
      -H "X-Api-Key: ${API_KEY_VALUE}")
    echo "    resposta: ${DEL_BODY}"
    DELETED=$(echo "${DEL_BODY}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('deleted',0))" 2>/dev/null || echo "0")
    if [ "${DELETED}" = "1" ]; then
      echo "  ✅ B3_delete → deleted=1"
      PASS=$((PASS+1))
    else
      echo "  ❌ B3_delete → não deletou"
      FAIL=$((FAIL+1))
      FAIL_NAMES="${FAIL_NAMES} B3_delete"
    fi
  fi

  echo ""
  echo "B4. POST /face/search após delete (esperado: sem matches):"
  SEARCH2=$(curl -s --max-time 20 \
    -X POST "${INVOKE_URL}/face/search" \
    -H "Content-Type: application/json" \
    -H "Origin: ${ALLOWED_ORIGIN}" \
    -H "X-Api-Key: ${API_KEY_VALUE}" \
    --data-binary "@${PAYLOAD_SEARCH}")
  echo "    resposta: ${SEARCH2}"
  MATCH_COUNT=$(echo "${SEARCH2}" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('matches',[])))" 2>/dev/null || echo "?")
  if [ "${MATCH_COUNT}" = "0" ]; then
    echo "  ✅ B4_search_after_delete → 0 matches"
    PASS=$((PASS+1))
  else
    echo "  ❌ B4_search_after_delete → veio ${MATCH_COUNT} matches (esperava 0)"
    FAIL=$((FAIL+1))
    FAIL_NAMES="${FAIL_NAMES} B4_search_after_delete"
  fi

  rm -f "${PAYLOAD_FILE}" "${PAYLOAD_SEARCH}"
fi

# ================================================================
# Resumo
# ================================================================
echo ""
echo "════════════════════════════════════════════"
TOTAL=$((PASS+FAIL))
echo " resultado: ${PASS}/${TOTAL} passaram"
if [ "${FAIL}" -gt 0 ]; then
  echo " falhas:   ${FAIL_NAMES}"
  exit 1
else
  echo " ✅ infra 100% funcional"
  echo ""
  echo " Próximos passos (quando autorizar):"
  echo "   ETAPA 2 — código Lambda (pronto ✓)"
  echo "   ETAPA 3 — modificar index.html"
  echo "   ETAPA 4 — schema Firebase"
fi
