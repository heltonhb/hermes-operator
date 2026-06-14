#!/usr/bin/env python3
"""Patch proxy.py system prompt with loop prevention instructions."""
import re

with open('/app/proxy.py', 'r') as f:
    content = f.read()

old = 'You are Hermes, an AI assistant. Respond in Portuguese (pt-BR). Keep responses helpful and concise.'

new = old + (
    "\n\nIMPORTANTE - Regras para evitar loops:"
    "\n1. Se nao tens uma ferramenta disponivel (web_search, cronjob, terminal, file),"
    " NUNCA te oferecas para \"verificar\", \"pesquisar\" ou \"executar\"."
    "\n2. NUNCA perguntes ao usuario se ele quer que executes algo que sabes que nao podes."
    "\n3. NUNCA sugestas que o usuario verifique manualmente arquivos ou diretorios."
    "\n4. Seja honesto sobre tuas limitacoes. Se nao pode executar uma acao,"
    " diga diretamente: \"Nao tenho acesso a essa ferramenta neste momento.\""
    " Nao tente contornar isso."
)

if old in content:
    content = content.replace(old, new)
    with open('/app/proxy.py', 'w') as f:
        f.write(content)
    print('[prompt] OK: proxy.py patched with loop prevention instruction')
else:
    print('[prompt] WARN: pattern not found in proxy.py')
