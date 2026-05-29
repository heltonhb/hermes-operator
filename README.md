---
title: Hermes Operator
emoji: 😻
colorFrom: indigo
colorTo: purple
sdk: docker
pinned: false
short_description: Hermes Agent API Server — OpenAI-compatible chat API
---

# Hermes Operator 🐙

[Hermes Agent](https://hermes-agent.nousresearch.com/) rodando como API HTTP compatível com OpenAI no Hugging Face Spaces.

## Endpoints

| Método | Rota | Descrição |
|--------|------|-----------|
| `POST` | `/v1/chat/completions` | Chat Completion (formato OpenAI) |
| `POST` | `/v1/responses` | Responses API (stateful) |
| `GET` | `/v1/models` | Lista modelos disponíveis |
| `GET` | `/health` | Health check do serviço |

## Como usar

```bash
# Chat completion simples
curl -X POST https://heltonhb-hermes-operator.hf.space/v1/chat/completions \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "hermes",
    "messages": [{"role": "user", "content": "Olá! Quem é você?"}]
  }'

# Com sessão contínua (memória entre requests)
curl -X POST ... \
  -H "X-Hermes-Session-Id: minha-sessao-1" \
  -d '{...}'

# Health check
curl https://heltonhb-hermes-operator.hf.space/health
```

## Configuração

### Secrets obrigatórias

Configure no Hugging Face Space em **Settings → Repository Secrets**:

| Secret | Descrição |
|--------|-----------|
| `OPENROUTER_API_KEY` | Chave da API OpenRouter ([criar](https://openrouter.ai/keys)) |
| `API_SERVER_KEY` | Chave para autenticar requests na API |

### Secrets opcionais

| Secret | Padrão | Descrição |
|--------|--------|-----------|
| `HERMES_MODEL` | `deepseek/deepseek-chat` | Modelo a usar via OpenRouter |
| `HERMES_PROVIDER` | `openrouter` | Provider (só mude se não usar OpenRouter) |
