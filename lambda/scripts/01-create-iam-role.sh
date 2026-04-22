#!/usr/bin/env bash
# ================================================================
# ETAPA 1.1 — Criar IAM Role least-privilege para o Lambda
# ================================================================
# O que faz:
#   1. Cria role "pontofacil-lambda-role" com trust policy para Lambda
#   2. Anexa inline policy com permissões MÍNIMAS:
#        - Rekognition: IndexFaces, SearchFacesByImage, DeleteFaces, ListFaces
#          (escopadas ao collection pontofacil-rostos)
#        - CloudWatch Logs: criar grupos/streams e escrever eventos
#   3. Salva a ARN no arquivo de estado para os próximos scripts usarem
#
# Idempotente: pode rodar várias vezes sem quebrar.
# ================================================================
set -euo pipefail

cd "$(dirname "$0")"
source ./_env.sh

echo "======================================"
echo " ETAPA 1.1 — IAM Role least-privilege"
echo "======================================"
echo "Role: ${ROLE_NAME}"
echo "Collection ARN: ${COLLECTION_ARN}"
echo ""

# --- 1. Criar role (ou pular se existe) ---
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "⚠  Role ${ROLE_NAME} já existe — pulando criação."
else
  echo "→ criando role ${ROLE_NAME}..."
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --description "Least-privilege role para Lambda pontofacil-face-api" \
    --tags "Key=project,Value=${PROJECT}" \
    >/dev/null
  echo "   ✓ role criada"
fi

# --- 2. Anexar (ou atualizar) inline policy ---
echo "→ aplicando inline policy ${POLICY_NAME}..."

PERMISSION_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RekognitionFaceOps",
      "Effect": "Allow",
      "Action": [
        "rekognition:IndexFaces",
        "rekognition:SearchFacesByImage",
        "rekognition:DeleteFaces",
        "rekognition:ListFaces"
      ],
      "Resource": "${COLLECTION_ARN}"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:*"
    }
  ]
}
JSON
)

aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "${PERMISSION_POLICY}"

echo "   ✓ policy aplicada"

# --- 3. Ler ARN final e salvar no state ---
ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)
state_set role_arn "${ROLE_ARN}"

echo ""
echo "✅ ETAPA 1.1 concluída."
echo "   Role ARN: ${ROLE_ARN}"
echo ""
echo "→ aguardando 10s de propagação IAM (Lambda rejeita roles novas por ~segundos)..."
sleep 10
echo "   ok"
echo ""
echo "Próximo passo: bash lambda/scripts/02-deploy-lambda.sh"
