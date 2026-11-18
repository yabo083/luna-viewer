import { DatabaseSync } from 'node:sqlite'
const token = process.env.TOKEN
const key = 'r-4a066453788c:user:664BAF4D09142330988FECAE7EA6B166'
const from = Number(process.argv[2])
const to = Number(process.argv[3])
const page = await (await fetch('http://127.0.0.1:5028/api/platform/messages?key=' + encodeURIComponent(key) + '&limit=200', { headers: { authorization: 'Bearer ' + token } })).json()
const inRange = page.items.filter((message) => message.time >= from && message.time <= to)
console.log('plugin messages in range:', inRange.length)
for (const message of inRange) console.log(' ', message.time, message.dir, message.id.slice(0, 26), JSON.stringify(message.content).slice(0, 70))
const db = new DatabaseSync('/root/chatluna/data/chatluna.db', { readOnly: true })
const rows = db.prepare("select n, time, payloadJson from chatluna_session_entry where sessionId like ? and kind = 'message' and time between ? and ?").all('route:r-4a066453788c%', from - 1000, to + 1000)
for (const row of rows) {
  const message = JSON.parse(String(row.payloadJson)).message
  if (message.role !== 'assistant') continue
  const text = (message.content || []).filter((block) => block.type === 'text').map((block) => block.text).join('')
  const parts = [...text.matchAll(/<message(?:\s[^>]*)?>([\s\S]*?)<\/message>/gi)].map((m) => m[1])
  console.log('log entry', row.n, row.time, 'segments=', parts.length)
  for (const part of parts) console.log('   seg', JSON.stringify(part.replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim()).slice(0, 80))
}
