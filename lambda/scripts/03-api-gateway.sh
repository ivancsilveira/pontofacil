#!/usr/bin/env bash
# ================================================================
# ETAPA 1.3 — API Gateway REST + integração Lambda + CORS
# ================================================================
# Cria:
#   REST API "pontofacil-face-api" (regional)
#   ├── /face
#   │   ├── /index      [POST]  → Lambda (API Key required)
#   │   ├── /index      [OPTIONS] → MOCK (CORS preflight)
#   │   ├── /search     [POST]  → Lambda (API Key required)
#   │   ├── /search     [OPTIONS] → MOCK (CORS preflight)
#   │   ├── /{faceId}   [DELETE] → Lambda (API Key required)
#   │   └── /{faceId}   [OPTIONS] → MOCK (CORS preflight)
#   Stage: prod
#
# Depois:
#   - Lambda permission pra API Gateway invocar
#   - Deploy para stage prod
#   - Salva API_ID + INVOKE_URL em .state.json
#
# IDEMPOTENTE: se a API já existe com esse nome, é deletada e recriada
# (ainda não temos tráfego de produção, é seguro).
# ================================================================
set -euo pipefail

cd "$(dirname "$0")"
source ./_env.sh

STAGE="prod"

echo "======================================"
echo " ETAPA 1.3 — API Gateway REST"
echo "======================================"

# --- valida que Lambda existe (foi criada no 1.2) ---
LAMBDA_ARN="$(state_get lambda_arn)"
if [ -z "${LAMBDA_ARN}" ]; then
  echo "❌ lambda_arn não encontrado em .state.json"
  echo "   Rode primeiro: bash lambda/scripts/02-deploy-lambda.sh"
  exit 1
fi
echo "Lambda:     ${LAMBDA_ARN}"
echo "Stage:      ${STAGE}"
echo "CORS orig:  ${ALLOWED_ORIGIN}"
echo ""

# --- 0. Se já existe API com esse nome, deleta ---
EXISTING_ID=$(aws apigateway get-rest-apis \
  --region "${AWS_REGION}" \
  --query "items[?name=='${API_NAME}'].id | [0]" \
  --output text 2>/dev/null || echo "")

if [ -n "${EXISTING_ID}" ] && [ "${EXISTING_ID}" != "None" ] && [ "${EXISTING_ID}" != "null" ]; then
  echo "⚠  API '${API_NAME}' já existe (id=${EXISTING_ID}) — deletando p/ recriar..."
  aws apigateway delete-rest-api \
    --rest-api-id "${EXISTING_ID}" \
    --region "${AWS_REGION}" \
    --no-cli-pager
  echo "   ✓ deletada. Esperando 35s (rate limit de criação da AWS)..."
  sleep 35
fi

# --- 1. Cria REST API regional ---
echo ""
echo "→ criando REST API '${API_NAME}'..."
API_ID=$(aws apigateway create-rest-api \
  --name "${API_NAME}" \
  --description "Backend Rekognition pra PontoFácil — só chamado do GitHub Pages" \
  --endpoint-configuration "types=REGIONAL" \
  --tags "project=${PROJECT}" \
  --region "${AWS_REGION}" \
  --query 'id' --output text)
echo "   ✓ API ID: ${API_ID}"

# --- 2. Root resource ID ---
ROOT_ID=$(aws apigateway get-resources \
  --rest-api-id "${API_ID}" \
  --region "${AWS_REGION}" \
  --query 'items[?path==`/`].id' --output text)
echo "   root: ${ROOT_ID}"

# --- 3. Cria hierarquia de resources ---
echo ""
echo "→ criando resources..."
FACE_ID=$(aws apigateway create-resource \
  --rest-api-id "${API_ID}" --parent-id "${ROOT_ID}" --path-part "face" \
  --region "${AWS_REGION}" --query 'id' --output text)
echo "   /face:           ${FACE_ID}"

INDEX_RES_ID=$(aws apigateway create-resource \
  --rest-api-id "${API_ID}" --parent-id "${FACE_ID}" --path-part "index" \
  --region "${AWS_REGION}" --query 'id' --output text)
echo "   /face/index:     ${INDEX_RES_ID}"

SEARCH_RES_ID=$(aws apigateway create-resource \
  --rest-api-id "${API_ID}" --parent-id "${FACE_ID}" --path-part "search" \
  --region "${AWS_REGION}" --query 'id' --output text)
echo "   /face/search:    ${SEARCH_RES_ID}"

FACEID_RES_ID=$(aws apigateway create-resource \
  --rest-api-id "${API_ID}" --parent-id "${FACE_ID}" --path-part "{faceId}" \
  --region "${AWS_REGION}" --query 'id' --output text)
echo "   /face/{faceId}:  ${FACEID_RES_ID}"

# --- 4. Monta URI de integração Lambda ---
LAMBDA_URI="arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"

# --- 5. Helper: adiciona método que invoca Lambda com API key required ---
add_lambda_method() {
  local resource_id="$1"
  local http_method="$2"
  local path_label="$3"

  aws apigateway put-method \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "${http_method}" \
    --authorization-type "NONE" \
    --api-key-required \
    --region "${AWS_REGION}" \
    --no-cli-pager > /dev/null

  aws apigateway put-integration \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "${http_method}" \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "${LAMBDA_URI}" \
    --region "${AWS_REGION}" \
    --no-cli-pager > /dev/null

  # method response stub (AWS_PROXY delega status code à Lambda, mas API GW exige spec mínimo)
  aws apigateway put-method-response \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "${http_method}" \
    --status-code "200" \
    --region "${AWS_REGION}" \
    --no-cli-pager > /dev/null

  echo "   ${http_method} ${path_label} → Lambda ✓"
}

# --- 6. Helper: adiciona OPTIONS com CORS via MOCK (sem custar invoke Lambda) ---
add_cors_options() {
  local resource_id="$1"
  local methods_allowed="$2"  # ex: "POST,OPTIONS" ou "DELETE,OPTIONS"
  local path_label="$3"

  aws apigateway put-method \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "OPTIONS" \
    --authorization-type "NONE" \
    --no-api-key-required \
    --region "${AWS_REGION}" \
    --no-cli-pager > /dev/null

  aws apigateway put-integration \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "OPTIONS" \
    --type MOCK \
    --request-templates '{"application/json":"{\"statusCode\": 200}"}' \
    --region "${AWS_REGION}" \
    --no-cli-pager > /dev/null

  aws apigateway put-method-response \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "OPTIONS" \
    --status-code "200" \
    --response-parameters '{"method.response.header.Access-Control-Allow-Origin":true,"method.response.header.Access-Control-Allow-Headers":true,"method.response.header.Access-Control-Allow-Methods":true}' \
    --region "${AWS_REGION}" \
    --no-cli-pager > /dev/null

  # Valores dos headers — aspas duplas escapam dentro do JSON; envoltas em aspas simples no valor
  aws apigateway put-integration-response \
    --rest-api-id "${API_ID}" \
    --resource-id "${resource_id}" \
    --http-method "OPTIONS" \
    --status-code "200" \
    --response-parameters "{\"method.response.header.Access-Control-Allow-Origin\":\"'${ALLOWED_ORIGIN}'\",\"method.response.header.Access-Control-Allow-Headers\":\"'Content-Type,X-Api-Key'\",\"method.response.header.Access-Control-Allow-Methods\":\"'${methods_allowed}'\"}" \
    --region "${AWS_REGION}" \
    --no-cli-pager > /dev/null

  echo "   OPTIONS ${path_label} → MOCK/CORS ✓"
}

# --- 7. Configurar os 3 endpoints ---
echo ""
echo "→ configurando métodos..."
add_lambda_method "${INDEX_RES_ID}"  "POST"   "/face/index"
add_cors_options  "${INDEX_RES_ID}"  "POST,OPTIONS" "/face/index"

add_lambda_method "${SEARCH_RES_ID}" "POST"   "/face/search"
add_cors_options  "${SEARCH_RES_ID}" "POST,OPTIONS" "/face/search"

add_lambda_method "${FACEID_RES_ID}" "DELETE" "/face/{faceId}"
add_cors_options  "${FACEID_RES_ID}" "DELETE,OPTIONS" "/face/{faceId}"

# --- 8. Permissão para API Gateway invocar Lambda ---
echo ""
echo "→ concedendo permissão pra API Gateway invocar Lambda..."
# Remove permission anterior se existir (idempotência)
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
echo "   ✓ permissão concedida"

# --- 9. Deploy para stage ---
echo ""
echo "→ fazendo deploy para stage '${STAGE}'..."
DEPLOYMENT_ID=$(aws apigateway create-deployment \
  --rest-api-id "${API_ID}" \
  --stage-name "${STAGE}" \
  --stage-description "Produção — chamada do GitHub Pages" \
  --description "Initial deploy $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --region "${AWS_REGION}" \
  --query 'id' --output text)
echo "   ✓ deployment id: ${DEPLOYMENT_ID}"

# --- 10. Habilita logs do stage (métricas básicas, sem X-Ray ainda) ---
aws apigateway update-stage \
  --rest-api-id "${API_ID}" \
  --stage-name "${STAGE}" \
  --patch-operations \
    op=replace,path=/*/*/metrics/enabled,value=true \
    op=replace,path=/*/*/throttling/rateLimit,value=50 \
    op=replace,path=/*/*/throttling/burstLimit,value=100 \
  --region "${AWS_REGION}" \
  --no-cli-pager > /dev/null

# --- 11. URL final + state ---
INVOKE_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/${STAGE}"
state_set api_id "${API_ID}"
state_set api_invoke_url "${INVOKE_URL}"
state_set api_stage "${STAGE}"

echo ""
echo "✅ ETAPA 1.3 concluída."
echo "   API ID:     ${API_ID}"
echo "   Invoke URL: ${INVOKE_URL}"
echo ""
echo "   Endpoints:"
echo "     POST   ${INVOKE_URL}/face/index       (api-key)"
echo "     POST   ${INVOKE_URL}/face/search      (api-key)"
echo "     DELETE ${INVOKE_URL}/face/{faceId}    (api-key)"
echo ""
echo "→ teste rápido (sem api-key — deve responder 403):"
curl -s -o /dev/null -w "   HTTP %{http_code} (esperado: 403)\n" \
  -X POST "${INVOKE_URL}/face/search" \
  -H 'Content-Type: application/json' \
  -d '{"imageBase64":"test"}' || true
echo ""
echo "Próximo passo: bash lambda/scripts/04-api-key.sh"
