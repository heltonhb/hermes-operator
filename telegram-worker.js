/**
 * Telegram Relay Worker — Cloudflare Worker
 * 
 * Relay mensagens do HF Space para api.telegram.org
 * (contorna o bloqueio SSL do HF Space)
 * 
 * Deploy:
 *   1. Acesse https://dash.cloudflare.com/ → Workers & Pages
 *   2. Create Worker → cole este código → Deploy
 *   3. Defina o segredo WORKER_API_KEY no painel do Worker
 *   4. Copie a URL do Worker (ex: https://telegram-relay.seunome.workers.dev)
 * 
 * Config no HF Space (Secrets):
 *   TELEGRAM_WORKER_URL = https://telegram-relay.seunome.workers.dev
 *   TELEGRAM_WORKER_KEY = sua-chave-secreta-aqui
 *   TELEGRAM_BOT_TOKEN  = (já deve estar configurado)
 */

export default {
  async fetch(request, env) {
    // Apenas POST
    if (request.method !== 'POST') {
      return new Response(JSON.stringify({ error: 'Método não permitido' }), {
        status: 405,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Autenticação
    const auth = request.headers.get('Authorization')
    if (!auth || !auth.startsWith('Bearer ') || auth.slice(7) !== env.WORKER_API_KEY) {
      return new Response(JSON.stringify({ error: 'Não autorizado' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    try {
      const body = await request.json()
      const { token, chat_id, text, parse_mode, action } = body

      if (!token || !chat_id) {
        return new Response(JSON.stringify({ error: 'token e chat_id são obrigatórios' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        })
      }

      // ── sendMessage ──────────────────────────────────────
      if (action === 'sendMessage' || !action) {
        if (!text) {
          return new Response(JSON.stringify({ error: 'text é obrigatório para sendMessage' }), {
            status: 400,
            headers: { 'Content-Type': 'application/json' },
          })
        }

        // Telegram limit: 4096 chars — se passar, chunk automático
        const MAX_TELEGRAM = 4096
        if (text.length > MAX_TELEGRAM) {
          const results = []
          for (let i = 0; i < text.length; i += MAX_TELEGRAM) {
            const chunk = text.slice(i, i + MAX_TELEGRAM)
            const r = await sendTelegram(token, chat_id, chunk, parse_mode || 'Markdown')
            results.push(r)
          }
          return new Response(JSON.stringify({ ok: true, chunks: results }), {
            headers: { 'Content-Type': 'application/json' },
          })
        }

        const result = await sendTelegram(token, chat_id, text, parse_mode || 'Markdown')
        return new Response(JSON.stringify(result), {
          status: result.ok ? 200 : 400,
          headers: { 'Content-Type': 'application/json' },
        })
      }

      // ── sendChatAction ───────────────────────────────────
      if (action === 'sendChatAction') {
        const url = `https://api.telegram.org/bot${token}/sendChatAction`
        const response = await fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ chat_id, action: body.action_value || 'typing' }),
        })
        const result = await response.json()
        return new Response(JSON.stringify(result), {
          status: response.status,
          headers: { 'Content-Type': 'application/json' },
        })
      }

      return new Response(JSON.stringify({ error: `Ação desconhecida: ${action}` }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      })
    } catch (e) {
      return new Response(JSON.stringify({ error: e.message }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      })
    }
  },
}

async function sendTelegram(token, chat_id, text, parse_mode) {
  const url = `https://api.telegram.org/bot${token}/sendMessage`
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      chat_id,
      text,
      parse_mode,
      disable_web_page_preview: true,
    }),
  })
  return await response.json()
}
