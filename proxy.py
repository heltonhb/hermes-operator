import os
import aiohttp
from aiohttp import web
import json
import logging
import traceback
import asyncio
import glob
import time
import urllib.request
import urllib.error
import threading

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("webhook-proxy")

# ── Pending messages queue (for local bridge to collect) ──
PENDING_FILE = "/tmp/hermes_pending.json"
_pending_lock = threading.Lock()

def _load_pending():
    try:
        if os.path.exists(PENDING_FILE):
            with open(PENDING_FILE) as f:
                return json.load(f)
    except Exception:
        pass
    return []

def _save_pending(messages):
    with _pending_lock:
        with open(PENDING_FILE, "w") as f:
            json.dump(messages, f, ensure_ascii=False)

def _add_pending(chat_id, text):
    pending = _load_pending()
    pending.append({
        "chat_id": chat_id,
        "text": text,
        "ts": time.time(),
        "id": len(pending) + 1
    })
    _save_pending(pending)
    log.info(f"Pending message queued for chat {chat_id} ({len(pending)} total)")

GATEWAY_URL = "http://127.0.0.1:7861"
TELEGRAM_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
HERMES_API_KEY = os.environ.get("HERMES_API_KEY", "")
DEFAULT_MODEL = os.environ.get("HERMES_MODEL", "llama-3.3-70b-versatile")


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
    headers = {
        "Content-Type": "application/json",
        "X-Hermes-Session-Id": f"tg_{chat_id}"
    }
    if HERMES_API_KEY:
        headers["Authorization"] = f"Bearer {HERMES_API_KEY}"

    payload = {
        "model": DEFAULT_MODEL,
        "messages": [
            {"role": "system", "content": "You are Hermes, an AI assistant. Respond in Portuguese (pt-BR). Keep responses helpful and concise."},
            {"role": "user", "content": text}
        ],
        "max_tokens": 1024,
        "user": f"tg_{chat_id}"
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
    """Queue message for local bridge delivery (SSL to api.telegram.org blocked from HF Space)."""
    # Telegram limit: 4096 characters per message
    if len(text) > 4000:
        chunks = [text[i:i+4000] for i in range(0, len(text), 4000)]
    else:
        chunks = [text]

    for chunk in chunks:
        _add_pending(chat_id, chunk)
        await asyncio.sleep(0.1)

async def send_telegram_action(chat_id, action):
    """Chat actions not supported from HF Space (SSL blocked). No-op."""
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

async def get_gateway_logs_handler(request):
    log_path = "/root/.hermes/logs/gateway.log"
    if os.path.exists(log_path):
        try:
            with open(log_path, "r") as f:
                content = f.read()[-10000:]
                return web.Response(text=content)
        except Exception as e:
            return web.Response(text=f"Error reading log: {e}", status=500)
    return web.Response(text="Log file not found", status=404)

async def get_pending_handler(request):
    """Return and clear all pending Telegram messages (for local bridge)."""
    pending = _load_pending()
    _save_pending([])
    return web.json_response(pending)

# ── Cron Outbox Monitoring ──────────────────────────────────
CRON_OUTPUT_DIR = "/root/.hermes/cron/output"
TRACKING_FILE = "/root/.hermes/telegram_sent_files.json"
WATCHED_JOB_IDS = ["3db6ea02dc8d"]
TARGET_CHAT_ID = 1999968153

def load_sent_files():
    if os.path.exists(TRACKING_FILE):
        try:
            with open(TRACKING_FILE) as f:
                return set(json.load(f))
        except Exception:
            return set()
    return set()

def save_sent_files(sent_set):
    try:
        os.makedirs(os.path.dirname(TRACKING_FILE), exist_ok=True)
        with open(TRACKING_FILE, "w") as f:
            json.dump(list(sent_set), f)
    except Exception as e:
        log.error(f"Error saving tracking file: {e}")

async def check_cron_outbox():
    sent_files = load_sent_files()
    new_sent = False

    for job_id in WATCHED_JOB_IDS:
        job_dir = os.path.join(CRON_OUTPUT_DIR, job_id)
        if not os.path.isdir(job_dir):
            continue

        for fpath in sorted(glob.glob(os.path.join(job_dir, "*.md"))):
            if fpath in sent_files:
                continue
            # Skip files older than 26 hours
            try:
                mtime = os.path.getmtime(fpath)
                if (time.time() - mtime) > 60 * 60 * 26:
                    continue
                with open(fpath) as f:
                    content = f.read().strip()
                if not content:
                    continue
                log.info(f"Outbox: sending {os.path.basename(fpath)} to Telegram")
                await send_telegram_message(TARGET_CHAT_ID, content)
                sent_files.add(fpath)
                new_sent = True
                await asyncio.sleep(1)
            except Exception as e:
                log.error(f"Outbox error reading {fpath}: {e}")

    if new_sent:
        save_sent_files(sent_files)

async def cron_checker_loop():
    log.info("Starting background cron outbox checker loop...")
    while True:
        try:
            await check_cron_outbox()
        except asyncio.CancelledError:
            break
        except Exception as e:
            log.error(f"Error in cron checker loop: {e}")
        await asyncio.sleep(60)

async def start_background_tasks(app):
    app['cron_checker'] = asyncio.create_task(cron_checker_loop())

async def cleanup_background_tasks(app):
    app['cron_checker'].cancel()
    try:
        await app['cron_checker']
    except asyncio.CancelledError:
        pass

app = web.Application()
app.on_startup.append(start_background_tasks)
app.on_cleanup.append(cleanup_background_tasks)

app.router.add_post('/telegram/webhook', handle_telegram_webhook)
app.router.add_get('/telegram/logs', get_logs_handler)
app.router.add_get('/telegram/gateway_logs', get_gateway_logs_handler)
app.router.add_get('/telegram/pending', get_pending_handler)
app.router.add_route('*', '/{tail:.*}', proxy_handler)

if __name__ == '__main__':
    port = int(os.environ.get("PORT", "7860"))
    log.info(f"Starting proxy server on port {port}, forwarding to {GATEWAY_URL}...")
    web.run_app(app, host='0.0.0.0', port=port)
