const token = process.env.TOKEN
const base = process.env.BASE || 'http://127.0.0.1:5028'
const norm = (value) => String(value).replace(/\s+/g, '').replace(/[*_`~]/g, '').replace(/\[引用\]/g, '')
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
  const items = await fetchPage(item.key)
  const pairs = []
  for (let i = 0; i < items.length; i += 1) {
    for (let j = i + 1; j < items.length; j += 1) {
      const left = items[i], right = items[j]
      if (left.dir !== right.dir) continue
      const delta = Math.abs(left.time - right.time)
      if (delta > 10000) continue
      const one = norm(left.content), two = norm(right.content)
      const similar = one === two || (one.length > 6 && two.length > 6 && (one.includes(two) || two.includes(one)))
      if (similar) pairs.push({ delta, left, right })
    }
  }
  console.log(`${item.key}: messages=${items.length} similarPairs=${pairs.length}`)
  for (const pair of pairs.slice(0, 6)) {
    console.log('  dt=' + pair.delta)
    console.log('   A', pair.left.time, pair.left.dir, pair.left.id.slice(0, 26), JSON.stringify(pair.left.content).slice(0, 100))
    console.log('   B', pair.right.time, pair.right.dir, pair.right.id.slice(0, 26), JSON.stringify(pair.right.content).slice(0, 100))
  }
}
