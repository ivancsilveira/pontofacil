#!/usr/bin/env bash
# Constantes de projeto. Fonte única da verdade — sourced by every other script.
# Não contém credenciais — AWS lê de ~/.aws/credentials automaticamente.

export AWS_REGION="sa-east-1"
export ACCOUNT_ID="866672751311"
export PROJECT="pontofacil"

# Recursos
export COLLECTION_ID="pontofacil-rostos"
export ROLE_NAME="pontofacil-lambda-role"
export POLICY_NAME="pontofacil-lambda-rekognition"
export LAMBDA_NAME="pontofacil-face-api"
export API_NAME="pontofacil-face-api"
export API_KEY_NAME="pontofacil-github-pages-key"
export USAGE_PLAN_NAME="pontofacil-usage-plan"
export WAF_ACL_NAME="pontofacil-waf-acl"

# Frontend
export ALLOWED_ORIGIN="https://ivancsilveira.github.io"
# Lista de origins permitidos (CSV) — usado por Lambda e WAF. Inclui localhost pra dev local.
export ALLOWED_ORIGINS="https://ivancsilveira.github.io,http://localhost:8080"
# Array com as mesmas entradas (usado pelo script 05 do WAF)
export ALLOWED_ORIGINS_ARRAY=("https://ivancsilveira.github.io" "http://localhost:8080")

# ARNs calculados (IAM é global, Rekognition é regional)
export COLLECTION_ARN="arn:aws:rekognition:${AWS_REGION}:${ACCOUNT_ID}:collection/${COLLECTION_ID}"
export ROLE_ARN_EXPECTED="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# Arquivo de estado (IDs gerados pelos scripts — NÃO commitar, está no .gitignore)
export STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.state.json"

# Helpers
state_get() {
  local key="$1"
  if [ -f "${STATE_FILE}" ]; then
    # uses python (preinstalled on macOS) — no jq dependency
    python3 -c "import json,sys; d=json.load(open('${STATE_FILE}')); print(d.get('${key}',''))"
  fi
}

state_set() {
  local key="$1"; local value="$2"
  if [ ! -f "${STATE_FILE}" ]; then echo '{}' > "${STATE_FILE}"; fi
  python3 -c "
import json
d = json.load(open('${STATE_FILE}'))
d['${key}'] = '''${value}'''
json.dump(d, open('${STATE_FILE}','w'), indent=2)
"
}
