import { DatabaseSync } from 'node:sqlite'
const token = process.env.TOKEN
const base = process.env.BASE || 'http://127.0.0.1:5028'
const db = new DatabaseSync(process.env.DB || '/root/chatluna/data/chatluna.db', { readOnly: true })
const norm = (value) => String(value)
  .replace(/<(\/?)([a-zA-Z][\w:-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/g, (whole, closing, tag) => {
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

const fetchPage = async (key) => {
  let all = []
  let before = ''
  for (let i = 0; i < 10; i += 1) {
    const page = await (await fetch(base + '/api/platform/messages?key=' + encodeURIComponent(key) + '&limit=200' + (before ? '&before=' + before : ''), { headers: { authorization: 'Bearer ' + token } })).json()
    all = page.items.concat(all)
    if (!page.hasMore || !page.items.length) break
    before = String(page.items[0].time)
  }
  return all
}

const list = await (await fetch(base + '/api/platform/conversations', { headers: { authorization: 'Bearer ' + token } })).json()
for (const item of list.items) {
  const actual = await fetchPage(item.key)
  const from = actual[0]?.time ?? 0
  const to = actual[actual.length - 1]?.time ?? 0
  const sessions = db.prepare('select id from chatluna_sessions where conversationKey = ? order by lastActiveAt desc limit 200').all(item.key)
  const expected = []
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
          const content = norm(text + fileText)
          if (!content) continue
          expected.push({ dir: 'in', time: Number(block.time) || entryTime, content })
        }
      } else if (message.role === 'assistant') {
        let source = (message.content || []).filter((block) => block.type === 'text').map((block) => block.text).join('')
        if (!source.trim()) source = (message.content || []).filter((block) => block.type === 'tool-call' && ['reply', 'send'].includes(block.toolName)).map((block) => block.input?.content || '').join('')
        let index = 0
        for (const content of segments(source)) {
          expected.push({ dir: 'out', time: entryTime + index, content })
          index += 1
        }
      }
    }
  }
  // 只对齐 App 窗口内的时间段
  const inWindow = expected.filter((item) => item.time >= from - 1000 && item.time <= to + 1000)
  const pool = inWindow.slice()
  let matched = 0
  const unknown = []
  for (const message of actual) {
    const content = norm(message.content)
    let best = -1
    let bestDelta = Infinity
    for (let i = 0; i < pool.length; i += 1) {
      if (pool[i].dir !== message.dir) continue
      const delta = Math.abs(pool[i].time - message.time)
      if (delta > 10000) continue
      if (pool[i].content !== content) continue
      if (delta < bestDelta) { bestDelta = delta; best = i }
    }
    if (best >= 0) { pool.splice(best, 1); matched += 1 } else unknown.push({ ...message, content })
  }
  // 疑似重复：窗口里同一方向、10s 内有没对上的日志条目，且两边都还在
  const suspects = []
  for (const left of unknown) {
    for (const right of pool) {
      if (right.dir !== left.dir) continue
      const delta = Math.abs(right.time - left.time)
      if (delta > 10000) continue
      const one = left.content, two = right.content
      if (one === two || (one.length > 4 && two.length > 4 && (one.includes(two) || two.includes(one)))) {
        suspects.push({ delta, left, right })
      }
    }
  }
  console.log(`${item.key}: window=${actual.length} logWindow=${inWindow.length} matched=${matched} captureOnly=${unknown.length} logOnly=${pool.length} suspectDuplicates=${suspects.length}`)
  for (const suspect of suspects.slice(0, 3)) {
    console.log('   suspect dt=' + suspect.delta)
    console.log('     plugin:', suspect.left.time, suspect.left.dir, JSON.stringify(suspect.left.content).slice(0, 90))
    console.log('     log   :', suspect.right.time, suspect.right.dir, JSON.stringify(suspect.right.content).slice(0, 90))
  }
  for (const message of unknown.slice(0, 2)) console.log('   captureOnly:', message.time, message.dir, JSON.stringify(message.content).slice(0, 70))
  for (const message of pool.slice(0, 2)) console.log('   logOnly:', message.time, message.dir, JSON.stringify(message.content).slice(0, 70))
}
