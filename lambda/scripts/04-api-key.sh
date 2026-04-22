#!/usr/bin/env bash
# ================================================================
# ETAPA 1.4 — API Key + Usage Plan
# ================================================================
# Cria:
#   - API Key "pontofacil-github-pages-key" (valor auto-gerado pela AWS)
#   - Usage Plan "pontofacil-usage-plan":
#       throttle: 20 req/s sustained, 40 burst
#       quota:    10000 requests / dia
#   - Associa stage prod ao plan
#   - Associa API key ao plan
#
# IDEMPOTENTE: se já existir, deleta e recria.
# ================================================================
#
# ⚠  NOTA DE SEGURANÇA — por que API Key em GitHub Pages é OK (com ressalvas):
#
# O valor da API key vai precisar estar embutido no index.html (site público).
# Qualquer um consegue ver com "View Source". Isso NÃO é um defeito do script,
# é uma decisão arquitetural desta fase. A mitigação se faz em CAMADAS:
#
#   1. WAF (etapa 1.5) bloqueia Origin ≠ ivancsilveira.github.io
#   2. Usage Plan limita a 10k req/dia → um atacante enche a quota, daí nada
#   3. Lambda valida Origin em runtime (defense-in-depth)
#   4. Rekognition é escopado ao collection e ações mínimas
#
# Se quisermos auth mais robusta no futuro: Cognito Identity Pool
# (token STS temporário por sessão) ou JWT assinado pelo Firebase.
# ================================================================
set -euo pipefail

cd "$(dirname "$0")"
source ./_env.sh

echo "======================================"
echo " ETAPA 1.4 — API Key + Usage Plan"
echo "======================================"

API_ID="$(state_get api_id)"
API_STAGE="$(state_get api_stage)"
INVOKE_URL="$(state_get api_invoke_url)"
if [ -z "${API_ID}" ] || [ -z "${API_STAGE}" ]; then
  echo "❌ api_id/api_stage não encontrados em .state.json"
  echo "   Rode primeiro: bash lambda/scripts/03-api-gateway.sh"
  exit 1
fi
echo "API ID:     ${API_ID}"
echo "Stage:      ${API_STAGE}"
echo ""

# --- 1. Deleta API Key anterior se existir ---
EXISTING_KEY_ID=$(aws apigateway get-api-keys \
  --region "${AWS_REGION}" \
  --query "items[?name=='${API_KEY_NAME}'].id | [0]" \
  --output text 2>/dev/null || echo "")

if [ -n "${EXISTING_KEY_ID}" ] && [ "${EXISTING_KEY_ID}" != "None" ] && [ "${EXISTING_KEY_ID}" != "null" ]; then
  echo "⚠  API Key '${API_KEY_NAME}' já existe (${EXISTING_KEY_ID}) — deletando..."
  aws apigateway delete-api-key \
    --api-key "${EXISTING_KEY_ID}" \
    --region "${AWS_REGION}" \
    --no-cli-pager
  echo "   ✓ deletada"
fi

# --- 2. Deleta Usage Plan anterior se existir ---
EXISTING_PLAN_ID=$(aws apigateway get-usage-plans \
  --region "${AWS_REGION}" \
  --query "items[?name=='${USAGE_PLAN_NAME}'].id | [0]" \
  --output text 2>/dev/null || echo "")

if [ -n "${EXISTING_PLAN_ID}" ] && [ "${EXISTING_PLAN_ID}" != "None" ] && [ "${EXISTING_PLAN_ID}" != "null" ]; then
  echo "⚠  Usage Plan '${USAGE_PLAN_NAME}' já existe (${EXISTING_PLAN_ID}) — deletando..."
  # Antes de deletar, precisa remover todas as usage-plan-keys associadas
  for k in $(aws apigateway get-usage-plan-keys --usage-plan-id "${EXISTING_PLAN_ID}" --region "${AWS_REGION}" --query 'items[].id' --output text 2>/dev/null); do
    aws apigateway delete-usage-plan-key --usage-plan-id "${EXISTING_PLAN_ID}" --key-id "${k}" --region "${AWS_REGION}" 2>/dev/null || true
  done
  aws apigateway delete-usage-plan \
    --usage-plan-id "${EXISTING_PLAN_ID}" \
    --region "${AWS_REGION}" \
    --no-cli-pager
  echo "   ✓ deletado"
fi

# --- 3. Cria API Key (valor auto-gerado) ---
echo ""
echo "→ criando API Key '${API_KEY_NAME}'..."
API_KEY_ID=$(aws apigateway create-api-key \
  --name "${API_KEY_NAME}" \
  --description "API key para frontend GitHub Pages (PontoFácil)" \
  --enabled \
  --tags "project=${PROJECT}" \
  --region "${AWS_REGION}" \
  --query 'id' --output text)
echo "   ✓ API Key ID: ${API_KEY_ID}"

# Pega o valor em si (só agora — create-api-key não retorna 'value' por padrão)
API_KEY_VALUE=$(aws apigateway get-api-key \
  --api-key "${API_KEY_ID}" \
  --include-value \
  --region "${AWS_REGION}" \
  --query 'value' --output text)

# --- 4. Cria Usage Plan ---
echo ""
echo "→ criando Usage Plan '${USAGE_PLAN_NAME}'..."
USAGE_PLAN_ID=$(aws apigateway create-usage-plan \
  --name "${USAGE_PLAN_NAME}" \
  --description "PontoFácil — 20 req/s sustained, 40 burst, 10k/dia" \
  --throttle "burstLimit=40,rateLimit=20" \
  --quota "limit=10000,period=DAY" \
  --tags "project=${PROJECT}" \
  --region "${AWS_REGION}" \
  --query 'id' --output text)
echo "   ✓ Usage Plan ID: ${USAGE_PLAN_ID}"

# --- 5. Associa stage ao Usage Plan ---
echo ""
echo "→ associando stage '${API_STAGE}' ao Usage Plan..."
aws apigateway update-usage-plan \
  --usage-plan-id "${USAGE_PLAN_ID}" \
  --patch-operations "op=add,path=/apiStages,value=${API_ID}:${API_STAGE}" \
  --region "${AWS_REGION}" \
  --no-cli-pager > /dev/null
echo "   ✓ stage associado"

# --- 6. Associa API Key ao Usage Plan ---
echo ""
echo "→ associando API Key ao Usage Plan..."
aws apigateway create-usage-plan-key \
  --usage-plan-id "${USAGE_PLAN_ID}" \
  --key-id "${API_KEY_ID}" \
  --key-type "API_KEY" \
  --region "${AWS_REGION}" \
  --no-cli-pager > /dev/null
echo "   ✓ key associada"

# --- 7. Salva no state ---
state_set api_key_id "${API_KEY_ID}"
state_set api_key_value "${API_KEY_VALUE}"
state_set usage_plan_id "${USAGE_PLAN_ID}"

echo ""
echo "✅ ETAPA 1.4 concluída."
echo ""
echo "   API Key ID:     ${API_KEY_ID}"
echo "   Usage Plan ID:  ${USAGE_PLAN_ID}"
echo "   Throttle:       20 req/s rate · 40 burst"
echo "   Quota:          10.000 req/dia"
echo ""
echo "══════════════════════════════════════════════════════════════"
echo " 🔑 API KEY VALUE (guardar — vai no frontend depois):"
echo ""
echo "   ${API_KEY_VALUE}"
echo ""
echo " Salvo em: lambda/scripts/.state.json (gitignored)"
echo "══════════════════════════════════════════════════════════════"
echo ""

# --- 8. Testes rápidos ---
echo "→ teste sem API Key (esperado: 403)..."
HTTP_NOKEY=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${INVOKE_URL}/face/search" \
  -H "Content-Type: application/json" \
  -H "Origin: ${ALLOWED_ORIGIN}" \
  -d '{"imageBase64":"x"}')
echo "   HTTP ${HTTP_NOKEY} $([ "${HTTP_NOKEY}" = "403" ] && echo "✓" || echo "⚠ esperava 403")"

echo "→ teste com API Key + imagem inválida (esperado: 400 invalid_image)..."
sleep 5  # usage plan association demora alguns segundos pra propagar
RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
  -X POST "${INVOKE_URL}/face/search" \
  -H "Content-Type: application/json" \
  -H "Origin: ${ALLOWED_ORIGIN}" \
  -H "X-Api-Key: ${API_KEY_VALUE}" \
  -d '{"imageBase64":"this-is-not-valid-base64-image-data"}')
echo "   resposta:"
echo "${RESP}" | sed 's/^/     /'
echo ""
echo "   (se veio \"error\":\"invalid_image\" — OK: API key funciona, Lambda responde)"
echo "   (se veio \"error\":\"internal_error\" — Rekognition rejeitou o blob, que tb é evidência de que passou pela Lambda)"

echo ""
echo "Próximo passo: bash lambda/scripts/05-waf.sh"
