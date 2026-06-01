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

if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    echo "[telegram] Iniciando poller em background..."
    POLLER_LOG="$HERMES_HOME/logs/telegram_poller.log"
    # ShellCheck: env vars sourced from container secrets
    export HERMES_API_URL="http://127.0.0.1:${API_SERVER_PORT}"
    export HERMES_API_KEY="${API_SERVER_KEY}"
    export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"

    # Check what's available
    echo "[telegram] Python check: $(command -v python3 || echo 'python3 not found')"
    echo "[telegram] Python check: $(command -v python || echo 'python not found')"
    test -f /app/telegram_poller.py && echo "[telegram] Poller file: OK" || echo "[telegram] Poller file: MISSING"

    # Determine which python to use
    POLLER_PY=""
    if command -v python3 >/dev/null 2>&1; then
        POLLER_PY="python3"
    elif command -v python >/dev/null 2>&1; then
        POLLER_PY="python"
    fi

    if [ -n "$POLLER_PY" ]; then
        $POLLER_PY /app/telegram_poller.py >> "$POLLER_LOG" 2>&1 &
        POLLER_PID=$!
        echo "[telegram] Poller PID: ${POLLER_PID} (using $POLLER_PY)"
        sleep 3
        if kill -0 $POLLER_PID 2>/dev/null; then
            echo "[telegram] Poller rodando OK"
        else
            echo "[telegram] Poller MORREU! Log tail:"
            tail -5 "$POLLER_LOG" 2>/dev/null || echo "  (log vazio)"
        fi
    else
        echo "[telegram] ERRO: Python nao encontrado!"
    fi
else
    echo "[telegram] token nao configurado — poller nao iniciado"
fi

cleanup() {
    echo "=== Shutting down ==="
    kill ${GATEWAY_PID} ${POLLER_PID:-} 2>/dev/null || true
    wait || true
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "=== Hermes Operator pronto ==="
wait $GATEWAY_PID
echo "[gateway] Processo encerrado"
