#!/bin/bash
set -e

echo "=== Hermes Operator — Starting ==="

if [ -z "$GROQ_API_KEY" ] && [ -z "$OPENROUTER_API_KEY" ] && [ -z "$OPENCODE_ZEN_API_KEY" ] && [ -z "$OPENCODE_API_KEY" ]; then
    echo "ERRO: Nenhuma API key configurada!"
    exit 1
fi

# Inicializa o volume persistente se estiver vazio
if [ ! -f "$HERMES_HOME/cron/jobs.json" ]; then
    echo "[volume] Inicializando volume persistente a partir de /app/initial_hermes..."
    mkdir -p "$HERMES_HOME/cron"
    cp -r /app/initial_hermes/* "$HERMES_HOME/" || true
fi

mkdir -p "$HERMES_HOME"/{logs,sessions}

# Inicia o cron se não estiver rodando
if ! pgrep cron > /dev/null; then
    echo "[cron] Iniciando serviço cron..."
    service cron start
else
    echo "[cron] Cron já está rodando"
fi

# Priority: groq > opencode > openrouter
if [ -n "$GROQ_API_KEY" ]; then
    HERMES_PROVIDER="${HERMES_PROVIDER:-groq}"
    HERMES_MODEL="${HERMES_MODEL:-llama-3.3-70b-versatile}"
    echo "[groq] API key encontrada OK — usando ${HERMES_MODEL}"
elif [ -n "$OPENCODE_ZEN_API_KEY" ] || [ -n "$OPENCODE_API_KEY" ]; then
    HERMES_PROVIDER="${HERMES_PROVIDER:-opencode}"
    HERMES_MODEL="${HERMES_MODEL:-deepseek/deepseek-v4-flash:free}"
    echo "[opencode] API key encontrada OK — usando ${HERMES_MODEL}"
elif [ -n "$OPENROUTER_API_KEY" ]; then
    HERMES_PROVIDER="${HERMES_PROVIDER:-openrouter}"
    HERMES_MODEL="${HERMES_MODEL:-deepseek/deepseek-v4-flash}"
    echo "[openrouter] Usando deepseek/deepseek-v4-flash"
fi

# ── Telegram token (from environment or local file) ─
echo "[telegram] Checking for TELEGRAM_BOT_TOKEN in environment..."
if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    # Fallback: try to read from local file
    if [ -f /app/telegram_token.txt ]; then
        TELEGRAM_BOT_TOKEN=$(cat /app/telegram_token.txt)
        export TELEGRAM_BOT_TOKEN
        echo "[telegram] Token carregado de telegram_token.txt: ${TELEGRAM_BOT_TOKEN:0:8}... (${#TELEGRAM_BOT_TOKEN} chars)"
    else
        echo "[telegram] AVISO: TELEGRAM_BOT_TOKEN não está definido! Telegram não responderá mensagens."
    fi
else
    echo "[telegram] Token encontrado no ambiente: ${TELEGRAM_BOT_TOKEN:0:8}... (${#TELEGRAM_BOT_TOKEN} chars)"
fi

# ── Build platforms YAML ────────────────────────────────────────
# WhatsApp relay only (Telegram handled by standalone poller below)
# Explicitly disable Telegram polling on the gateway since we use webhook-proxy.py
PLATFORMS_YAML="  platforms:
    telegram:
      enabled: false"
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
    - deepseek/deepseek-v4-flash
    - deepseek/deepseek-v4-pro
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
web:
  backend: ddgs
platform_toolsets:
  api_server:
    - web
CONFEOF
cp "$HERMES_HOME/config.yaml" /app/config.yaml

export API_SERVER_ENABLED=true
export API_SERVER_HOST=0.0.0.0
# The gateway API server will listen internally on 7861
export API_SERVER_PORT=7861

API_SERVER_KEY="${API_SERVER_KEY:-hermes-space-key-2026}"
export API_SERVER_KEY="$API_SERVER_KEY"
echo "[auth] API Server key pronta"

# ── Start Gateway ──────────────────────────────────────────────
echo "=== Iniciando Hermes Gateway na porta ${API_SERVER_PORT} ==="
hermes gateway run --verbose >> "$HERMES_HOME/logs/gateway.log" 2>&1 &
GATEWAY_PID=$!
echo "[gateway] PID: ${GATEWAY_PID}"

echo "[gateway] Aguardando API ficar pronta..."
READY=false
for i in $(seq 1 30); do
    # Verifica se o gateway está respondendo
    if curl -sf "http://127.0.0.1:${API_SERVER_PORT}/v1/health" > /dev/null 2>&1; then
        # Verifica dependências externas se o gateway estiver respondendo
        DEPS_OK=true
        
        # Verifica Telegram se o token estiver definido
        if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
            if ! curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" > /dev/null 2>&1; then
                echo "[gateway] AVISO: Não foi possível conectar com a API do Telegram"
                DEPS_OK=false
            fi
        fi
        
        # Verifica providers de LLM configurados
        if [ -n "$GROQ_API_KEY" ]; then
            if ! curl -sf -H "Authorization: Bearer $GROQ_API_KEY" "https://api.groq.com/openai/v1/models" > /dev/null 2>&1; then
                echo "[gateway] AVISO: Não foi possível conectar com a API do Groq"
                DEPS_OK=false
            fi
        elif [ -n "$OPENROUTER_API_KEY" ]; then
            if ! curl -sf -H "Authorization: Bearer $OPENROUTER_API_KEY" "https://openrouter.ai/api/v1/models" > /dev/null 2>&1; then
                echo "[gateway] AVISO: Não foi possível conectar com a API do OpenRouter"
                DEPS_OK=false
            fi
        elif [ -n "$OPENCODE_ZEN_API_KEY" ] || [ -n "$OPENCODE_API_KEY" ]; then
            # Para OpenCode, verificamos se conseguimos alcançar o endpoint
            if ! curl -sf "https://opencode.ai/zen/go/v1/models" > /dev/null 2>&1; then
                echo "[gateway] AVISO: Não foi possível conectar com a API do OpenCode"
                DEPS_OK=false
            fi
        fi
        
        if [ "$DEPS_OK" = true ]; then
            echo "[gateway] API pronta depois de ${i}s OK"
            READY=true
            break
        else
            echo "[gateway] API respondendo, mas algumas dependências estão indisponíveis (tentativa $i/30)"
        fi
    else
        echo "[gateway] Aguardando API ficar pronta... (tentativa $i/30)"
    fi
    sleep 1
done

if [ "$READY" != "true" ]; then
    echo "[gateway] AVISO: API nao respondeu depois de 30s"
fi

# ── Start Webhook Proxy ──────────────────────────────────────────
# Starts proxy.py on port 7860 (which is the port HF Spaces exposes)
PROXY_LOG="$HERMES_HOME/logs/proxy.log"
export HERMES_API_URL="http://127.0.0.1:7861"
export HERMES_API_KEY="${API_SERVER_KEY}"

echo "[proxy] Iniciando proxy webhook na porta ${PORT:-7860} (logs em $PROXY_LOG)..."
proxy_with_restart() {
    while true; do
        python3 /app/proxy.py 2>&1 | tee -a "$PROXY_LOG"
        local EC=${PIPESTATUS[0]}
        echo "[proxy] Proxy saiu (codigo ${EC}), reiniciando em 3s..."
        sleep 3
    done
}
proxy_with_restart &
PROXY_PID=$!
echo "[proxy] Proxy PID: ${PROXY_PID} (auto-restart ativo)"

sleep 3
if kill -0 $PROXY_PID 2>/dev/null; then
    echo "[proxy] Proxy rodando OK"
else
    echo "[proxy] AVISO: Proxy parece ter parado. Log tail:"
    tail -5 "$PROXY_LOG" 2>/dev/null || echo "  (log vazio)"
fi

# ── Graceful shutdown ──────────────────────────────────────────
cleanup() {
    echo "=== Shutting down ==="
    kill ${GATEWAY_PID} ${PROXY_PID:-} 2>/dev/null || true
    wait || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── Startup notification ──────────────────────────────────────
echo "[notify] Enviando notificacao de startup..."
HOSTNAME=$(hostname 2>/dev/null || echo "HF Space")
GIT_HASH=$(git log --oneline -1 2>/dev/null || echo "N/A")
STARTUP_MSG=$(cat <<MSG
✅ *Hermes Operator reiniciado (Webhook)*
Container: ${HOSTNAME}
Versao: ${GIT_HASH}
Gateway: PID ${GATEWAY_PID} (porta 7861)
Proxy: PID ${PROXY_PID} (porta ${PORT:-7860})
MSG
)
NOTIFY_RESP=$(curl -s -w "\n%{http_code}" -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=1999968153" \
    --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "text=${STARTUP_MSG}" 2>&1 || true)
echo "[notify] HTTP $(echo "${NOTIFY_RESP}" | tail -1)"
echo "[notify] Resposta: $(echo "${NOTIFY_RESP}" | head -n -1 | tr -d '\n' | head -c 200)"

# ── Verify proxy still alive ─────────────────────────────────
sleep 5
if kill -0 $PROXY_PID 2>/dev/null; then
    echo "[proxy] Proxy ainda vivo (PID $PROXY_PID)"
    # Set the webhook URL on Telegram
    if [ -n "$FLY_APP_NAME" ]; then
        HOST_DOMAIN="${FLY_APP_NAME}.fly.dev"
    else
        HOST_DOMAIN="${SPACE_HOST:-heltonhb-hermes-operator.hf.space}"
    fi
    WEBHOOK_URL="https://${HOST_DOMAIN}/telegram/webhook"
    echo "[webhook] Registrando webhook no Telegram: ${WEBHOOK_URL}..."
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
        -d "url=${WEBHOOK_URL}" \
        -d "allowed_updates=[\"message\",\"edited_message\",\"callback_query\"]"
else
    echo "[proxy] Proxy MORREU! Log:"
    tail -30 "$PROXY_LOG" 2>/dev/null || echo "  (log vazio)"
fi

echo "=== Hermes Operator pronto ==="

# ── Periodic health check ────────────────────────────────────
# Shows proxy log tail + timestamps every 60s on stdout
health_loop() {
    while true; do
        sleep 60
        echo "--- $(date +%H:%M:%S) health ---"
        if kill -0 $PROXY_PID 2>/dev/null; then
            echo "[proxy] PID ${PROXY_PID}: alive"
        else
            echo "[proxy] Proxy status: DEAD"
        fi
        
        # Verifica se o gateway está respondendo
        if curl -sf "http://127.0.0.1:${API_SERVER_PORT}/v1/health" > /dev/null 2>&1; then
            echo "[gateway] Status: OK"
        else
            echo "[gateway] Status: INDISPONÍVEL"
        fi
        
        local LOG_LINES=$(tail -c 2000 "$PROXY_LOG" 2>/dev/null | wc -l)
        if [ "$LOG_LINES" -gt 0 ]; then
            echo "[proxy] Last ${LOG_LINES} lines of log:"
            tail -5 "$PROXY_LOG" 2>/dev/null | sed 's/^/  | /'
        else
            echo "[proxy] Log vazio ou inacessivel"
        fi
    done
}
health_loop &
HEALTH_PID=$!

wait $GATEWAY_PID
echo "[gateway] Processo encerrado"
kill $HEALTH_PID 2>/dev/null || true
