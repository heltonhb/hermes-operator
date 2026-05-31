#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────
#  Hermes Operator — Entrypoint para Hugging Face Docker Space
# ─────────────────────────────────────────────────────────────
# Provider: openrouter (deepseek/deepseek-v4-flash)
# Obrigatório via env var:
#   OPENROUTER_API_KEY   — chave de API do OpenRouter
# Opcionais:
#   HERMES_MODEL         — modelo (padrão: deepseek/deepseek-v4-flash)
#   HERMES_PROVIDER      — provider (padrão: openrouter)
#   API_SERVER_KEY       — chave para autenticar requests na API
#   BRIDGE_RELAY_URL     — URL do gateway local (ngrok) para relay WhatsApp/Telegram
#   BRIDGE_API_KEY       — chave de API do relay
# ─────────────────────────────────────────────────────────────

echo "=== Hermes Operator — Starting ==="

# Validação: precisa da OPENROUTER_API_KEY
if [ -z "$OPENROUTER_API_KEY" ]; then
    echo "ERRO: OPENROUTER_API_KEY não configurada!"
    echo "Configure nas Secrets do Hugging Face Space:"
    echo "  Settings → Repository Secrets → Add secret"
    echo "  Nome: OPENROUTER_API_KEY"
    exit 1
fi

# Cria diretório do Hermes se não existir
mkdir -p "$HERMES_HOME"/{logs,sessions}

# ── Canais de delivery ─────────────────────────────────────────
# Telegram pode ser direto (webhook via TELEGRAM_BOT_TOKEN) ou relay
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_WEBHOOK_URL="${TELEGRAM_WEBHOOK_URL:-}"

# WhatsApp sempre como relay (precisa de conexão persistente)
BRIDGE_RELAY_URL="${BRIDGE_RELAY_URL:-}"
BRIDGE_API_KEY="${BRIDGE_API_KEY:-}"

if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    echo "[telegram] Modo direto via webhook para ${TELEGRAM_WEBHOOK_URL}"
fi
if [ -n "$BRIDGE_RELAY_URL" ]; then
    echo "[bridge] Relay WhatsApp → ${BRIDGE_RELAY_URL}"
fi

# Se HERMES_MODEL, HERMES_PROVIDER, TELEGRAM_BOT_TOKEN ou BRIDGE_RELAY_URL foi definida, gera config.yaml
if [ -n "$HERMES_MODEL" ] || [ -n "$HERMES_PROVIDER" ] || [ -n "$TELEGRAM_BOT_TOKEN" ] || [ -n "$BRIDGE_RELAY_URL" ]; then
    echo "[config] Provider: ${HERMES_PROVIDER:-openrouter}"
    echo "[config] Modelo: ${HERMES_MODEL:-deepseek/deepseek-v4-flash}"
    cat > "$HERMES_HOME/config.yaml" <<EOF
model:
  default: ${HERMES_MODEL:-deepseek/deepseek-v4-flash}
  provider: ${HERMES_PROVIDER:-openrouter}

gateway:
  media_delivery_allow_dirs: []
  trust_recent_files: true
  trust_recent_files_seconds: 600
$(if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
  echo "  platforms:"
  echo "    telegram:"
  echo "      enabled: true"
  echo "      token: ${TELEGRAM_BOT_TOKEN}"
  if [ -n "$TELEGRAM_WEBHOOK_URL" ]; then
    echo "      webhook_url: ${TELEGRAM_WEBHOOK_URL}"
    echo "      webhook_path: /webhooks/telegram"
  fi
fi
if [ -n "$BRIDGE_RELAY_URL" ]; then
  if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    echo "  platforms:"
    echo "    telegram:"
    echo "      enabled: true"
    echo "      relay_url: ${BRIDGE_RELAY_URL}"
    echo "      relay_api_key: ${BRIDGE_API_KEY}"
  fi
  echo "    whatsapp:"
  echo "      enabled: true"
  echo "      relay_url: ${BRIDGE_RELAY_URL}"
  echo "      relay_api_key: ${BRIDGE_API_KEY}"
fi)

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
fi

# ── API Server ────────────────────────────────────────────────
# Configura o Hermes Gateway para expor a API HTTP
export API_SERVER_ENABLED=true
export API_SERVER_HOST=0.0.0.0
export API_SERVER_PORT=${PORT:-7860}

# Se API_SERVER_KEY foi definida, ativa autenticação
if [ -n "$API_SERVER_KEY" ]; then
    export API_SERVER_KEY="$API_SERVER_KEY"
    echo "[auth] API Server com chave de autenticação"
else
    echo "[auth] API Server sem autenticação (qualquer request será aceita)"
    echo "       Recomendo definir API_SERVER_KEY nas Secrets do HF!"
fi

# ── Health check ──────────────────────────────────────────────
# O HF Spaces espera uma resposta HTTP em ${PORT} para considerar
# o Space "Running". O Hermes Gateway API Server expõe /health.

echo "=== Iniciando Hermes Gateway na porta ${API_SERVER_PORT} ==="
echo ""

# Executa o gateway em primeiro plano (foreground)
exec hermes gateway run --verbose
