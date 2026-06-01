#!/usr/bin/env python3
"""
Telegram Bridge para HF Space
Polla mensagens do Telegram e usa Hermes API Server pra processar.
Respostas sao enviadas de volta via Telegram Bot API.
Independe do Telegram platform adapter do Hermes Gateway.
"""
import os, sys, json, time, logging, threading, requests

# Force IPv4 for Telegram API (avoid IPv6 SYN-SENT hangs)
try:
    import socket
    requests.packages.urllib3.util.connection.HAS_IPV6 = False
    log = logging.getLogger("telegram-bridge")
    log.info("Forced IPv4 for HTTP connections")
except Exception:
    pass

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("telegram-bridge")

# ── Config ──────────────────────────────────────────────────────
# Tenta ler token do .env se não estiver no ambiente
TELEGRAM_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
if not TELEGRAM_TOKEN:
    env_path = os.path.expanduser("~/.hermes/.env")
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                if line.startswith("TELEGRAM_BOT_TOKEN="):
                    TELEGRAM_TOKEN = line.split("=", 1)[1].split("#")[0].strip().strip("'\"")
                    break

HERMES_API = os.environ.get("HERMES_API_URL", "https://heltonhb-hermes-operator.hf.space")
HERMES_API_KEY = os.environ.get("HERMES_API_KEY", "")
if not HERMES_API_KEY:
    # Try reading from .hermes-bridge-key (created during WhatsApp bridge setup)
    bridge_key_path = os.path.expanduser("~/.hermes-bridge-key")
    if os.path.exists(bridge_key_path):
        with open(bridge_key_path) as f:
            HERMES_API_KEY = f.read().strip()
        log.info(f"Read API key from {bridge_key_path}")
if not HERMES_API_KEY:
    # Try .env for API_SERVER_KEY
    env_path = os.path.expanduser("~/.hermes/.env")
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                if "API_SERVER_KEY" in line and "=" in line and not line.startswith("#"):
                    val = line.split("=", 1)[1].split("#")[0].strip().strip("'\"")
                    if val and val != "your_key_here":
                        HERMES_API_KEY = val
                        break
# ────────────────────────────────────────────────────────────────


def tg_api(method, data=None):
    """Call Telegram Bot API"""
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/{method}"
    try:
        # Must be > poll timeout (30s) + buffer
        r = requests.post(url, json=data, timeout=45)
        return r.json()
    except Exception as e:
        log.error(f"tg_api({method}): {e}")
        return {"ok": False, "description": str(e)}


def hermes_chat(chat_id, text, user_id, username):
    """Send a message to Hermes for processing"""
    messages = [
        {"role": "system", "content": "You are Hermes, an AI assistant. Respond in Portuguese (pt-BR). Keep responses helpful and concise."},
        {"role": "user", "content": text}
    ]

    headers = {"Content-Type": "application/json"}
    if HERMES_API_KEY:
        headers["Authorization"] = f"Bearer {HERMES_API_KEY}"

    try:
        r = requests.post(
            f"{HERMES_API}/v1/chat/completions",
            json={
                "model": "llama-3.3-70b-versatile",
                "messages": messages,
                "max_tokens": 1024,
                "user": f"telegram:{chat_id}:{username}"
            },
            headers=headers,
            timeout=60
        )
        if r.status_code == 200:
            result = r.json()
            response = result["choices"][0]["message"]["content"]
            return response
        elif r.status_code == 404:
            log.error(f"Hermes API 404: a URL {HERMES_API}/v1/chat/completions não responde")
            return None
        else:
            log.error(f"Hermes API error {r.status_code}: {r.text[:300]}")
            return None
    except requests.exceptions.ConnectionError:
        log.error(f"Hermes API connection error: {HERMES_API} inacessível")
        return None
    except Exception as e:
        log.error(f"Hermes API exception: {e}")
        return None


def handle_update(update):
    """Process a single Telegram update"""
    uid = update.get("update_id")

    # Extract message
    msg = update.get("message") or update.get("edited_message")
    if not msg:
        log.debug(f"Update {uid}: no message, skipping")
        return

    # Get message details
    chat = msg.get("chat", {})
    chat_id = chat.get("id")
    chat_type = chat.get("type", "private")
    text = msg.get("text", "").strip()
    from_user = msg.get("from", {})
    user_id = from_user.get("id")
    username = from_user.get("username") or from_user.get("first_name", "?")

    # Skip non-text messages for now
    if not text:
        return

    # Handle commands
    if text.startswith("/"):
        if text == "/start":
            tg_api("sendMessage", {
                "chat_id": chat_id,
                "text": "Olá! Eu sou o Hermes, seu assistente de IA.\n\n"
                        "Me pergunte qualquer coisa — pesquisas, dúvidas, análises.\n"
                        "Respondo em português 🇧🇷",
                "parse_mode": "Markdown"
            })
            return
        elif text == "/ping":
            tg_api("sendMessage", {
                "chat_id": chat_id,
                "text": "Pong! 🏓\n\nBridge local → Space API ativo.",
                "parse_mode": "Markdown"
            })
            return

    log.info(f"From @{username} (chat {chat_id}): {text[:60]}...")

    # Show typing indicator
    tg_api("sendChatAction", {"chat_id": chat_id, "action": "typing"})

    # Process via Hermes
    response = hermes_chat(chat_id, text, user_id, username)

    if response:
        log.info(f"Response to @{username}: {len(response)} chars")
        # Telegram has 4096 char limit, split if needed
        if len(response) > 4000:
            # Split into chunks of 4000 chars
            for i in range(0, len(response), 4000):
                chunk = response[i:i+4000]
                tg_api("sendMessage", {
                    "chat_id": chat_id,
                    "text": chunk,
                    "parse_mode": "Markdown"
                })
                time.sleep(0.5)  # Avoid hitting rate limits
        else:
            tg_api("sendMessage", {
                "chat_id": chat_id,
                "text": response,
                "parse_mode": "Markdown"
            })
    else:
        tg_api("sendMessage", {
            "chat_id": chat_id,
            "text": "Desculpe, tive um problema ao processar sua mensagem. "
                    "O servidor pode estar inicializando (cold start). "
                    "Tente novamente em alguns segundos."
        })


def poll():
    """Main polling loop"""
    log.info(f"=== Telegram Bridge started ===")
    log.info(f"  Bot: @HermesHeltonBot")
    log.info(f"  Hermes API: {HERMES_API}")
    log.info(f"  Auth: {'Bearer key' if HERMES_API_KEY else 'No auth'}")
    offset = 0
    fail_count = 0

    while True:
        try:
            updates = tg_api("getUpdates", {
                "offset": offset,
                "timeout": 30,
                "limit": 10,
                "allowed_updates": ["message", "callback_query", "edited_message"]
            })

            if updates.get("ok"):
                fail_count = 0
                for update in updates.get("result", []):
                    uid = update["update_id"]
                    log.info(f"Update {uid}")
                    handle_update(update)
                    offset = uid + 1
                    # Brief pause between updates
                    time.sleep(0.3)
            elif updates.get("error_code") == 409:
                log.warning("409 Conflict - another poller is active, waiting 15s...")
                time.sleep(15)
            else:
                error_desc = updates.get("description", str(updates)[:100])
                log.error(f"API error: {error_desc}")
                fail_count += 1
                time.sleep(min(fail_count * 2, 30))
        except Exception as e:
            log.error(f"Poll exception: {e}")
            fail_count += 1
            time.sleep(min(fail_count * 2, 30))


def main():
    if not TELEGRAM_TOKEN:
        log.error("TELEGRAM_BOT_TOKEN not set")
        sys.exit(1)

    bot_info = tg_api("getMe")
    if bot_info.get("ok"):
        bot_user = bot_info["result"]["username"]
        log.info(f"Bot @{bot_user} authenticated! ✅")
    else:
        log.error(f"Bot auth failed: {bot_info.get('description')}")
        sys.exit(1)

    # Quick API test
    log.info(f"Testing Hermes API connection...")
    try:
        r = requests.get(f"{HERMES_API}/v1/health", timeout=10)
        if r.status_code == 200:
            log.info(f"Hermes API reachable ✅ ({r.json().get('status', 'ok')})")
        else:
            log.warning(f"Hermes API health returned {r.status_code}")
    except Exception as e:
        log.warning(f"Hermes API health check failed: {e}")
        log.warning("Bridge will still try on each message")

    # Poll in foreground
    poll()


if __name__ == "__main__":
    main()
