#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────
#  Hermes Operator — Entrypoint para Hugging Face Docker Space
# ─────────────────────────────────────────────────────────────

echo "=== Hermes Operator — Starting ==="

# ── Validação ────────────────────────────────────────────────
if [ -z "$OPENROUTER_API_KEY" ]; then
    echo "ERRO: OPENROUTER_API_KEY não configurada!"
    echo "Configure nas Secrets do Hugging Face Space:"
    echo "  Settings → Repository Secrets → Add secret"
    echo "  Nome: OPENROUTER_API_KEY"
    exit 1
fi

# ── Diretórios ───────────────────────────────────────────────
mkdir -p "$HERMES_HOME"/{logs,sessions}

# ── Gera config.yaml ─────────────────────────────────────────
HERMES_MODEL="${HERMES_MODEL:-deepseek/deepseek-v4-flash}"
HERMES_PROVIDER="${HERMES_PROVIDER:-openrouter}"

echo "[config] Provider: ${HERMES_PROVIDER}"
echo "[config] Modelo: ${HERMES_MODEL}"

# Monta bloco de plataformas
PLATFORMS_YAML="  platforms:"
if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    echo "[telegram] Habilitado no Gateway"
    PLATFORMS_YAML="${PLATFORMS_YAML}
    telegram:
      enabled: true
      token: '${TELEGRAM_BOT_TOKEN}'"
fi
if [ -n "$BRIDGE_RELAY_URL" ]; then
    echo "[bridge] Relay WhatsApp → ${BRIDGE_RELAY_URL}"
    PLATFORMS_YAML="${PLATFORMS_YAML}
    whatsapp:
      enabled: true
      relay_url: ${BRIDGE_RELAY_URL}
      relay_api_key: ${BRIDGE_API_KEY}"
fi

cat > "$HERMES_HOME/config.yaml" <<EOF
model:
  default: ${HERMES_MODEL}
  provider: ${HERMES_PROVIDER}

gateway:
  media_delivery_allow_dirs: []
  trust_recent_files: true
  trust_recent_files_seconds: 600
${PLATFORMS_YAML}
security:
  redact_secrets: true
  tirith_enabled: true

sessions:
  auto_prune: true
  retention_days: 30

display:
  language: pt
  show_cost: false

platform_toolsets:
  api_server:
    - web
EOF

# ── API Server ───────────────────────────────────────────────
export API_SERVER_ENABLED=true
export API_SERVER_HOST=0.0.0.0
export API_SERVER_PORT=${PORT:-7860}

if [ -n "$API_SERVER_KEY" ]; then
    export API_SERVER_KEY="$API_SERVER_KEY"
    echo "[auth] API Server com chave de autenticação"
else
    echo "[auth] API Server sem autenticação"
    echo "       Recomendo definir API_SERVER_KEY nas Secrets do HF!"
fi

# ── Start ────────────────────────────────────────────────────
echo "=== Iniciando Hermes Gateway na porta ${API_SERVER_PORT} ==="

exec hermes gateway run --verbose
