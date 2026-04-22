#!/usr/bin/env bash
# ================================================================
# ETAPA 3.x — Injetar API URL + API Key no index.html
# ================================================================
# Substitui os placeholders __REK_API_URL__ e __REK_API_KEY__ no
# index.html pelos valores atuais do .state.json (gerados nas etapas
# 1.3 e 1.4). Rode toda vez que a URL ou a key mudarem.
#
# Idempotente: se o valor atual já bate, não faz nada.
# Backup: cria index.html.pre-inject.bak antes de cada substituição.
# ================================================================
set -euo pipefail

cd "$(dirname "$0")"
source ./_env.sh

INDEX="$(cd ../.. && pwd)/index.html"

if [ ! -f "${INDEX}" ]; then
  echo "❌ index.html não encontrado em ${INDEX}"
  exit 1
fi

URL=$(state_get api_invoke_url)
KEY=$(state_get api_key_value)

if [ -z "${URL}" ] || [ -z "${KEY}" ]; then
  echo "❌ api_invoke_url / api_key_value não encontrados em .state.json"
  echo "   Rode 03-api-gateway.sh e 04-api-key.sh antes."
  exit 1
fi

echo "========================================"
echo " Inject Rekognition config → index.html"
echo "========================================"
echo "  URL:    ${URL}"
echo "  Key:    ${KEY:0:8}…${KEY: -4}   (truncado)"
echo "  Index:  ${INDEX}"
echo ""

# Snapshot de segurança
cp "${INDEX}" "${INDEX}.pre-inject.bak"

# Python faz sub seguro — escapa caracteres especiais, não usa sed (problema com / na URL)
python3 - "${INDEX}" "${URL}" "${KEY}" <<'PYEOF'
import sys, pathlib
idx, url, key = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(idx)
t = p.read_text()

placeholders = [
    ('__REK_API_URL__', url),
    ('__REK_API_KEY__', key),
]

# Verifica que um dos dois está presente (placeholder) OU que o valor atual já bate
has_placeholder = any(ph in t for ph, _ in placeholders)
already_injected = all(val in t for _, val in placeholders)

if not has_placeholder and already_injected:
    print("→ valores já injetados (nada a fazer)")
    sys.exit(0)

changes = 0
for ph, val in placeholders:
    if ph in t:
        t = t.replace(ph, val)
        changes += 1
        print(f"   ✓ substituído {ph}")
    elif val not in t:
        # Nem o placeholder nem o valor — re-injeção necessária mas precisa de string âncora.
        # Detecta pelo padrão: const REK_API_URL = '...';
        import re
        if ph == '__REK_API_URL__':
            t2, n = re.subn(r"const REK_API_URL = '[^']*';", f"const REK_API_URL = '{val}';", t, count=1)
        elif ph == '__REK_API_KEY__':
            t2, n = re.subn(r"const REK_API_KEY = '[^']*';", f"const REK_API_KEY = '{val}';", t, count=1)
        if n:
            t = t2
            changes += 1
            print(f"   ✓ re-injetado via regex para {ph}")

p.write_text(t)
print(f"\n✅ {changes} substituições aplicadas.")
PYEOF

# Valida que ficou 0 placeholders
if grep -q '__REK_API_URL__\|__REK_API_KEY__' "${INDEX}"; then
  echo ""
  echo "⚠  ainda há placeholders no arquivo — verifique manualmente"
  grep -n '__REK_API_URL__\|__REK_API_KEY__' "${INDEX}"
  exit 1
fi

echo ""
echo "✅ index.html pronto. Backup em: ${INDEX}.pre-inject.bak"
echo ""
echo "Próximo passo: teste local"
echo "   cd $(cd ../.. && pwd)"
echo "   python3 -m http.server 8080"
echo "   abre http://localhost:8080 no Chrome"
