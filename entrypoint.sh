#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────
#  Hermes Operator — Entrypoint para Hugging Face Docker Space
# ─────────────────────────────────────────────────────────────
# Espera:
#   OPENROUTER_API_KEY   (obrigatório — configurar nas Secrets do HF)
#   HERMES_MODEL         (opcional — padrão: deepseek/deepseek-chat)
#   HERMES_PROVIDER      (opcional — padrão: openrouter)
#   API_SERVER_KEY       (opcional — chave para autenticar requests)
# ─────────────────────────────────────────────────────────────

echo "=== Hermes Operator — Starting ==="

# Validação: precisa de pelo menos uma API key configurada
if [ -z "$OPENROUTER_API_KEY" ]; then
    echo "ERRO: OPENROUTER_API_KEY não configurada!"
    echo "Configure nas Secrets do Hugging Face Space:"
    echo "  Settings → Repository Secrets → Add secret"
    echo ""
    echo "  OPENROUTER_API_KEY = sk-or-..."
    exit 1
fi

# Cria diretório do Hermes se não existir
mkdir -p "$HERMES_HOME"/{logs,sessions}

# Se HERMES_MODEL foi definida, atualiza config.yaml
if [ -n "$HERMES_MODEL" ]; then
    echo "[config] Modelo: $HERMES_MODEL"
    cat > "$HERMES_HOME/config.yaml" <<EOF
model:
  default: ${HERMES_MODEL}
  provider: ${HERMES_PROVIDER:-openrouter}

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
