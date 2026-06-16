FROM python:3.11-slim

WORKDIR /app

# Instala dependências do sistema (Node.js para WhatsApp bridge)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    logrotate \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Instala Node.js 22.x para WhatsApp Baileys bridge
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/* && \
    node --version && npm --version

# Timeout maior pro pip (HF Space é lento)
ENV PIP_DEFAULT_TIMEOUT=120

# Instala apenas os extras necessários (não [all] — reduz drasticamente o build)
# messaging = Telegram/WhatsApp | web = DuckDuckGo search | cron = cron jobs
RUN pip install --no-cache-dir "hermes-agent[messaging,web,cron]" ddgs duckduckgo_search

# Cria diretório do Hermes
ENV HERMES_HOME=/root/.hermes
RUN mkdir -p $HERMES_HOME/logs $HERMES_HOME/sessions

# Copia entrypoint e config
COPY entrypoint.sh /app/entrypoint.sh
COPY config.yaml /app/config.yaml
COPY proxy.py /app/proxy.py
RUN chmod +x /app/entrypoint.sh

# ── WhatsApp Baileys bridge ──
COPY whatsapp-bridge/ /app/whatsapp-bridge/
COPY whatsapp-creds.json /app/whatsapp-creds.json
RUN cd /app/whatsapp-bridge && \
    npm install --legacy-peer-deps --no-audit --no-fund 2>&1 | tail -3 && \
    # Substitui o bridge padrão do pip pelo nosso (QR capture)
    rm -rf /usr/local/lib/python3.11/site-packages/hermes_agent/scripts/whatsapp-bridge || true && \
    mkdir -p /usr/local/lib/python3.11/site-packages/hermes_agent/scripts && \
    ln -sf /app/whatsapp-bridge /usr/local/lib/python3.11/site-packages/hermes_agent/scripts/whatsapp-bridge && \
    rm -rf /usr/local/lib/python3.11/site-packages/scripts/whatsapp-bridge || true && \
    mkdir -p /usr/local/lib/python3.11/site-packages/scripts && \
    ln -sf /app/whatsapp-bridge /usr/local/lib/python3.11/site-packages/scripts/whatsapp-bridge

# Token do Telegram via env var TELEGRAM_BOT_TOKEN (HF Space Secret)

# Copia configurações iniciais de cron para inicializar o volume
RUN mkdir -p /app/initial_hermes/cron
COPY cron_jobs.json /app/initial_hermes/cron/jobs.json
COPY config/logrotate.conf /etc/logrotate.d/hermes-operator

# Porta do HF Spaces
ENV PORT=7860

# Adiciona job de logrotate para execução diária
RUN mkdir -p /etc/cron.d && \
    echo "0 0 * * * root /usr/sbin/logrotate /etc/logrotate.d/hermes-operator" > /etc/cron.d/hermes-operator-logrotate && \
    chmod 0644 /etc/cron.d/hermes-operator-logrotate

CMD ["/app/entrypoint.sh"]
