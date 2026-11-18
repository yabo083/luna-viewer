// chatluna-plugin-media-bridge
// 把 agent 工作区（data/chatluna/agents-work）里的文件通过 Bearer 保护的
// GET /api/workspace?path=<相对路径> 暴露给客户端（移动端渲染消息里的图片）。
// 只读；路径必须落在工作区内。后续版本会在这里加：上传、临时签名、缩略图。
//
// 另外提供 GET /api/traffic 与 GET /api/traffic/stream：入站 + 出站消息的旁路记录。
// 纯指令消息（如 `chatluna-菜单`）在 Koishi 的指令层就被消费掉了，既不落会话日志也不加载
// agent；bot 借框架之口发出的回复（`session.send`）同样只进平台、不进 agent 日志。客户端
// 两边都看不到，所以这里在事件层抄一份环形缓冲（`dir` 区分方向），让 App 的「消息记录」页
// 能看见它们，并通过 SSE 实时推送。
import { readFile, stat } from 'node:fs/promises'
import { extname, join, normalize, resolve, sep } from 'node:path'
import { openStream } from '@chatluna/server'

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
// 新连接先补最近 20 条，够 App 开局把「刚发的指令」补上；更早的走 /api/traffic 翻。
const TRAFFIC_STREAM_HISTORY = 20

// 出站：`before-send` 到适配器真正 `send` 之间只隔一次渲染/一次 HTTP，2s 足够覆盖排队与重试；
// 超过这个窗口的快照不再属于本次 send，宁可略过也不写错正文。
const OUTBOUND_SLOT_TTL = 2000
// 同一条出站消息可能被多个 bot 实例/适配器各上报一次（一次回复也可能被拆成多段 flush），
// 所以「同一个频道 + 同样的正文」在 500ms 内只记一条。
const OUTBOUND_DEDUPE_MS = 500

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

function clipContent(text) {
  return text.length > TRAFFIC_MAX_CONTENT ? text.slice(0, TRAFFIC_MAX_CONTENT) : text
}

// 元素拿不到时（老适配器）退回 content；两条路都压成一行。
function normalizeContent(elements, fallback) {
  return (describeElements(elements) || textOf(fallback)).replace(/\s+/g, ' ').trim()
}

// 标题里的 id（`A1338876…`）是 ChatLuna 会话 id，traffic 里的 `channelId`/`guildId` 是适配器
// 的 `C…`，两者不同命名空间，靠标题 id 匹配群会话必然失败。`conversationKey` / `routeId`
// 才是同一套标识，客户端用它们精确匹配。
function conversationKeyOf(session) {
  // `.conversation` 由 chat 插件惰性挂在 Session 原型上（依赖 routing 服务）；取不到或抛错时
  // 退回 channelId，客户端就要退回标题 id 匹配。
  try {
    const key = session.conversation?.key
    if (key) return textOf(key)
  } catch {}
  return textOf(session.channelId) || null
}

function trafficEntry(session, dir = 'in') {
  const entry = {
    id: textOf(session.messageId ?? session.id),
    dir,
    time: Number(session.timestamp) || Date.now(),
    platform: textOf(session.platform),
    selfId: textOf(session.selfId),
    userId: textOf(session.userId),
    channelId: textOf(session.channelId),
    guildId: session.guildId ? textOf(session.guildId) : null,
    content: clipContent(normalizeContent(session.elements, session.content)),
    conversationKey: conversationKeyOf(session)
  }
  // `routeId` 由 @chatluna/satori 惰性提供；没有这个字段的运行环境不写键，保持条目形状兼容。
  const routeId = session.routeId
  if (routeId) entry.routeId = textOf(routeId)
  return entry
}

export function apply(ctx) {
  const root = resolve(process.env.CHATLUNA_WORKSPACE ?? join(process.cwd(), 'data/chatluna/agents-work'))
  ctx.logger('media-bridge').info('serving workspace files from %s', root)

  // 指令在 `message` 事件之后才被匹配执行，所以这里能看到没进会话的那部分。
  const traffic = []
  // 在线 SSE 订阅者；连接关闭时自己摘除，插件卸载时统一收尾，避免计时器/写句柄泄漏。
  const subscribers = new Set()
  ctx.on('dispose', () => {
    for (const stream of subscribers) stream.close()
    subscribers.clear()
  })

  const pushTraffic = (entry) => {
    traffic.push(entry)
    if (traffic.length > TRAFFIC_CAPACITY) traffic.splice(0, traffic.length - TRAFFIC_CAPACITY)
    // 推送失败（背压/已断开）不影响缓冲：客户端重连时靠历史帧补齐。
    for (const stream of subscribers) stream.send({ event: 'traffic', data: entry })
  }

  ctx.on('message', (session) => pushTraffic(trafficEntry(session, 'in')))

  // 出站分两步，因为两个事件各缺一半信息：
  // - `before-send`（MessageEncoder 渲染前）拿得到正文（`session.elements`）与 `session.conversation`；
  // - `send`（适配器真正落库之后）带得到平台消息 id，但适配器传进来的是新造的 `bot.session()`，
  //   没有 elements（QQ 适配器 flush 里 decodeMessage 那一行仍是注释掉的）。
  // 于是 `before-send` 只记「这个频道最近要发什么」，`send` 才落一条 `dir: 'out'` 的条目。
  const outboundSlots = new Map()
  const outboundSeen = new Map()
  let outboundSeq = 0

  const pruneOutbound = () => {
    const now = Date.now()
    if (outboundSlots.size > 128) {
      for (const [key, slot] of outboundSlots) {
        if (now - slot.time > OUTBOUND_SLOT_TTL) outboundSlots.delete(key)
      }
    }
    if (outboundSeen.size > 64) {
      for (const [key, at] of outboundSeen) {
        if (now - at > OUTBOUND_DEDUPE_MS) outboundSeen.delete(key)
      }
    }
  }

  ctx.on('before-send', (session) => {
    outboundSlots.set(textOf(session.channelId), {
      content: normalizeContent(session.elements, session.content),
      conversationKey: conversationKeyOf(session),
      time: Date.now()
    })
    pruneOutbound()
  })

  // `send` 的 session 是 `bot.session()` 新造的：`isDirect` 这类挂在 Session 原型上的访问器
  // 没被复制过去，私聊就会被算成「频道」路由（少了 `:user:`），与会话说到底不是同一个键。
  // 回复总是发回它来的那个频道，所以优先沿用这个频道最近一条入站消息的会话键/路由。
  const recentInboundOf = (platform, channelId) => {
    for (let index = traffic.length - 1; index >= 0; index--) {
      const item = traffic[index]
      if (item.dir !== 'in') continue
      if (item.platform !== platform || item.channelId !== channelId) continue
      return item
    }
    return undefined
  }

  ctx.on('send', (session) => {
    const channelId = textOf(session.channelId)
    const now = Date.now()
    const slot = outboundSlots.get(channelId)
    // 快照过期/不存在说明这条 send 不是本进程刚排队的那一次（例如别处直接调 bot.internal），
    // 正文不可知；写一条空正文只会污染「消息记录」。
    if (!slot || now - slot.time > OUTBOUND_SLOT_TTL || !slot.content) return
    // 去重键不含 selfId：同一条出站可能被多个 bot 实例/适配器各上报一次。
    const key = channelId + '\u0000' + slot.content
    const seenAt = outboundSeen.get(key)
    if (seenAt !== undefined && now - seenAt <= OUTBOUND_DEDUPE_MS) return
    outboundSeen.set(key, now)
    pruneOutbound()

    const entry = trafficEntry(session, 'out')
    entry.content = clipContent(slot.content)
    const inbound = recentInboundOf(entry.platform, entry.channelId)
    if (inbound?.conversationKey) {
      entry.conversationKey = inbound.conversationKey
      if (inbound.routeId) entry.routeId = inbound.routeId
      else delete entry.routeId
    } else {
      entry.conversationKey = slot.conversationKey
    }
    // 出站消息的作者是 bot 自己：`send` 的 session 是新造的，没有 user。
    if (!entry.userId) entry.userId = entry.selfId
    // 平台回了消息 id 就用它；否则退回本地键——客户端按 id 去重（SSE 历史重放 + 轮询会
    // 重复拿到同一批），空 id 会让同一条消息反复出现。`trafficEntry` 里的 `session.id`
    // 是进程内自增的 session 序号，不是平台消息 id，不能当条目 id。
    const messageId = textOf(session.messageId)
    entry.id = messageId || `out-${entry.selfId}:${now}:${++outboundSeq}`
    pushTraffic(entry)
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

  // SSE：先补最多 20 条历史（旧 → 新，客户端可顺序追加），之后每条入站/出站消息一帧。
  // openStream 负责 text/event-stream 头、flushHeaders、15s `: ping` 心跳与断开清理。
  ctx.server.get('/api/traffic/stream', async (req, res) => {
    const stream = openStream(ctx, res)
    subscribers.add(stream)
    stream.onClose(() => subscribers.delete(stream))
    for (const entry of traffic.slice(-TRAFFIC_STREAM_HISTORY)) {
      stream.send({ event: 'traffic', data: entry })
    }
  })
}
