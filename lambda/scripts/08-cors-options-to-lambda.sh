#!/usr/bin/env bash
# ================================================================
# ETAPA 1.3.1 — Migra OPTIONS de MOCK pra AWS_PROXY (Lambda)
# ================================================================
# Por quê: o MOCK integration response precisa de Access-Control-Allow-Origin
# ESTÁTICO no header. Pra suportar múltiplos origins dinamicamente,
# delegamos o preflight OPTIONS ao Lambda — que já sabe escolher o origin
# correto baseado no header da request.
#
# Custo extra: Lambda invocação no preflight (~1x por sessão, cacheado pelo browser).
# ~$0.001/mês a 30 preflights/dia. Desprezível.
# ================================================================
set -euo pipefail

cd "$(dirname "$0")"
source ./_env.sh

echo "======================================"
echo " Migra OPTIONS MOCK → AWS_PROXY (Lambda)"
echo "======================================"

API_ID="$(state_get api_id)"
API_STAGE="$(state_get api_stage)"
LAMBDA_ARN="$(state_get lambda_arn)"

if [ -z "${API_ID}" ] || [ -z "${LAMBDA_ARN}" ]; then
  echo "❌ api_id/lambda_arn não encontrados em .state.json"
  exit 1
fi

LAMBDA_URI="arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"
echo "API:    ${API_ID}"
echo "Lambda: ${LAMBDA_ARN}"
echo ""

# --- Pega resource IDs pelos paths ---
echo "→ descobrindo resource IDs..."
RES_INDEX=$(aws apigateway get-resources --rest-api-id "${API_ID}" --region "${AWS_REGION}" \
  --query "items[?path=='/face/index'].id" --output text)
RES_SEARCH=$(aws apigateway get-resources --rest-api-id "${API_ID}" --region "${AWS_REGION}" \
  --query "items[?path=='/face/search'].id" --output text)
RES_FACEID=$(aws apigateway get-resources --rest-api-id "${API_ID}" --region "${AWS_REGION}" \
  --query "items[?path=='/face/{faceId}'].id" --output text)

for n in "/face/index:${RES_INDEX}" "/face/search:${RES_SEARCH}" "/face/{faceId}:${RES_FACEID}"; do
  echo "   ${n}"
done

migrate_options() {
  local resource_id="$1"
  local path_label="$2"

  echo ""
  echo "── ${path_label} ──"

  # 1. Deleta integration-response OPTIONS 200 (do MOCK) — ignora se não existe
  aws apigateway delete-integration-response \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "OPTIONS" \
    --status-code "200" \
    --region "${AWS_REGION}" \
    --no-cli-pager 2>/dev/null && echo "   ✓ integration-response MOCK removida" || echo "   · integration-response já estava limpa"

  # 2. Deleta integration OPTIONS (MOCK)
  aws apigateway delete-integration \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "OPTIONS" \
    --region "${AWS_REGION}" \
    --no-cli-pager 2>/dev/null && echo "   ✓ integration MOCK removida" || echo "   · integration já estava limpa"

  # 3. Re-cria method OPTIONS (idempotente — mesma config de antes)
  aws apigateway delete-method \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "OPTIONS" \
    --region "${AWS_REGION}" \
    --no-cli-pager 2>/dev/null || true

  aws apigateway put-method \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "OPTIONS" \
    --authorization-type "NONE" \
    --no-api-key-required \
    --region "${AWS_REGION}" \
    --no-cli-pager > /dev/null
  echo "   ✓ método OPTIONS recriado (NONE auth, sem api-key)"

  # 4. Nova integration: AWS_PROXY pra Lambda
  aws apigateway put-integration \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "OPTIONS" \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "${LAMBDA_URI}" \
    --region "${AWS_REGION}" \
    --no-cli-pager > /dev/null
  echo "   ✓ integration AWS_PROXY → Lambda"

  # 5. Method-response 200 (AWS_PROXY não usa integration-response, mas método precisa declarar status)
  aws apigateway put-method-response \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "OPTIONS" \
    --status-code "200" \
    --region "${AWS_REGION}" \
    --no-cli-pager > /dev/null
  echo "   ✓ method-response 200 declarado"
}

# --- Aplica nos 3 resources ---
migrate_options "${RES_INDEX}"  "/face/index"
migrate_options "${RES_SEARCH}" "/face/search"
migrate_options "${RES_FACEID}" "/face/{faceId}"

# --- Lambda já tem permissão do API Gateway (apigw-invoke statement-id),
# criada em 03-api-gateway.sh. Idempotência: re-aplicar pra garantir ---
echo ""
echo "→ reconfirmando permissão Lambda (idempotente)..."
aws lambda remove-permission \
  --function-name "${LAMBDA_NAME}" \
  --statement-id "apigw-invoke" \
  --region "${AWS_REGION}" 2>/dev/null || true
aws lambda add-permission \
  --function-name "${LAMBDA_NAME}" \
  --statement-id "apigw-invoke" \
  --action "lambda:InvokeFunction" \
  --principal "apigateway.amazonaws.com" \
  --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
  --region "${AWS_REGION}" \
  --no-cli-pager > /dev/null
echo "   ✓ permissão ok"

# --- Redeploy stage ---
echo ""
echo "→ redeploying stage '${API_STAGE}'..."
DEPLOYMENT_ID=$(aws apigateway create-deployment \
  --rest-api-id "${API_ID}" \
  --stage-name "${API_STAGE}" \
  --description "OPTIONS migrated to Lambda AWS_PROXY ($(date -u +%Y-%m-%dT%H:%M:%SZ))" \
  --region "${AWS_REGION}" \
  --query 'id' --output text)
echo "   ✓ deployment: ${DEPLOYMENT_ID}"

# --- Teste rápido ---
echo ""
echo "→ aguardando 5s pra propagar..."
sleep 5

INVOKE_URL="$(state_get api_invoke_url)"
ALLOWED_ORIGIN_A="https://ivancsilveira.github.io"
ALLOWED_ORIGIN_B="http://localhost:8080"

echo ""
echo "→ CORS preflight test (localhost):"
OUT=$(curl -s -D - -o /dev/null \
  -X OPTIONS "${INVOKE_URL}/face/search" \
  -H "Origin: ${ALLOWED_ORIGIN_B}" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Content-Type,X-Api-Key")
echo "${OUT}" | grep -iE "^HTTP|Access-Control-Allow-" | sed 's/^/   /'
if echo "${OUT}" | grep -qi "Access-Control-Allow-Origin: ${ALLOWED_ORIGIN_B}"; then
  echo "   ✅ localhost preflight passa"
else
  echo "   ⚠ preflight não retornou Allow-Origin: ${ALLOWED_ORIGIN_B}"
fi

echo ""
echo "→ CORS preflight test (GitHub Pages):"
OUT2=$(curl -s -D - -o /dev/null \
  -X OPTIONS "${INVOKE_URL}/face/search" \
  -H "Origin: ${ALLOWED_ORIGIN_A}" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Content-Type,X-Api-Key")
echo "${OUT2}" | grep -iE "^HTTP|Access-Control-Allow-" | sed 's/^/   /'
if echo "${OUT2}" | grep -qi "Access-Control-Allow-Origin: ${ALLOWED_ORIGIN_A}"; then
  echo "   ✅ github.io preflight passa"
else
  echo "   ⚠ preflight não retornou Allow-Origin: ${ALLOWED_ORIGIN_A}"
fi

echo ""
echo "✅ Script 08 concluído."
echo "   Hard-refresh no browser e teste de novo o cadastro de biometria."
