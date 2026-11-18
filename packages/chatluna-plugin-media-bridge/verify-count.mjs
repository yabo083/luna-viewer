import { DatabaseSync } from 'node:sqlite'
const token = process.env.TOKEN
const base = process.env.BASE || 'http://127.0.0.1:5028'
const db = new DatabaseSync(process.env.DB || '/root/chatluna/data/chatluna.db', { readOnly: true })
const norm = (value) => String(value).replace(/<(\/?)([a-zA-Z][\w:-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/g, (whole, closing, tag) => {
  if (closing) return ''
  const lower = String(tag).toLowerCase()
  if (lower === 'at') return '@'
  if (lower === 'img' || lower === 'image') return '[图片]'
  if (lower.startsWith('attachment')) return '[图片]'
  return ''
}).replace(/\s+/g, '').replace(/[*_`~]/g, '')
const segments = (text) => {
  const found = [...String(text).matchAll(/<message(?:\s[^>]*)?>([\s\S]*?)<\/message>/gi)].map((m) => m[1])
  return (found.length ? found : [text]).map(norm).filter(Boolean)
}
const page = async (key) => {
  let all = []
  let before = ''
  for (let i = 0; i < 10; i += 1) {
    const result = await (await fetch(base + '/api/platform/messages?key=' + encodeURIComponent(key) + '&limit=200' + (before ? '&before=' + before : ''), { headers: { authorization: 'Bearer ' + token } })).json()
    all = result.items.concat(all)
    if (!result.hasMore || !result.items.length) break
    before = String(result.items[0].time)
  }
  return all
}
const list = await (await fetch(base + '/api/platform/conversations', { headers: { authorization: 'Bearer ' + token } })).json()
console.log('key | plugin | logEnvelopes+segments | captureOnly | logOnlyOutsideWindow')
for (const item of list.items) {
  const actual = await page(item.key)
  const from = actual[0].time, to = actual[actual.length - 1].time
  const sessions = db.prepare('select id from chatluna_sessions where conversationKey = ?').all(item.key)
  let envelopes = 0, segs = 0
  const expected = []
  for (const session of sessions) {
    const rows = db.prepare("select n, time, payloadJson from chatluna_session_entry where sessionId = ? and kind = 'message' order by n desc limit 300").all(session.id)
    for (const row of rows) {
      let message = null
      try { message = JSON.parse(String(row.payloadJson)).message } catch { continue }
      if (!message) continue
      const t = Number(row.time) || Number(row.n)
      if (message.role === 'user') {
        for (const block of message.content || []) {
          if (block.type !== 'envelope' || (block.kind && block.kind !== 'message')) continue
          const text = (block.content || []).filter((c) => c.type === 'text').map((c) => c.text).join('')
          const fileText = (block.content || []).some((c) => c.type === 'file') ? '[图片]' : ''
          const content = norm(text + fileText)
          if (!content) continue
          envelopes += 1
          expected.push({ dir: 'in', time: Number(block.time) || t, content })
        }
      } else if (message.role === 'assistant') {
        let source = (message.content || []).filter((b) => b.type === 'text').map((b) => b.text).join('')
        if (!source.trim()) source = (message.content || []).filter((b) => b.type === 'tool-call' && ['reply', 'send'].includes(b.toolName)).map((b) => b.input?.content || '').join('')
        let index = 0
        for (const content of segments(source)) { segs += 1; expected.push({ dir: 'out', time: t + index, content }); index += 1 }
      }
    }
  }
  const pool = expected.filter((e) => e.time >= from - 1000 && e.time <= to + 1000)
  let matched = 0, captureOnly = 0
  for (const message of actual) {
    const content = norm(message.content)
    let best = -1, bestDelta = Infinity
    for (let i = 0; i < pool.length; i += 1) {
      if (pool[i].dir !== message.dir) continue
      const delta = Math.abs(pool[i].time - message.time)
      if (delta > 10000) continue
      const one = pool[i].content, two = content
      if (one !== two && !(one.length > 4 && (two.includes(one) || one.includes(two)))) continue
      if (delta < bestDelta) { bestDelta = delta; best = i }
    }
    if (best >= 0) { pool.splice(best, 1); matched += 1 } else captureOnly += 1
  }
  console.log(`${item.key} | ${actual.length} | ${envelopes}+${segs}=${envelopes + segs} | ${captureOnly} | ${pool.length}`)
}
