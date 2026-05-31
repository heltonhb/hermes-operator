#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────
#  Hermes Operator — Entrypoint para Hugging Face Docker Space
# ─────────────────────────────────────────────────────────────
# Provider: opencode-zen (deepseek-v4-flash-free), gratuito sem chave
# Opcionais via env vars:
#   HERMES_MODEL         — modelo (padrão: deepseek-v4-flash-free)
#   HERMES_PROVIDER      — provider (padrão: opencode-zen)
#   OPENCODE_ZEN_BASE_URL— base URL (padrão: https://opencode.ai/zen/v1)
#   API_SERVER_KEY       — chave para autenticar requests na API
# ─────────────────────────────────────────────────────────────

echo "=== Hermes Operator — Starting ==="

# Provider opencode-zen é gratuito — não precisa de API key
echo "[info] Provider: opencode-zen (gratuito, sem chave necessária)"

# Cria diretório do Hermes se não existir
mkdir -p "$HERMES_HOME"/{logs,sessions}

# Se HERMES_MODEL ou HERMES_PROVIDER foi definida, atualiza config.yaml
if [ -n "$HERMES_MODEL" ] || [ -n "$HERMES_PROVIDER" ]; then
    echo "[config] Provider: ${HERMES_PROVIDER:-opencode-zen}"
    echo "[config] Modelo: ${HERMES_MODEL:-deepseek-v4-flash-free}"
    cat > "$HERMES_HOME/config.yaml" <<EOF
model:
  default: ${HERMES_MODEL:-deepseek-v4-flash-free}
  provider: ${HERMES_PROVIDER:-opencode-zen}

gateway:
  media_delivery_allow_dirs: []
  trust_recent_files: true
  trust_recent_files_seconds: 600

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
