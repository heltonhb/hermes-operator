#!/bin/bash
set -e

echo "=== Hermes Operator — Starting ==="

if [ -z "$GROQ_API_KEY" ] && [ -z "$OPENROUTER_API_KEY" ]; then
    echo "ERRO: Nenhuma API key configurada!"
    exit 1
fi

mkdir -p "$HERMES_HOME"/{logs,sessions}

if [ -n "$GROQ_API_KEY" ]; then
    echo "[groq] API key encontrada OK"
else
    HERMES_PROVIDER="${HERMES_PROVIDER:-openrouter}"
    HERMES_MODEL="${HERMES_MODEL:-deepseek/deepseek-chat}"
fi

HERMES_MODEL="${HERMES_MODEL:-llama-3.3-70b-versatile}"
HERMES_PROVIDER="${HERMES_PROVIDER:-groq}"

# ── Telegram token (baked into image, hex-encoded) ────────────
# Decode BEFORE starting gateway so the native Telegram platform
# can pick up TELEGRAM_BOT_TOKEN from the environment.
echo "[telegram] Decoding baked token..."
TELEGRAM_BOT_TOKEN=$(printf  '\x38\x39\x38\x35\x33\x37\x38\x32\x37\x36\x3a\x41\x41\x48\x70\x57\x4a\x52\x4d\x56\x53\x47\x68\x44\x34\x32\x51\x30\x30\x43\x52\x75\x63\x62\x44\x4a\x57\x45\x59\x42\x56\x48\x67\x55\x6b\x30')
export TELEGRAM_BOT_TOKEN
echo "[telegram] Token: ${TELEGRAM_BOT_TOKEN:0:8}... (${#TELEGRAM_BOT_TOKEN} chars)"

# ── Build platforms YAML ────────────────────────────────────
# Uses native Hermes Gateway Telegram platform instead of standalone poller
PLATFORMS_YAML="  platforms:
    telegram:
      enabled: true"
if [ -n "$BRIDGE_RELAY_URL" ]; then
    PLATFORMS_YAML="${PLATFORMS_YAML}
    whatsapp:
      enabled: true
      relay_url: ${BRIDGE_RELAY_URL}
      relay_api_key: ${BRIDGE_API_KEY}"
fi

# Export Telegram home channel for cron delivery
if [ -n "$TELEGRAM_HOME_CHANNEL" ]; then
    export TELEGRAM_HOME_CHANNEL
    echo "[telegram] Home channel: $TELEGRAM_HOME_CHANNEL"
fi

# ── Generate config ──────────────────────────────────────────
cat > "$HERMES_HOME/config.yaml" <<CONFEOF
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
CONFEOF

# ── API Server config ────────────────────────────────────────
export API_SERVER_ENABLED=true
export API_SERVER_HOST=0.0.0.0
export API_SERVER_PORT=${PORT:-7860}

if [ -n "$API_SERVER_KEY" ]; then
    export API_SERVER_KEY="$API_SERVER_KEY"
    echo "[auth] API Server com chave"
fi

# ── Start Gateway ────────────────────────────────────────────
# The native Telegram platform handles polling inside the gateway process.
# No separate poller needed — the gateway manages the Telegram connection,
# session routing, tool execution, and message delivery natively.
echo "=== Iniciando Hermes Gateway (porta ${API_SERVER_PORT}) ==="
echo "  Telegram: nativo (dentro do gateway)"
echo "  WhatsApp: $( [ -n \"$BRIDGE_RELAY_URL\" ] && echo 'relay configurado' || echo 'desligado' )"

hermes gateway run --verbose >> "$HERMES_HOME/logs/gateway.log" 2>&1 &
GATEWAY_PID=$!
echo "[gateway] PID: ${GATEWAY_PID}"

echo "[gateway] Aguardando API ficar pronta..."
READY=false
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${API_SERVER_PORT}/v1/health" > /dev/null 2>&1; then
        echo "[gateway] API pronta depois de ${i}s OK"
        READY=true
        break
    fi
    sleep 1
done

if [ "$READY" != "true" ]; then
    echo "[gateway] AVISO: API nao respondeu depois de 30s"
fi

# ── Notify Telegram ──────────────────────────────────────────
echo "[notify] Enviando notificacao de startup..."
HOSTNAME=$(hostname 2>/dev/null || echo "HF Space")
GIT_HASH=$(git log --oneline -1 2>/dev/null || echo "N/A")
STARTUP_MSG=$(cat <<MSG
✅ *Hermes Operator reiniciado*
Container: ${HOSTNAME}
Versao: ${GIT_HASH}
Gateway: PID ${GATEWAY_PID} (Telegram nativo)
MSG
)
NOTIFY_RESP=$(curl -s -w "\n%{http_code}" -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=1999968153" \
    --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "text=${STARTUP_MSG}" 2>&1 || true)
echo "[notify] HTTP $(echo "${NOTIFY_RESP}" | tail -1)"
echo "[notify] Resposta: $(echo "${NOTIFY_RESP}" | head -n -1 | tr -d '\n' | head -c 200)"

# ── Graceful shutdown ────────────────────────────────────────
cleanup() {
    echo "=== Shutting down ==="
    kill ${GATEWAY_PID} 2>/dev/null || true
    wait || true
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "=== Hermes Operator pronto ==="
wait $GATEWAY_PID
echo "[gateway] Processo encerrado"