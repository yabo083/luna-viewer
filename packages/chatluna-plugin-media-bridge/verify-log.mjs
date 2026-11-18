// 独立复算：把 DB 里的 message 条目按插件同样的规则拆成平台消息，再和 HTTP 接口返回的
// 消息列表对上（内容 + 时间就近），用于验证「不重复、不缺漏」。
import { DatabaseSync } from 'node:sqlite'
import { readFileSync } from 'node:fs'

const token = process.env.TOKEN
const base = process.env.BASE || 'http://127.0.0.1:5028'
const db = new DatabaseSync(process.env.DB || '/root/chatluna/data/chatluna.db', { readOnly: true })
const strip = (value) => String(value).replace(/<(\/?)([a-zA-Z][\w:-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/g, (whole, closing, tag) => {
  if (closing) return ''
  const lower = String(tag).toLowerCase()
  if (lower === 'at') return '@'
  if (lower === 'img' || lower === 'image') return '[图片]'
  if (lower.startsWith('attachment')) return '[图片]'
  return ''
}).replace(/\s+/g, '').replace(/[*_`~]/g, '')

const segments = (text) => {
  const found = [...String(text).matchAll(/<message(?:\s[^>]*)?>([\s\S]*?)<\/message>/gi)].map((m) => m[1])
  return (found.length ? found : [text]).map(strip).filter(Boolean)
}

const fetchPage = async (key) => {
  let all = []
  let before = ''
  for (let i = 0; i < 10; i += 1) {
    const url = base + '/api/platform/messages?key=' + encodeURIComponent(key) + '&limit=200' + (before ? '&before=' + before : '')
    const page = await (await fetch(url, { headers: { authorization: 'Bearer ' + token } })).json()
    all = page.items.concat(all)
    if (!page.hasMore || !page.items.length) break
    before = String(page.items[0].time)
  }
  return all
}

const list = await (await fetch(base + '/api/platform/conversations', { headers: { authorization: 'Bearer ' + token } })).json()
for (const item of list.items) {
  const sessions = db.prepare('select id from chatluna_sessions where conversationKey = ? order by lastActiveAt desc limit 200').all(item.key)
  const expected = []
  let envelopeCount = 0
  let assistantCount = 0
  for (const session of sessions) {
    const rows = db.prepare("select n, time, payloadJson from chatluna_session_entry where sessionId = ? and kind = 'message' order by n desc limit 300").all(session.id)
    for (const row of rows) {
      let message = null
      try { message = JSON.parse(String(row.payloadJson)).message } catch { continue }
      if (!message) continue
      const entryTime = Number(row.time) || Number(row.n)
      if (message.role === 'user') {
        for (const block of message.content || []) {
          if (block.type !== 'envelope' || (block.kind && block.kind !== 'message')) continue
          const text = (block.content || []).filter((child) => child.type === 'text').map((child) => child.text).join('')
          const fileText = (block.content || []).some((child) => child.type === 'file') ? '[图片]' : ''
          const content = strip(text + fileText)
          if (!content) continue
          envelopeCount += 1
          expected.push({ dir: 'in', time: Number(block.time) || entryTime, content })
        }
      } else if (message.role === 'assistant') {
        let source = (message.content || []).filter((block) => block.type === 'text').map((block) => block.text).join('')
        if (!source.trim()) {
          source = (message.content || []).filter((block) => block.type === 'tool-call' && ['reply', 'send'].includes(block.toolName)).map((block) => block.input?.content || '').join('')
        }
        let index = 0
        for (const content of segments(source)) {
          assistantCount += 1
          expected.push({ dir: 'out', time: entryTime + index, content })
          index += 1
        }
      }
    }
  }
  const actual = await fetchPage(item.key)
  const pool = expected.slice()
  let matched = 0
  const unmatched = []
  for (const message of actual) {
    const content = strip(message.content)
    let best = -1
    let bestDelta = Infinity
    for (let i = 0; i < pool.length; i += 1) {
      if (pool[i].dir !== message.dir) continue
      const delta = Math.abs(pool[i].time - message.time)
      if (delta > 10000) continue
      if (pool[i].content !== content && !(pool[i].content.length > 4 && content.includes(pool[i].content))) continue
      if (delta < bestDelta) { bestDelta = delta; best = i }
    }
    if (best >= 0) { pool.splice(best, 1); matched += 1 } else unmatched.push(message)
  }
  console.log(`${item.key}: plugin=${actual.length} logEnvelopes=${envelopeCount} logSegments=${assistantCount} expected=${expected.length} matched=${matched} extra(capture)=${unmatched.length} missing=${pool.length}`)
  for (const message of unmatched.slice(0, 3)) console.log('   extra', message.time, message.dir, JSON.stringify(message.content).slice(0, 50))
  for (const message of pool.slice(0, 3)) console.log('   missing', message.time, message.dir, JSON.stringify(message.content).slice(0, 50))
}
