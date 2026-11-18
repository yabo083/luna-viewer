const token = process.env.TOKEN
const response = await fetch('http://127.0.0.1:5028/api/platform/stream', { headers: { authorization: 'Bearer ' + token } })
console.log('connected', response.status, Date.now())
const reader = response.body.getReader()
const decoder = new TextDecoder()
let buffer = ''
while (true) {
  const { value, done } = await reader.read()
  if (done) break
  buffer += decoder.decode(value, { stream: true })
  let cut
  while ((cut = buffer.indexOf('\n\n')) >= 0) {
    const chunk = buffer.slice(0, cut)
    buffer = buffer.slice(cut + 2)
    const lines = chunk.split('\n').filter((line) => line.startsWith('data: '))
    const at = Date.now()
    if (!lines.length) continue
    let frame = null
    try { frame = JSON.parse(lines.map((line) => line.slice(6)).join('\n')) } catch { continue }
    console.log(JSON.stringify({ at, key: frame.key, dir: frame.message.dir, time: frame.message.time, lag: at - frame.message.time, content: (frame.message.content || '').slice(0, 40), id: frame.message.id.slice(0, 22) }))
  }
}
