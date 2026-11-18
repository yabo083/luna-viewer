const token = process.env.TOKEN
const key = process.argv[2]
const needle = process.argv[3]
const page = await (await fetch('http://127.0.0.1:5028/api/platform/messages?key=' + encodeURIComponent(key) + '&limit=200', { headers: { authorization: 'Bearer ' + token } })).json()
for (const message of page.items) {
  if (String(message.content).includes(needle)) console.log(message.time, message.dir, message.id.slice(0, 30), JSON.stringify(message.content).slice(0, 160))
}
