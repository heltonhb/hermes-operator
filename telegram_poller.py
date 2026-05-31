#!/usr/bin/env python3
"""
Telegram Bridge para HF Space
Polla mensagens do Telegram e usa Hermes API Server pra processar.
Respostas sao enviadas de volta via Telegram Bot API.
Independe do Telegram platform adapter do Hermes Gateway.
"""
import os, sys, json, time, logging, threading, requests

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("telegram-bridge")

# ── Config ──────────────────────────────────────────────────────
TELEGRAM_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
HERMES_API = os.environ.get("HERMES_API_URL", "http://localhost:7860")
HERMES_API_KEY = os.environ.get("HERMES_API_KEY", "")
# ────────────────────────────────────────────────────────────────

def tg_api(method, data=None):
    """Call Telegram Bot API"""
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/{method}"
    try:
        r = requests.post(url, json=data, timeout=15)
        return r.json()
    except Exception as e:
        log.error(f"tg_api({method}): {e}")
        return {"ok": False, "description": str(e)}

def hermes_chat(chat_id, text, user_id, username):
    """Send a message to Hermes for processing"""
    # Build user messages in OpenAI format
    messages = [
        {"role": "system", "content": "You are Hermes, an AI assistant. Respond to the user's message."},
        {"role": "user", "content": text}
    ]
    
    headers = {"Content-Type": "application/json"}
    if HERMES_API_KEY:
        headers["Authorization"] = f"Bearer {HERMES_API_KEY}"
    
    try:
        r = requests.post(
            f"{HERMES_API}/v1/chat/completions",
            json={
                "model": "deepseek/deepseek-v4-flash",
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
        else:
            log.error(f"Hermes API error {r.status_code}: {r.text[:200]}")
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
    
    # Skip commands we don't handle
    if text.startswith("/"):
        text = text  # Handle commands normally
        if text == "/start":
            tg_api("sendMessage", {
                "chat_id": chat_id,
                "text": "Olá! Eu sou o Hermes, seu assistente de IA. Como posso ajudar?",
                "parse_mode": "Markdown"
            })
            return
    
    log.info(f"From @{username} (chat {chat_id}): {text[:60]}...")
    
    # Show typing indicator
    tg_api("sendChatAction", {"chat_id": chat_id, "action": "typing"})
    
    # Process via Hermes
    response = hermes_chat(chat_id, text, user_id, username)
    
    if response:
        # Send response
        tg_api("sendMessage", {
            "chat_id": chat_id,
            "text": response,
            "parse_mode": "Markdown"
        })
    else:
        tg_api("sendMessage", {
            "chat_id": chat_id,
            "text": "Desculpe, tive um problema ao processar sua mensagem. Tente novamente mais tarde."
        })

def poll():
    """Main polling loop"""
    log.info(f"Telegram Bridge started for @HermesHeltonBot")
    log.info(f"Hermes API: {HERMES_API}")
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
            elif updates.get("error_code") == 409:
                log.warning("409 Conflict - another instance is polling, waiting...")
                time.sleep(15)
            else:
                log.error(f"API error: {updates.get('description', str(updates))}")
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
        log.info(f"Bot @{bot_user} authenticated!")
    else:
        log.error(f"Bot auth failed: {bot_info.get('description')}")
        sys.exit(1)
    
    # Poll in foreground
    poll()

if __name__ == "__main__":
    main()
