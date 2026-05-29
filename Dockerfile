FROM python:3.11-slim

# Instala dependências do sistema
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Instala o Hermes Agent + aiohttp (necessário para o API Server)
RUN pip install --no-cache-dir --upgrade hermes-agent aiohttp

# Define diretório de trabalho
WORKDIR /app

# Configura o HERMES_HOME para um local controlado
ENV HERMES_HOME=/app/hermes-home
ENV PYTHONUNBUFFERED=1

# Cria diretórios do Hermes
RUN mkdir -p $HERMES_HOME/logs $HERMES_HOME/sessions

# Copia config e entrypoint
COPY config.yaml $HERMES_HOME/config.yaml
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Porta do Hugging Face Space (definida pela env PORT, padrão 7860)
EXPOSE 7860

# Cria usuário não-root (prática HF)
RUN useradd -m -u 1000 user && chown -R user:user /app
USER user

ENTRYPOINT ["/app/entrypoint.sh"]
