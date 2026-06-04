import os
import aiohttp
from aiohttp import web
import json
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("webhook-proxy")

GATEWAY_URL = "http://127.0.0.1:7861"
TELEGRAM_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
HERMES_API_KEY = os.environ.get("HERMES_API_KEY", "")

async def handle_telegram_webhook(request):
    try:
        data = await request.json()
        log.info(f"Received Telegram webhook update: {data}")
        
        # Extract message or edited_message
        msg = data.get("message") or data.get("edited_message")
        if msg:
            chat = msg.get("chat", {})
            chat_id = chat.get("id")
            text = msg.get("text", "").strip()
            from_user = msg.get("from", {})
            username = from_user.get("username") or from_user.get("first_name", "?")

            if text:
                if text == "/start":
                    await send_telegram_message(chat_id, "Olá! Eu sou o Hermes, seu assistente de IA rodando 100% na nuvem.\n\nMe pergunte qualquer coisa — pesquisas, dúvidas, análises.\nRespondo em português 🇧🇷")
                    return web.Response(text="OK")

                # Send typing action
                await send_telegram_action(chat_id, "typing")

                # Process via local Hermes Gateway
                response = await call_hermes_chat(chat_id, text, username)
                if response:
                    await send_telegram_message(chat_id, response)
                else:
                    await send_telegram_message(chat_id, "Desculpe, tive um problema ao processar sua mensagem. O servidor pode estar inicializando. Tente novamente em alguns segundos.")

        return web.Response(text="OK")
    except Exception as e:
        log.error(f"Error handling webhook: {e}")
        return web.Response(text="Internal Server Error", status=500)

async def call_hermes_chat(chat_id, text, username):
    headers = {"Content-Type": "application/json"}
    if HERMES_API_KEY:
        headers["Authorization"] = f"Bearer {HERMES_API_KEY}"

    payload = {
        "model": "llama-3.3-70b-versatile",
        "messages": [
            {"role": "system", "content": "You are Hermes, an AI assistant. Respond in Portuguese (pt-BR). Keep responses helpful and concise."},
            {"role": "user", "content": text}
        ],
        "max_tokens": 1024,
        "user": f"telegram:{chat_id}:{username}"
    }

    async with aiohttp.ClientSession() as session:
        try:
            async with session.post(f"{GATEWAY_URL}/v1/chat/completions", json=payload, headers=headers, timeout=90) as r:
                if r.status == 200:
                    result = await r.json()
                    return result["choices"][0]["message"]["content"]
                else:
                    err_text = await r.text()
                    log.error(f"Hermes Gateway status {r.status}: {err_text}")
        except Exception as e:
            log.error(f"Error calling Hermes Gateway completions API: {e}")
    return None

async def send_telegram_message(chat_id, text):
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
    
    # Telegram limit: 4096 characters per message
    if len(text) > 4000:
        chunks = [text[i:i+4000] for i in range(0, len(text), 4000)]
    else:
        chunks = [text]

    async with aiohttp.ClientSession() as session:
        for chunk in chunks:
            payload = {
                "chat_id": chat_id,
                "text": chunk,
                "parse_mode": "Markdown"
            }
            try:
                async with session.post(url, json=payload, timeout=15) as r:
                    res = await r.json()
                    if not res.get("ok"):
                        log.error(f"Failed to send telegram message chunk: {res}")
            except Exception as e:
                log.error(f"Error sending telegram message: {e}")

async def send_telegram_action(chat_id, action):
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendChatAction"
    payload = {"chat_id": chat_id, "action": action}
    async with aiohttp.ClientSession() as session:
        try:
            async with session.post(url, json=payload, timeout=5) as r:
                pass
        except Exception:
            pass

async def proxy_handler(request):
    path = request.path
    method = request.method
    headers = {k: v for k, v in request.headers.items() if k.lower() != 'host'}
    data = await request.read()

    url = f"{GATEWAY_URL}{path}"
    if request.query_string:
        url += f"?{request.query_string}"

    async with aiohttp.ClientSession() as session:
        try:
            async with session.request(method, url, headers=headers, data=data, timeout=120) as r:
                body = await r.read()
                return web.Response(
                    body=body,
                    status=r.status,
                    headers={k: v for k, v in r.headers.items() if k.lower() not in ('content-encoding', 'transfer-encoding')}
                )
        except Exception as e:
            log.error(f"Proxy error for {method} {path}: {e}")
            return web.Response(text="Gateway Error", status=502)

async def get_logs_handler(request):
    log_path = "/root/.hermes/logs/proxy.log"
    if os.path.exists(log_path):
        try:
            with open(log_path, "r") as f:
                content = f.read()[-10000:]
                return web.Response(text=content)
        except Exception as e:
            return web.Response(text=f"Error reading log: {e}", status=500)
    return web.Response(text="Log file not found", status=404)

app = web.Application()
app.router.add_post('/telegram/webhook', handle_telegram_webhook)
app.router.add_get('/telegram/logs', get_logs_handler)
app.router.add_route('*', '/{tail:.*}', proxy_handler)

if __name__ == '__main__':
    port = int(os.environ.get("PORT", "7860"))
    log.info(f"Starting proxy server on port {port}, forwarding to {GATEWAY_URL}...")
    web.run_app(app, host='0.0.0.0', port=port)
