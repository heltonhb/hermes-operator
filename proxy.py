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

# ── Cloudflare Worker Relay (alternativa à bridge local) ──
TELEGRAM_WORKER_URL = os.environ.get("TELEGRAM_WORKER_URL", "")
TELEGRAM_WORKER_KEY = os.environ.get("TELEGRAM_WORKER_KEY", "")
WORKER_ENABLED = bool(TELEGRAM_WORKER_URL and TELEGRAM_WORKER_KEY)
if TELEGRAM_WORKER_URL:
    log.info(f"Telegram Worker relay configurado: {TELEGRAM_WORKER_URL}")
else:
    log.info("Telegram Worker NÃO configurado — usando bridge local (legado)")

# ═══════════════════════════════════════════════
# QR Code para WhatsApp
# ═══════════════════════════════════════════════

QR_FILE = "/tmp/whatsapp-qr.txt"

async def handle_whatsapp_qr(request):
    """Serve the WhatsApp QR code as an HTML page with JS-generated QR."""
    qr_text = ""
    if os.path.exists(QR_FILE):
        with open(QR_FILE, "r") as f:
            qr_text = f.read().strip()
    if not qr_text:
        return web.Response(
            text=json.dumps({
                "status": "no_qr",
                "message": "Nenhum QR code disponivel. Se o bridge estiver rodando, aguarde a geracao.",
                "session_exists": os.path.exists(os.path.expanduser("~/.hermes/whatsapp/session/creds.json"))
            }),
            content_type="application/json"
        )
    # Serve as HTML page with JS QR generation
    html_page = f"""<!DOCTYPE html>
<html lang="pt-BR">
<head><meta charset="utf-8"><title>WhatsApp QR - Hermes Operator</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body {{ font-family: sans-serif; background: #111; color: #eee; display: flex;
  flex-direction: column; align-items: center; justify-content: center;
  min-height: 100vh; margin: 0; padding: 20px; }}
h1 {{ color: #25D366; margin-bottom: 10px; }}
p {{ color: #aaa; margin-bottom: 20px; }}
#qrcode img {{ max-width: 400px; width: 100%; height: auto; }}
.loading {{ color: #666; font-style: italic; }}
</style>
</head>
<body>
<h1>💬 WhatsApp QR Code</h1>
<p>Escaneie com WhatsApp → Menu → Dispositivos conectados</p>
<div id="qrcode" class="loading">Gerando QR code...</div>
<script src="https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js"></script>
<script>
new QRCode(document.getElementById("qrcode"), {{
  text: {json.dumps(qr_text)},
  width: 300, height: 300
}});
document.getElementById("qrcode").classList.remove("loading");
</script>
</body>
</html>"""
    return web.Response(text=html_page, content_type="text/html; charset=utf-8")


async def handle_whatsapp_pairing_code(request):
    """Serve the WhatsApp pairing code if available."""
    PAIRING_FILE = "/tmp/whatsapp-pairing-code.txt"
    code = ""
    if os.path.exists(PAIRING_FILE):
        with open(PAIRING_FILE, "r") as f:
            code = f.read().strip()
    if code:
        return web.json_response({"ok": True, "code": code, "phone": "5511971685906",
            "instructions": "Abra WhatsApp → Menu (⋮) → Dispositivos conectados → Conectar dispositivo → Conectar com número de telefone. Digite o código acima."})
    else:
        # Check if already connected via bridge health
        import subprocess
        try:
            r = subprocess.run(["curl", "-sf", "http://127.0.0.1:3000/health"], capture_output=True, text=True, timeout=5)
            if r.returncode == 0:
                import json as j
                health = j.loads(r.stdout)
                if health.get("status") == "connected":
                    return web.json_response({"status": "connected"})
        except:
            pass
        return web.json_response({"status": "no_code", "message": "Aguardando bridge gerar pairing code..."})


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

async def _send_via_worker(chat_id, text, parse_mode="Markdown"):
    """POST mensagem ao Cloudflare Worker, que relay para Telegram API.
    O Worker usa seu próprio env.TELEGRAM_BOT_TOKEN — o proxy não precisa do token."""
    log.info(f"Worker send: chat_id={chat_id} text_len={len(text)}")
    async with aiohttp.ClientSession() as session:
        try:
            async with session.post(
                TELEGRAM_WORKER_URL,
                headers={
                    "Authorization": f"Bearer {TELEGRAM_WORKER_KEY}",
                    "Content-Type": "application/json"
                },
                json={
                    "chat_id": chat_id,
                    "text": text,
                    "parse_mode": parse_mode
                },
                timeout=30
            ) as r:
                if r.status != 200:
                    err = await r.text()
                    log.warning(f"Worker relay error ({r.status}): {err[:200]}")
                    # If it's a parse error (invalid markdown), retry without parse_mode
                    if r.status == 400 and "parse entities" in err:
                        log.info("Retrying without parse_mode (plain text)")
                        async with session.post(
                            TELEGRAM_WORKER_URL,
                            headers={"Authorization": f"Bearer {TELEGRAM_WORKER_KEY}", "Content-Type": "application/json"},
                            json={"chat_id": chat_id, "text": text},
                            timeout=30
                        ) as r2:
                            if r2.status == 200:
                                log.info(f"Sent via Worker (plain text) to chat {chat_id}")
                                return True
                            err2 = await r2.text()
                            log.error(f"Worker relay error even without parse_mode ({r2.status}): {err2[:200]}")
                    return False
                log.info(f"Sent via Worker to chat {chat_id}")
                return True
        except asyncio.TimeoutError:
            log.error(f"Worker relay timeout for chat {chat_id}")
        except Exception as e:
            log.error(f"Worker relay failed for chat {chat_id}: {e}")
    return False

async def send_telegram_message(chat_id, text):
    """Send message — via Worker (preferencial) ou fallback bridge local."""
    if len(text) > 4000:
        chunks = [text[i:i+4000] for i in range(0, len(text), 4000)]
    else:
        chunks = [text]

    for chunk in chunks:
        if WORKER_ENABLED:
            ok = await _send_via_worker(chat_id, chunk)
            if not ok:
                # Fallback: queue for local bridge
                _add_pending(chat_id, chunk)
                log.warning(f"Worker falhou, pendente na fila local para chat {chat_id}")
        else:
            _add_pending(chat_id, chunk)
        await asyncio.sleep(0.1)

async def send_telegram_action(chat_id, action):
    """Send typing action via Worker relay (ou no-op se não configurado)."""
    if not WORKER_ENABLED:
        return
    async with aiohttp.ClientSession() as session:
        try:
            await session.post(
                TELEGRAM_WORKER_URL,
                headers={
                    "Authorization": f"Bearer {TELEGRAM_WORKER_KEY}",
                    "Content-Type": "application/json"
                },
                json={
                    "chat_id": chat_id,
                    "action": "sendChatAction",
                    "action_value": action
                },
                timeout=10
            )
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
app.router.add_get('/whatsapp/qr', handle_whatsapp_qr)
app.router.add_get('/whatsapp/status', lambda r: handle_whatsapp_qr(r))
app.router.add_get('/whatsapp/pairing-code', handle_whatsapp_pairing_code)

# ── WhatsApp Bridge endpoints (proxied to internal bridge on :3000) ──
BRIDGE_URL = "http://127.0.0.1:3000"

async def _proxy_bridge_post(path, data):
    """Forward a POST to the internal bridge and return its response."""
    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(f"{BRIDGE_URL}{path}", json=data, timeout=15) as r:
                body = await r.json()
                return web.json_response(body, status=r.status)
    except asyncio.TimeoutError:
        return web.json_response({"ok": False, "error": "Bridge timeout"}, status=504)
    except Exception as e:
        return web.json_response({"ok": False, "error": str(e)}, status=502)

async def handle_whatsapp_reset(request):
    """Reset WhatsApp session (delete creds, restart bridge)."""
    return await _proxy_bridge_post("/reset-session", {})

async def handle_whatsapp_pairing(request):
    """Request pairing code for given phone number."""
    try:
        data = await request.json()
    except Exception:
        data = {}
    phone = data.get("phone", "5511971685906")
    return await _proxy_bridge_post("/pairing", {"phone": phone})

app.router.add_post("/whatsapp/reset", handle_whatsapp_reset)
app.router.add_post("/whatsapp/pairing", handle_whatsapp_pairing)

app.router.add_route('*', '/{tail:.*}', proxy_handler)

if __name__ == '__main__':
    port = int(os.environ.get("PORT", "7860"))
    log.info(f"Starting proxy server on port {port}, forwarding to {GATEWAY_URL}...")
    web.run_app(app, host='0.0.0.0', port=port)
