FROM python:3.11-slim

WORKDIR /app

# Instala dependências do sistema
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    logrotate \
    && rm -rf /var/lib/apt/lists/*

# Instala Hermes Agent com extras de messaging + DuckDuckGo search gratuito
# (usando urllib sync para Telegram API — evita TimeoutError do aiohttp)
RUN pip install --no-cache-dir "hermes-agent[all]" duckduckgo_search

# Cria diretório do Hermes
ENV HERMES_HOME=/root/.hermes
RUN mkdir -p $HERMES_HOME/logs $HERMES_HOME/sessions

# Copia entrypoint e config
COPY entrypoint.sh /app/entrypoint.sh
COPY config.yaml /app/config.yaml
COPY telegram_poller.py /app/telegram_poller.py
COPY proxy.py /app/proxy.py
COPY telegram_token.txt /app/telegram_token.txt
RUN chmod +x /app/entrypoint.sh

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
