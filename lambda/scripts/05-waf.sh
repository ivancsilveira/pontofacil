#!/usr/bin/env bash
# ================================================================
# ETAPA 1.5 — WAFv2 Web ACL regional + associação
# ================================================================
# Rules (em ordem de prioridade):
#   1. BlockBadOrigin        — custom: Origin != GitHub Pages → Block
#   2. AWSCommonRules        — managed: CommonRuleSet da AWS
#                              overrides (pra nosso caso de base64 image):
#                              · SizeRestrictions_BODY      → Count (não bloqueia)
#                              · GenericRFI_BODY            → Count
#                              · CrossSiteScripting_BODY    → Count
#   3. RateLimitPerIP        — custom: 500 req / 5min / IP → Block
#
# Default action: Allow.
#
# IDEMPOTENTE: se já existe WebACL com esse nome, desassocia e deleta.
# ================================================================
#
# 💰 CUSTO ESTIMADO:
#   - 1 Web ACL:            US$ 5.00/mês
#   - 2 custom rules:       US$ 2.00/mês
#   - 1 managed rule group: US$ 1.00/mês
#   - Tráfego baixo:        ~ US$ 0.10/mês
#   TOTAL:                  ~ US$ 8/mês
#
#   Com US$ 100 em créditos + Free Tier, cobre ~12 meses.
# ================================================================
set -euo pipefail

cd "$(dirname "$0")"
source ./_env.sh

echo "======================================"
echo " ETAPA 1.5 — WAFv2 Web ACL"
echo "======================================"

API_ID="$(state_get api_id)"
API_STAGE="$(state_get api_stage)"
if [ -z "${API_ID}" ] || [ -z "${API_STAGE}" ]; then
  echo "❌ api_id/api_stage não encontrados no .state.json"
  exit 1
fi
STAGE_ARN="arn:aws:apigateway:${AWS_REGION}::/restapis/${API_ID}/stages/${API_STAGE}"
echo "Stage ARN:  ${STAGE_ARN}"
echo "ACL:        ${WAF_ACL_NAME}"
echo "Origin ok:  ${ALLOWED_ORIGIN}"
echo ""

# --- 1. Desassocia + deleta WebACL anterior se existir ---
EXISTING=$(aws wafv2 list-web-acls \
  --scope REGIONAL \
  --region "${AWS_REGION}" \
  --query "WebACLs[?Name=='${WAF_ACL_NAME}']" \
  --output json 2>/dev/null || echo "[]")

if [ "${EXISTING}" != "[]" ] && [ -n "${EXISTING}" ]; then
  WAF_ID=$(echo "${EXISTING}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['Id']) if d else print('')")
  WAF_LOCK=$(echo "${EXISTING}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['LockToken']) if d else print('')")

  if [ -n "${WAF_ID}" ]; then
    echo "⚠  WebACL '${WAF_ACL_NAME}' já existe (${WAF_ID}) — limpando..."

    # Desassocia do stage (se estiver) — ignora erro se não estiver associada
    aws wafv2 disassociate-web-acl \
      --resource-arn "${STAGE_ARN}" \
      --region "${AWS_REGION}" 2>/dev/null || true

    # Espera propagação (desassociação demora ~5-10s no plano de dados)
    sleep 8

    aws wafv2 delete-web-acl \
      --scope REGIONAL \
      --id "${WAF_ID}" \
      --name "${WAF_ACL_NAME}" \
      --lock-token "${WAF_LOCK}" \
      --region "${AWS_REGION}" \
      --no-cli-pager
    echo "   ✓ deletada"
    sleep 5
  fi
fi

# --- 2. Monta JSON das rules em arquivo temporário ---
RULES_FILE=$(mktemp -t pontofacil-waf-rules)
trap "rm -f ${RULES_FILE}" EXIT

# WAFv2 JSON trata SearchString como blob — valor DEVE ser base64 no arquivo.
# Codifica via python pra ser portável (macOS e Linux, sem diferença de flag).
ORIGIN_A="https://ivancsilveira.github.io"
ORIGIN_B="http://localhost:8080"
ORIGIN_A_B64=$(python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode()).decode())" "${ORIGIN_A}")
ORIGIN_B_B64=$(python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode()).decode())" "${ORIGIN_B}")
echo "→ SearchString base64:"
echo "   ${ORIGIN_A} → ${ORIGIN_A_B64}"
echo "   ${ORIGIN_B} → ${ORIGIN_B_B64}"

cat > "${RULES_FILE}" <<JSON
[
  {
    "Name": "BlockBadOrigin",
    "Priority": 1,
    "Statement": {
      "NotStatement": {
        "Statement": {
          "OrStatement": {
            "Statements": [
              {
                "ByteMatchStatement": {
                  "SearchString": "${ORIGIN_A_B64}",
                  "FieldToMatch": { "SingleHeader": { "Name": "origin" } },
                  "TextTransformations": [{ "Priority": 0, "Type": "NONE" }],
                  "PositionalConstraint": "EXACTLY"
                }
              },
              {
                "ByteMatchStatement": {
                  "SearchString": "${ORIGIN_B_B64}",
                  "FieldToMatch": { "SingleHeader": { "Name": "origin" } },
                  "TextTransformations": [{ "Priority": 0, "Type": "NONE" }],
                  "PositionalConstraint": "EXACTLY"
                }
              }
            ]
          }
        }
      }
    },
    "Action": { "Block": {} },
    "VisibilityConfig": {
      "SampledRequestsEnabled": true,
      "CloudWatchMetricsEnabled": true,
      "MetricName": "BlockBadOrigin"
    }
  },
  {
    "Name": "AWSCommonRules",
    "Priority": 2,
    "OverrideAction": { "None": {} },
    "Statement": {
      "ManagedRuleGroupStatement": {
        "VendorName": "AWS",
        "Name": "AWSManagedRulesCommonRuleSet",
        "RuleActionOverrides": [
          { "Name": "SizeRestrictions_BODY",       "ActionToUse": { "Count": {} } },
          { "Name": "GenericRFI_BODY",             "ActionToUse": { "Count": {} } },
          { "Name": "CrossSiteScripting_BODY",     "ActionToUse": { "Count": {} } }
        ]
      }
    },
    "VisibilityConfig": {
      "SampledRequestsEnabled": true,
      "CloudWatchMetricsEnabled": true,
      "MetricName": "AWSCommonRules"
    }
  },
  {
    "Name": "RateLimitPerIP",
    "Priority": 3,
    "Statement": {
      "RateBasedStatement": {
        "Limit": 500,
        "AggregateKeyType": "IP"
      }
    },
    "Action": { "Block": {} },
    "VisibilityConfig": {
      "SampledRequestsEnabled": true,
      "CloudWatchMetricsEnabled": true,
      "MetricName": "RateLimitPerIP"
    }
  }
]
JSON

# Valida JSON antes de mandar pra AWS
python3 -c "import json; json.load(open('${RULES_FILE}'))" && echo "→ rules JSON válido"

# --- 3. Cria Web ACL ---
echo ""
echo "→ criando Web ACL '${WAF_ACL_NAME}'..."
CREATE_OUT=$(aws wafv2 create-web-acl \
  --name "${WAF_ACL_NAME}" \
  --scope REGIONAL \
  --default-action '{"Allow":{}}' \
  --rules "file://${RULES_FILE}" \
  --visibility-config "SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=${WAF_ACL_NAME}" \
  --tags "Key=project,Value=${PROJECT}" \
  --region "${AWS_REGION}" \
  --output json)

WAF_ARN=$(echo "${CREATE_OUT}" | python3 -c "import json,sys; print(json.load(sys.stdin)['Summary']['ARN'])")
WAF_ID=$(echo "${CREATE_OUT}"  | python3 -c "import json,sys; print(json.load(sys.stdin)['Summary']['Id'])")

echo "   ✓ Web ACL criada"
echo "   ID:  ${WAF_ID}"
echo "   ARN: ${WAF_ARN}"

# --- 4. Associa ao stage do API Gateway ---
echo ""
echo "→ associando ao stage ${API_STAGE}..."
sleep 3  # pequena folga para Web ACL aparecer no plano de dados
aws wafv2 associate-web-acl \
  --resource-arn "${STAGE_ARN}" \
  --web-acl-arn "${WAF_ARN}" \
  --region "${AWS_REGION}" \
  --no-cli-pager > /dev/null
echo "   ✓ associada"

# --- 5. Salva no state ---
state_set waf_acl_id "${WAF_ID}"
state_set waf_acl_arn "${WAF_ARN}"

echo ""
echo "✅ ETAPA 1.5 concluída."
echo ""
echo "   Web ACL ID:  ${WAF_ID}"
echo "   Regra 1:     BlockBadOrigin   (Block se Origin ≠ ${ALLOWED_ORIGIN})"
echo "   Regra 2:     AWSCommonRules   (managed — sem size/body blocks)"
echo "   Regra 3:     RateLimitPerIP   (Block após 500 req / 5min / IP)"
echo "   Default:     Allow"
echo ""

# --- 6. Testes rápidos (WAF leva ~30s pra propagar regras) ---
INVOKE_URL="$(state_get api_invoke_url)"
API_KEY_VALUE="$(state_get api_key_value)"

echo "→ aguardando 35s pra WAF propagar..."
sleep 35
echo ""
echo "→ teste SEM Origin (esperado: 403 — WAF bloqueia):"
HTTP1=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${INVOKE_URL}/face/search" \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: ${API_KEY_VALUE}" \
  -d '{"imageBase64":"x"}')
echo "   HTTP ${HTTP1} $([ "${HTTP1}" = "403" ] && echo "✓" || echo "⚠ esperava 403")"

echo "→ teste COM Origin correto + API key + payload bobo (esperado: 400 invalid_image):"
HTTP2=$(curl -s -o /tmp/waf_test_body -w "%{http_code}" \
  -X POST "${INVOKE_URL}/face/search" \
  -H "Content-Type: application/json" \
  -H "Origin: ${ALLOWED_ORIGIN}" \
  -H "X-Api-Key: ${API_KEY_VALUE}" \
  -d '{"imageBase64":"not-a-valid-image"}')
BODY=$(cat /tmp/waf_test_body 2>/dev/null || echo "")
rm -f /tmp/waf_test_body
echo "   HTTP ${HTTP2}"
echo "   body: ${BODY}"
if [ "${HTTP2}" = "400" ]; then
  echo "   ✓ passou WAF + API Gateway + chegou na Lambda"
else
  echo "   ⚠ esperava 400 (pode ser só demora de propagação — tente de novo em 1 min)"
fi

echo ""
echo "Próximo passo: bash lambda/scripts/06-smoke-tests.sh"
