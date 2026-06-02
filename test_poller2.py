#!/usr/bin/env python3
"""Test: send /ping, wait 90s, check if poller consumed it"""
import requests, time, os

# Read token from .env
token = None
env_path = os.path.expanduser("~/.hermes/.env")
with open(env_path) as f:
    for line in f:
        key = "TELEGRAM_BOT_TOKEN"
        prefix = key + "="
        if line.startswith(prefix):
            token = line.split("=", 1)[1].split("#")[0].strip().strip("'\"")
            break

print(f"Token loaded: {len(token)} chars")

# Verify
r = requests.get(f"https://api.telegram.org/bot{token}/getMe")
data = r.json()
print(f"getMe: {data.get('ok')} - @{data.get('result',{}).get('username','?')}")

# Check if poller active now
url = f"https://api.telegram.org/bot{token}/getUpdates"
r = requests.post(url, json={"offset": 0, "timeout": 5, "limit": 1})
data = r.json()
poller_now = data.get("error_code") == 409
print(f"Poller ativo AGORA? {'SIM (409)' if poller_now else 'NAO'}")
if not poller_now:
    print(f"  Updates: {len(data.get('result',[]))}")

# Send /ping
print("\n--- Enviando /ping ---")
r2 = requests.post(f"https://api.telegram.org/bot{token}/sendMessage", json={
    "chat_id": 1999968153,
    "text": "/ping",
    "parse_mode": "Markdown"
})
j2 = r2.json()
j2_ok = j2.get("ok", False)
msg_id = j2.get("result", {}).get("message_id", "?")
print(f"sendMessage ok? {j2_ok}, msg_id={msg_id}")
if not j2_ok:
    print(f"Erro: {j2.get('description','?')}")
    exit(1)

# Wait
print("\nAguardando 90s para o poller processar...")
print("(Veja se o bot respondeu no Telegram)")
time.sleep(90)

# Check
print("\n--- Verificando ---")
r3 = requests.post(url, json={"offset": 0, "timeout": 5, "limit": 5})
r4 = requests.post(url, json={"offset": 0, "timeout": 5, "limit": 1})

data3 = r3.json()
poller_now2 = r4.json().get("error_code") == 409
print(f"Poller ativo? {'SIM (409)' if poller_now2 else 'NAO'}")
updates = data3.get("result", [])
print(f"Updates pendentes: {len(updates)}")

if len(updates) == 0:
    print("\n0 updates = POLLER CONSUMIU a mensagem!")
    print("Se o bot NAO respondeu no Telegram:")
    print("  -> O problema esta no handle_update() ou hermes_chat()")
    print("  -> Veja os logs do HF Space na aba Logs")
    print("  -> Procure por [telegram] ou [telegram-bridge]")
elif poller_now2:
    print("\nPoller ativo mas mensagem ainda pendente?")
    print("  Possivel: poller iniciou apos enviarmos a msg")
else:
    print("\nNao ha updates E poller nao esta ativo")
    print("  Possivel: Gateway reiniciou ou poller crashou")
    for u in updates:
        m = u.get("message") or {}
        print(f"  msg_id={m.get('message_id')}: {m.get('text','?')}")
