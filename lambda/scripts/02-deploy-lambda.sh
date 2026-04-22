#!/usr/bin/env bash
# ================================================================
# ETAPA 1.2 — Deploy da Lambda pontofacil-face-api
# ================================================================
# Layout (flat — sem subdir src/):
#   lambda/
#   ├── index.js
#   ├── rekognition.js
#   ├── package.json
#   ├── node_modules/       (instalado pelo script, gitignored)
#   ├── dist/function.zip   (gerado pelo script, gitignored)
#   ├── README.md           (não vai pro zip)
#   └── scripts/            (não vai pro zip)
#
# O que faz:
#   1. Lê o role ARN do .state.json (gravado em 1.1)
#   2. Roda "npm install --omit=dev" em lambda/
#   3. Zipa index.js + rekognition.js + package.json + node_modules/
#   4. Cria OU atualiza a função Lambda (idempotente)
#   5. Espera function-updated e salva ARN em .state.json
# ================================================================
set -euo pipefail

cd "$(dirname "$0")"
source ./_env.sh

LAMBDA_DIR="$(cd .. && pwd)"
DIST_DIR="${LAMBDA_DIR}/dist"
ZIP_FILE="${DIST_DIR}/function.zip"

echo "======================================"
echo " ETAPA 1.2 — Deploy Lambda"
echo "======================================"
echo "Lambda dir: ${LAMBDA_DIR}"
echo "Zip:        ${ZIP_FILE}"
echo ""

# --- 1. role_arn do state ---
ROLE_ARN="$(state_get role_arn)"
if [ -z "${ROLE_ARN}" ]; then
  echo "❌ role_arn não encontrado em .state.json"
  echo "   Rode primeiro: bash lambda/scripts/01-create-iam-role.sh"
  exit 1
fi
echo "Role:       ${ROLE_ARN}"

# --- 1.5 env vars em JSON (aws CLI shorthand usa vírgula como separador,
#            e nosso ALLOWED_ORIGINS contém vírgulas) ---
ENV_JSON=$(mktemp -t pontofacil-lambda-env)
trap 'rm -f "${ENV_JSON}"' EXIT
python3 - "${COLLECTION_ID}" "${ALLOWED_ORIGIN}" "${ALLOWED_ORIGINS}" > "${ENV_JSON}" <<'PYEOF_ENV'
import sys, json
variables = {
    "COLLECTION_ID": sys.argv[1],
    "ALLOWED_ORIGIN": sys.argv[2],
    "ALLOWED_ORIGINS": sys.argv[3],
}
print(json.dumps({"Variables": variables}))
PYEOF_ENV
echo "→ env.json em: ${ENV_JSON}"

# --- 2. npm install ---
echo ""
echo "→ npm install --omit=dev em ${LAMBDA_DIR}..."
( cd "${LAMBDA_DIR}" && npm install --omit=dev --silent --no-fund --no-audit )
echo "   ✓ deps instaladas"

# --- 3. zip (só o que a Lambda precisa) ---
echo ""
echo "→ criando zip..."
mkdir -p "${DIST_DIR}"
rm -f "${ZIP_FILE}"
(
  cd "${LAMBDA_DIR}" && zip -qr "${ZIP_FILE}" \
    index.js \
    rekognition.js \
    package.json \
    node_modules \
    -x "*.DS_Store" "*/.DS_Store" "node_modules/.cache/*"
)
ZIP_SIZE=$(wc -c < "${ZIP_FILE}" | tr -d ' ')
ZIP_MB=$(awk "BEGIN{printf \"%.2f\", ${ZIP_SIZE}/1024/1024}")
echo "   ✓ zip: ${ZIP_SIZE} bytes (${ZIP_MB} MB)"

# --- 4. criar ou atualizar ---
if aws lambda get-function --function-name "${LAMBDA_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo ""
  echo "⚠  Lambda ${LAMBDA_NAME} já existe — atualizando código + config..."

  aws lambda update-function-code \
    --function-name "${LAMBDA_NAME}" \
    --zip-file "fileb://${ZIP_FILE}" \
    --publish \
    --region "${AWS_REGION}" \
    --no-cli-pager \
    > /dev/null

  aws lambda wait function-updated \
    --function-name "${LAMBDA_NAME}" \
    --region "${AWS_REGION}"

  aws lambda update-function-configuration \
    --function-name "${LAMBDA_NAME}" \
    --role "${ROLE_ARN}" \
    --timeout 10 \
    --memory-size 256 \
    --environment "file://${ENV_JSON}" \
    --region "${AWS_REGION}" \
    --no-cli-pager \
    > /dev/null

  aws lambda wait function-updated \
    --function-name "${LAMBDA_NAME}" \
    --region "${AWS_REGION}"

  echo "   ✓ código + config atualizados"
else
  echo ""
  echo "→ criando Lambda ${LAMBDA_NAME}..."
  aws lambda create-function \
    --function-name "${LAMBDA_NAME}" \
    --runtime nodejs20.x \
    --role "${ROLE_ARN}" \
    --handler "index.handler" \
    --zip-file "fileb://${ZIP_FILE}" \
    --timeout 10 \
    --memory-size 256 \
    --architectures x86_64 \
    --environment "file://${ENV_JSON}" \
    --tags "project=${PROJECT}" \
    --description "Backend Rekognition — rotas /face/index, /face/search, /face/{faceId}" \
    --region "${AWS_REGION}" \
    --no-cli-pager \
    > /dev/null

  aws lambda wait function-active \
    --function-name "${LAMBDA_NAME}" \
    --region "${AWS_REGION}"

  echo "   ✓ Lambda criada e ativa"
fi

# --- 5. estado final ---
LAMBDA_ARN=$(aws lambda get-function \
  --function-name "${LAMBDA_NAME}" \
  --region "${AWS_REGION}" \
  --query 'Configuration.FunctionArn' \
  --output text)

state_set lambda_arn "${LAMBDA_ARN}"
state_set lambda_name "${LAMBDA_NAME}"

echo ""
echo "✅ ETAPA 1.2 concluída."
echo "   Function: ${LAMBDA_NAME}"
echo "   ARN:      ${LAMBDA_ARN}"
echo ""
echo "→ validação rápida (Configuration):"
aws lambda get-function-configuration \
  --function-name "${LAMBDA_NAME}" \
  --region "${AWS_REGION}" \
  --query '{Runtime:Runtime,Memory:MemorySize,Timeout:Timeout,Role:Role,Env:Environment.Variables,State:State,LastStatus:LastUpdateStatus,CodeSize:CodeSize}' \
  --output table

echo ""
echo "Próximo passo: bash lambda/scripts/03-api-gateway.sh"
