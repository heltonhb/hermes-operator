#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────
#  Hermes Operator — Entrypoint para Hugging Face Docker Space
# ─────────────────────────────────────────────────────────────

echo "=== Hermes Operator — Starting ==="

# ── Validação ────────────────────────────────────────────────
if [ -z "$GROQ_API_KEY" ] && [ -z "$OPENROUTER_API_KEY" ]; then
    echo "ERRO: Nenhuma API key configurada!"
    echo "Configure GROQ_API_KEY (recomendado) ou OPENROUTER_API_KEY"
    echo "nas Secrets do Hugging Face Space:"
    echo "  Settings → Repository Secrets → Add secret"
    exit 1
fi

# ── Diretórios ───────────────────────────────────────────────
mkdir -p "$HERMES_HOME"/{logs,sessions}

# ── Validação GROQ ────────────────────────────────────────────
if [ -n "$GROQ_API_KEY" ]; then
    echo "[groq] API key encontrada ✅"
elif [ -n "$OPENROUTER_API_KEY" ]; then
    echo "[groq] AVISO: GROQ_API_KEY não configurada — usando OpenRouter como fallback"
    HERMES_PROVIDER="${HERMES_PROVIDER:-openrouter}"
    HERMES_MODEL="${HERMES_MODEL:-deepseek/deepseek-chat}"
else
    echo "[groq] ERRO: Nenhum provider configurado"
    exit 1
fi

# ── Gera config.yaml ─────────────────────────────────────────
HERMES_MODEL="${HERMES_MODEL:-llama-3.3-70b-versatile}"
HERMES_PROVIDER="${HERMES_PROVIDER:-groq}"

echo "[config] Provider: ${HERMES_PROVIDER}"
echo "[config] Modelo: ${HERMES_MODEL}"

# Monta bloco de plataformas (Telegram NÃO vai no Gateway — usa poller separado)
PLATFORMS_YAML="  platforms:"
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

providers:
  groq:
    name: Groq (Free)
    key_env: GROQ_API_KEY
    api: https://api.groq.com/openai/v1
    default_model: llama-3.3-70b-versatile
    models:
    - llama-3.3-70b-versatile
    - llama-3.1-8b-instant
    - meta-llama/llama-4-scout-17b-16e-instruct
    - deepseek-r1-distill-70b
    api_mode: chat_completions
  openrouter:
    name: OpenRouter
    key_env: OPENROUTER_API_KEY
    api: https://openrouter.ai/api/v1
    default_model: deepseek/deepseek-chat
    models:
    - deepseek/deepseek-chat
    - deepseek/deepseek-r1
    - anthropic/claude-sonnet-4
    api_mode: chat_completions

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

# ── Start Gateway (background) ───────────────────────────────
echo "=== Iniciando Hermes Gateway na porta ${API_SERVER_PORT} ==="
hermes gateway run --verbose &
GATEWAY_PID=$!
echo "[gateway] PID: ${GATEWAY_PID}"

# ── Aguarda API ficar pronta ────────────────────────────────
echo "[gateway] Aguardando API ficar pronta..."
READY=false
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${API_SERVER_PORT}/v1/health" > /dev/null 2>&1; then
        echo "[gateway] API pronta após ${i}s ✅"
        READY=true
        break
    fi
    sleep 1
done

if [ "$READY" != "true" ]; then
    echo "[gateway] AVISO: API não respondeu após 30s — continuando mesmo assim"
fi

# ── Telegram Poller ──────────────────────────────────────────
if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    echo "[telegram] Iniciando poller em background..."
    HERMES_API_URL="http://127.0.0.1:${API_SERVER_PORT}" \
    HERMES_API_KEY="${API_SERVER_KEY}" \
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" \
    python3 /app/telegram_poller.py &
    POLLER_PID=$!
    echo "[telegram] Poller PID: ${POLLER_PID}"
else
    echo "[telegram] TELEGRAM_BOT_TOKEN não configurado — poller não iniciado"
fi

# ── Trap para shutdown limpo ────────────────────────────────
cleanup() {
    echo "=== Shutting down ==="
    kill ${GATEWAY_PID} ${POLLER_PID:-} 2>/dev/null || true
    wait || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── Mantém container vivo até o gateway sair ────────────────
echo "=== Hermes Operator pronto ==="
wait $GATEWAY_PID
echo "[gateway] Processo encerrado"
