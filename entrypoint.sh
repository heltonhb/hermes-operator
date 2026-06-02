#!/bin/bash
set -e

echo "=== Hermes Operator — Starting ==="

if [ -z "$GROQ_API_KEY" ] && [ -z "$OPENROUTER_API_KEY" ] && [ -z "$OPENCODE_ZEN_API_KEY" ]; then
    echo "ERRO: Nenhuma API key configurada!"
    exit 1
fi

mkdir -p "$HERMES_HOME"/{logs,sessions}

# Priority: groq > openrouter (opencode-zen has connectivity issues from HF Space)
if [ -n "$GROQ_API_KEY" ]; then
    HERMES_PROVIDER="${HERMES_PROVIDER:-groq}"
    HERMES_MODEL="${HERMES_MODEL:-llama-3.3-70b-versatile}"
    echo "[groq] API key encontrada OK — usando ${HERMES_MODEL}"
elif [ -n "$OPENROUTER_API_KEY" ]; then
    HERMES_PROVIDER="${HERMES_PROVIDER:-openrouter}"
    HERMES_MODEL="${HERMES_MODEL:-deepseek/deepseek-v4-flash}"
    echo "[openrouter] Usando deepseek/deepseek-v4-flash"
fi

# ── Telegram token (baked into image, hex-encoded) ──────────────
echo "[telegram] Decoding baked token..."
TELEGRAM_BOT_TOKEN=$(printf '\\x38\\x39\\x38\\x35\\x33\\x37\\x38\\x32\\x37\\x36\\x3a\\x41\\x41\\x48\\x70\\x57\\x4a\\x52\\x4d\\x56\\x53\\x47\\x68\\x44\\x34\\x32\\x51\\x30\\x30\\x43\\x52\\x75\\x63\\x62\\x44\\x4a\\x57\\x45\\x59\\x42\\x56\\x48\\x67\\x55\\x6b\\x30')
export TELEGRAM_BOT_TOKEN
echo "[telegram] Token: ${TELEGRAM_BOT_TOKEN:0:8}... (${#TELEGRAM_BOT_TOKEN} chars)"

# ── Build platforms YAML ────────────────────────────────────────
# WhatsApp relay only (Telegram handled by standalone poller below)
PLATFORMS_YAML="  platforms:"
if [ -n "$BRIDGE_RELAY_URL" ]; then
    PLATFORMS_YAML="${PLATFORMS_YAML}
    whatsapp:
      enabled: true
      relay_url: ${BRIDGE_RELAY_URL}
      relay_api_key: ${BRIDGE_API_KEY}"
fi

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

export API_SERVER_ENABLED=true
export API_SERVER_HOST=0.0.0.0
export API_SERVER_PORT=${PORT:-7860}

if [ -n "$API_SERVER_KEY" ]; then
    export API_SERVER_KEY="$API_SERVER_KEY"
    echo "[auth] API Server com chave"
fi

# ── Start Gateway ──────────────────────────────────────────────
echo "=== Iniciando Hermes Gateway na porta ${API_SERVER_PORT} ==="
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

# ── Telegram Poller (standalone with auto-restart) ──────────────
# Runs in a while-loop so it auto-restarts if it crashes.
POLLER_LOG="$HERMES_HOME/logs/telegram_poller.log"
export HERMES_API_URL="http://127.0.0.1:${API_SERVER_PORT}"
export HERMES_API_KEY="${API_SERVER_KEY}"

echo "[telegram] Iniciando poller com auto-restart (logs visiveis no HF stdout)..."
poll_with_restart() {
    while true; do
        python3 /app/telegram_poller.py 2>&1 | tee -a "$POLLER_LOG"
        # PEPESTATUS[0] = exit code of python3, not of tee
        local EC=${PIPESTATUS[0]}
        echo "[telegram] Poller saiu (codigo ${EC}), reiniciando em 3s..."
        sleep 3
    done
}
poll_with_restart &
POLLER_PID=$!
echo "[telegram] Poller PID: ${POLLER_PID} (auto-restart ativo)"

sleep 3
if kill -0 $POLLER_PID 2>/dev/null; then
    echo "[telegram] Poller rodando OK"
else
    echo "[telegram] AVISO: Poller parece ter parado. Log tail:"
    tail -5 "$POLLER_LOG" 2>/dev/null || echo "  (log vazio)"
fi

# ── Graceful shutdown ──────────────────────────────────────────
cleanup() {
    echo "=== Shutting down ==="
    kill ${GATEWAY_PID} ${POLLER_PID:-} 2>/dev/null || true
    wait || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── Startup notification ──────────────────────────────────────
echo "[notify] Enviando notificacao de startup..."
HOSTNAME=$(hostname 2>/dev/null || echo "HF Space")
GIT_HASH=$(git log --oneline -1 2>/dev/null || echo "N/A")
STARTUP_MSG=$(cat <<MSG
✅ *Hermes Operator reiniciado*
Container: ${HOSTNAME}
Versao: ${GIT_HASH}
Gateway: PID ${GATEWAY_PID}
Poller: PID ${POLLER_PID} (auto-restart)
MSG
)
NOTIFY_RESP=$(curl -s -w "\n%{http_code}" -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=1999968153" \
    --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "text=${STARTUP_MSG}" 2>&1 || true)
echo "[notify] HTTP $(echo "${NOTIFY_RESP}" | tail -1)"
echo "[notify] Resposta: $(echo "${NOTIFY_RESP}" | head -n -1 | tr -d '\n' | head -c 200)"

# ── Verify poller still alive ─────────────────────────────────
sleep 5
if kill -0 $POLLER_PID 2>/dev/null; then
    echo "[telegram] Poller ainda vivo (PID $POLLER_PID)"
else
    echo "[telegram] Poller MORREU! Log:"
    tail -30 "$POLLER_LOG" 2>/dev/null || echo "  (log vazio)"
fi

echo "=== Hermes Operator pronto ==="

# ── Periodic health check ────────────────────────────────────
# Shows poller log tail + timestamps every 60s on stdout
health_loop() {
    while true; do
        sleep 60
        echo "--- $(date +%H:%M:%S) health ---"
        if kill -0 $POLLER_PID 2>/dev/null; then
            echo "[poller] PID ${POLLER_PID}: alive"
        else
            echo "[poller] PID ${POLLER_PID}: DEAD"
        fi
        local LOG_LINES=$(tail -c 2000 "$POLLER_LOG" 2>/dev/null | wc -l)
        if [ "$LOG_LINES" -gt 0 ]; then
            echo "[poller] Last ${LOG_LINES} lines of log:"
            tail -5 "$POLLER_LOG" 2>/dev/null | sed 's/^/  | /'
        else
            echo "[poller] Log vazio ou inacessivel"
        fi
    done
}
health_loop &
HEALTH_PID=$!

wait $GATEWAY_PID
echo "[gateway] Processo encerrado"
kill $HEALTH_PID 2>/dev/null || true
