// chatluna-plugin-media-bridge
// 把 agent 工作区（data/chatluna/agents-work）里的文件通过 Bearer 保护的
// GET /api/workspace?path=<相对路径> 暴露给客户端（移动端渲染消息里的图片）。
// 只读；路径必须落在工作区内。后续版本会在这里加：上传、临时签名、缩略图。
//
// 另外提供 GET /api/traffic：入站消息的旁路记录。纯指令消息（如 `chatluna-菜单`）
// 在 Koishi 的指令层就被消费掉了，既不落会话日志也不加载 agent，客户端完全看不到；
// 这里在事件层抄一份环形缓冲，让 App 的「消息记录」页能看见它们。
import { readFile, stat } from 'node:fs/promises'
import { extname, join, normalize, resolve, sep } from 'node:path'

export const name = 'chatluna-workspace-files'
export const inject = ['server']

const MIME = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/plain; charset=utf-8',
  '.json': 'application/json'
}

// 环形缓冲：500 条足够覆盖「刚发完指令回 App 查看」的窗口，再多只是吃内存。
const TRAFFIC_CAPACITY = 500
const TRAFFIC_MAX_CONTENT = 500

// `session.content` 是元素序列化后的原始标记（`<img .../>`、`<at id=.../>`），
// 直接给人看没有意义；按元素类型翻译成可读片段。
const ELEMENT_LABELS = {
  img: '[图片]',
  image: '[图片]',
  face: '[表情]',
  emoji: '[表情]',
  quote: '[引用]',
  file: '[文件]',
  audio: '[语音]',
  video: '[视频]'
}

function intParam(value, fallback, min, max) {
  const parsed = Number.parseInt(value ?? '', 10)
  if (!Number.isSafeInteger(parsed)) return fallback
  return Math.min(Math.max(parsed, min), max)
}

function textOf(value) {
  return typeof value === 'string' ? value : value == null ? '' : String(value)
}

function describeElements(elements) {
  if (!Array.isArray(elements)) return ''
  let text = ''
  for (const element of elements) {
    const type = element?.type
    if (type === 'text') {
      text += textOf(element.attrs?.content)
    } else if (type === 'at') {
      const name = textOf(element.attrs?.name)
      const id = textOf(element.attrs?.id)
      text += '@' + (name || id.slice(-4)) + ' '
    } else {
      const label = ELEMENT_LABELS[type]
      if (label) text += label
    }
  }
  return text
}

function trafficEntry(session) {
  // 元素拿不到时（老适配器）退回 content；两条路都压成一行再截断。
  const raw = describeElements(session.elements) || textOf(session.content)
  const content = raw.replace(/\s+/g, ' ').trim()
  return {
    id: textOf(session.messageId ?? session.id),
    time: Number(session.timestamp) || Date.now(),
    platform: textOf(session.platform),
    selfId: textOf(session.selfId),
    userId: textOf(session.userId),
    channelId: textOf(session.channelId),
    guildId: session.guildId ? textOf(session.guildId) : null,
    content: content.length > TRAFFIC_MAX_CONTENT ? content.slice(0, TRAFFIC_MAX_CONTENT) : content
  }
}

export function apply(ctx) {
  const root = resolve(process.env.CHATLUNA_WORKSPACE ?? join(process.cwd(), 'data/chatluna/agents-work'))
  ctx.logger('media-bridge').info('serving workspace files from %s', root)

  // 指令在 `message` 事件之后才被匹配执行，所以这里能看到没进会话的那部分。
  const traffic = []
  ctx.on('message', (session) => {
    traffic.push(trafficEntry(session))
    if (traffic.length > TRAFFIC_CAPACITY) traffic.splice(0, traffic.length - TRAFFIC_CAPACITY)
  })

  const serve = async (relative, res) => {
    if (!relative) {
      res.status = 400
      res.body = 'missing path'
      return
    }
    const target = resolve(root, normalize(relative))
    if (target !== root && !target.startsWith(root + sep)) {
      res.status = 400
      res.body = 'path outside workspace'
      return
    }
    const info = await stat(target).catch(() => undefined)
    if (info === undefined || !info.isFile()) {
      res.status = 404
      res.body = 'file not found'
      return
    }
    res.status = 200
    res.headers.set('content-type', MIME[extname(target).toLowerCase()] ?? 'application/octet-stream')
    res.headers.set('cache-control', 'public, max-age=3600')
    res.body = await readFile(target)
  }

  const query = (req, key) => req.query?.get?.(key) ?? ''

  ctx.server.get('/api/workspace/:name', async (req, res) => {
    const raw = req.params?.name ?? ''
    let relative
    try {
      relative = decodeURIComponent(raw)
    } catch {
      relative = raw
    }
    return serve(relative, res)
  })

  // 路径参数里的 `/` 在部分路由实现下拿不到，查询参数作为稳定形态。
  ctx.server.get('/api/workspace', async (req, res) => {
    return serve(query(req, 'path'), res)
  })

  // 新 → 旧；`platform` / `channelId` 空串表示不过滤。
  ctx.server.get('/api/traffic', async (req, res) => {
    const limit = intParam(query(req, 'limit'), 50, 1, 200)
    const platform = query(req, 'platform').trim()
    const channelId = query(req, 'channelId').trim()
    const items = []
    for (let index = traffic.length - 1; index >= 0 && items.length < limit; index--) {
      const entry = traffic[index]
      if (platform && entry.platform !== platform) continue
      if (channelId && entry.channelId !== channelId) continue
      items.push(entry)
    }
    res.status = 200
    res.headers.set('content-type', 'application/json; charset=utf-8')
    res.headers.set('cache-control', 'no-store')
    res.body = JSON.stringify({ items })
  })
}
