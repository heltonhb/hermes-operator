FROM python:3.11-slim

WORKDIR /app

# Instala dependências do sistema
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Instala Hermes Agent com extras de messaging (Telegram, WhatsApp, etc.)
RUN pip install --no-cache-dir "hermes-agent[all]"

# Cria diretório do Hermes
ENV HERMES_HOME=/root/.hermes
RUN mkdir -p $HERMES_HOME/logs $HERMES_HOME/sessions

# Copia entrypoint e config
COPY entrypoint.sh /app/entrypoint.sh
COPY config.yaml /app/config.yaml
RUN chmod +x /app/entrypoint.sh

# Porta do HF Spaces
ENV PORT=7860

CMD ["/app/entrypoint.sh"]
