# pontofacil-face-api (Lambda)

Backend seguro para reconhecimento facial via AWS Rekognition.

## Arquitetura

```
Frontend (GitHub Pages)
       ↓ (HTTPS + X-Api-Key)
API Gateway (REST + WAF)
       ↓
Lambda (este código)
       ↓
AWS Rekognition (collection: pontofacil-rostos)
```

## Endpoints

| Método | Path | Body / Params | Retorno |
|---|---|---|---|
| `POST` | `/face/index` | `{imageBase64, externalImageId}` | `{faceId, externalImageId, confidence}` |
| `POST` | `/face/search` | `{imageBase64, threshold?}` | `{matches: [{faceId, externalImageId, similarity}], searchedFaceConfidence, reason?}` |
| `DELETE` | `/face/{faceId}` | path param `faceId` (uuid) | `{deleted, faceId}` |

**Todos exigem header `X-Api-Key`.**
Origin check: Lambda recusa requests com `Origin` ≠ `https://ivancsilveira.github.io`. WAF bloqueia no edge.

## Códigos de erro

| Status | Corpo | Causa |
|---|---|---|
| 400 | `invalid_json` | body não é JSON válido |
| 400 | `missing_fields` | campo obrigatório faltando |
| 400 | `invalid_external_image_id` | chars fora de `[A-Za-z0-9_.\-:]` |
| 400 | `invalid_image` | base64 não decoda para Buffer |
| 400 | `invalid_face_id` | faceId fora do formato uuid |
| 403 | `origin_not_allowed` | Origin diferente do permitido |
| 404 | `not_found` | rota inexistente |
| 413 | `image_too_large` | imagem > 4.5 MB |
| 422 | `no_face_detected` | Rekognition não achou rosto na foto |
| 500 | `internal_error` | erro interno — detalhes só no CloudWatch |

## Variáveis de ambiente (setadas pelo deploy script)

- `COLLECTION_ID` → `pontofacil-rostos`
- `ALLOWED_ORIGIN` → `https://ivancsilveira.github.io`
- `AWS_REGION` → `sa-east-1` (injetada pelo runtime)

## Deploy

```bash
cd ~/Downloads/pontofacil
bash lambda/scripts/02-deploy-lambda.sh
```

O script: instala deps, cria zip, cria/atualiza a função, espera `function-updated`, salva o ARN em `.state.json`.

## LGPD — log de auditoria

Cada request gera uma linha JSON no CloudWatch Logs (`/aws/lambda/pontofacil-face-api`):

```json
{"ts":"2026-04-21T17:30:00.000Z","action":"index_ok","externalImageId":"func-abc123","faceId":"uuid","confidence":99.9,"sourceIp":"1.2.3.4"}
{"ts":"2026-04-21T17:31:00.000Z","action":"search_ok","matchCount":1,"topSimilarity":98.7,"topExternalImageId":"func-abc123","threshold":80,"sourceIp":"1.2.3.4"}
{"ts":"2026-04-21T17:32:00.000Z","action":"delete_ok","faceId":"uuid","deleted":1,"sourceIp":"1.2.3.4"}
```

Consulta via CloudWatch Insights:
```
fields @timestamp, action, externalImageId, faceId, sourceIp
| filter action = "delete_ok"
| sort @timestamp desc
```

## Desenvolvimento local

Pra editar o código com autocompletion:
```bash
cd lambda
npm install
npm run check   # syntax check
```

Não há como testar contra Rekognition real sem AWS. O teste end-to-end vivo é feito via `lambda/scripts/06-smoke-tests.sh` após deploy.
