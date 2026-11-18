// chatluna-plugin-media-bridge
// 把 agent 工作区（data/chatluna/agents-work）里的文件通过 Bearer 保护的
// GET /api/workspace?path=<相对路径> 暴露给客户端（移动端渲染消息里的图片）。
// 只读；路径必须落在工作区内。
//
// 同时是本实例的平台消息真源：在事件层按会话记录入站 + 出站消息，App 只消费
// /api/platform/* 三件套（会话列表、消息分页、实时流），不再自己拿会话日志和旁路
// 流量拼消息。指令回复这类「只到平台、不进 agent 日志」的消息同样在这里落一份。
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

// 每个会话独立环形缓冲：300 条足够 App 翻最近几屏；会话表 200 个，淘汰最久未活跃的。
// 全部只在内存里，实例重启即清空（App 重连后从新消息重新积累）。
const MESSAGE_CAPACITY = 300
const CONVERSATION_CAPACITY = 200
const MESSAGE_MAX_CONTENT = 500
// 新连接先回放每个会话最近 5 条，够 App 把当前屏幕接上；更早的走分页接口。
const STREAM_REPLAY = 5

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
  return text.length > MESSAGE_MAX_CONTENT ? text.slice(0, MESSAGE_MAX_CONTENT) : text
}

// 元素拿不到时（老适配器）退回 content；两条路都压成一行。
function normalizeContent(elements, fallback) {
  return (describeElements(elements) || textOf(fallback)).replace(/\s+/g, ' ').trim()
}

// 标题里的 id（`A1338876…`）是 ChatLuna 会话 id，平台侧的 `channelId`/`guildId` 是适配器
// 的 `C…`，两者不同命名空间，靠标题 id 匹配群会话必然失败。`session.conversation.key`
// 才是 App 会话 id 同一套标识，归一键直接复用它。
function conversationKeyOf(session) {
  // `.conversation` 由 chat 插件惰性挂在 Session 原型上（依赖 routing 服务）；取不到或抛错时
  // 退回 channelId。
  try {
    const key = session.conversation?.key
    if (key) return textOf(key)
  } catch {}
  return textOf(session.channelId) || null
}

// 群消息的 `guildId` 与 `channelId` 相同，私聊没有 `guildId`（与 App 现有判断一致）。
function conversationKind(guildId, channelId) {
  return guildId && guildId === channelId ? 'group' : 'private'
}

// 服务端拿不到群名，尾 6 位是唯一能区分会话的信息。
function conversationTitle(kind, channelId, key) {
  const source = channelId || key
  const tail = source.length <= 6 ? source : source.slice(-6)
  return (kind === 'group' ? '群聊 · ' : '私聊 · ') + tail
}

function messageEntry(session, dir = 'in') {
  return {
    id: textOf(session.messageId ?? session.id),
    dir,
    time: Number(session.timestamp) || Date.now(),
    platform: textOf(session.platform),
    selfId: textOf(session.selfId),
    userId: textOf(session.userId),
    channelId: textOf(session.channelId),
    guildId: session.guildId ? textOf(session.guildId) : null,
    content: clipContent(normalizeContent(session.elements, session.content))
  }
}

function publicMessage(message) {
  return {
    id: message.id,
    time: message.time,
    dir: message.dir,
    userId: message.userId,
    content: message.content
  }
}

export function apply(ctx) {
  const root = resolve(process.env.CHATLUNA_WORKSPACE ?? join(process.cwd(), 'data/chatluna/agents-work'))
  ctx.logger('media-bridge').info('serving workspace files from %s', root)

  // 会话表：插入顺序即最近活跃顺序；每条消息按 time 去重、升序保存在 messages 里。
  const conversations = new Map()
  // 在线 SSE 订阅者；连接关闭时自己摘除，插件卸载时统一收尾，避免计时器/写句柄泄漏。
  const subscribers = new Set()
  ctx.on('dispose', () => {
    for (const stream of subscribers) stream.close()
    subscribers.clear()
  })

  const notify = (key, message) => {
    // 推送失败（背压/已断开）不影响存储：客户端重连时靠回放补齐。
    for (const stream of subscribers) stream.send({ event: 'platform', data: { key, message } })
  }

  // 落一条消息；同一个会话、同一个 time 视为同一条（多 bot 实例/适配器重复上报）。
  // 返回真正入库的消息（重复则 null），调用方据此决定是否推实时帧。
  const record = (key, entry) => {
    const time = Number(entry.time) || Date.now()
    const channelId = textOf(entry.channelId)
    const guildId = entry.guildId ? textOf(entry.guildId) : null

    let conversation = conversations.get(key)
    if (conversation) {
      // 末尾即最新活跃；删了重插把这次活动挪到 LRU 尾部。
      conversations.delete(key)
    } else {
      conversation = {
        key,
        platform: '',
        selfId: '',
        channelId: '',
        guildId: null,
        kind: 'private',
        title: '',
        messages: []
      }
    }

    // 后到的消息可能补全频道元信息（出站 session 的 guildId / channelId 可能为空）。
    conversation.platform = textOf(entry.platform) || conversation.platform
    conversation.selfId = textOf(entry.selfId) || conversation.selfId
    conversation.channelId = channelId || conversation.channelId
    if (guildId) conversation.guildId = guildId
    conversation.kind = conversationKind(conversation.guildId, conversation.channelId)
    conversation.title = conversationTitle(conversation.kind, conversation.channelId, key)
    conversations.set(key, conversation)

    const messages = conversation.messages
    const last = messages[messages.length - 1]
    if (last && last.time === time) return null

    const message = {
      id: textOf(entry.id),
      time,
      dir: entry.dir === 'out' ? 'out' : 'in',
      userId: textOf(entry.userId),
      content: textOf(entry.content)
    }

    // 正常是追加；时间戳回退（适配器补发/重试）时插到正确位置，保持升序。
    if (last && time < last.time) {
      let index = messages.length - 1
      while (index >= 0 && messages[index].time > time) index--
      if (index >= 0 && messages[index].time === time) return null
      messages.splice(index + 1, 0, message)
    } else {
      messages.push(message)
    }
    if (messages.length > MESSAGE_CAPACITY) messages.splice(0, messages.length - MESSAGE_CAPACITY)

    // 会话表按「最后一条消息时间」淘汰，最久没消息的先走。
    if (conversations.size > CONVERSATION_CAPACITY) {
      let oldestKey = null
      let oldestTime = Infinity
      for (const [candidateKey, candidate] of conversations) {
        if (candidateKey === key) continue
        const tail = candidate.messages[candidate.messages.length - 1]
        const activeAt = tail ? tail.time : 0
        if (activeAt < oldestTime) {
          oldestTime = activeAt
          oldestKey = candidateKey
        }
      }
      if (oldestKey !== null) conversations.delete(oldestKey)
    }

    return message
  }

  // 频道 → 会话键。出站 `send` 的 session 是 `bot.session()` 新造的，`isDirect` 这类挂在
  // Session 原型上的访问器没被复制过去，私聊会被算成「频道」路由（少了 `:user:`）。
  // 回复总是发回它来的那个频道，所以优先沿用该频道最近一条入站消息的会话键。
  const inboundKeys = new Map()
  const rememberInboundKey = (entry, key) => {
    if (!entry.platform || !entry.channelId) return
    const channelKey = entry.platform + '\u0000' + entry.channelId
    inboundKeys.delete(channelKey)
    inboundKeys.set(channelKey, key)
    if (inboundKeys.size > CONVERSATION_CAPACITY) {
      const oldest = inboundKeys.keys().next().value
      if (oldest !== undefined) inboundKeys.delete(oldest)
    }
  }

  // 指令在 `message` 事件之后才被匹配执行，所以这里也能看到没进会话的那部分。
  ctx.on('message', (session) => {
    const key = conversationKeyOf(session)
    if (!key) return
    const entry = messageEntry(session, 'in')
    const message = record(key, entry)
    rememberInboundKey(entry, key)
    if (message) notify(key, message)
  })

  // 出站分两步，因为两个事件各缺一半信息：
  // - `before-send`（MessageEncoder 渲染前）拿得到正文（`session.elements`）与 `session.conversation`；
  // - `send`（适配器真正落库之后）带得到平台消息 id，但适配器传进来的是新造的 `bot.session()`，
  //   没有 elements。
  // 于是 `before-send` 只记「这个频道最近要发什么」，`send` 才落一条 `dir: 'out'` 的消息。
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

  ctx.on('send', (session) => {
    const channelId = textOf(session.channelId)
    const now = Date.now()
    const slot = outboundSlots.get(channelId)
    // 快照过期/不存在说明这条 send 不是本进程刚排队的那一次（例如别处直接调 bot.internal），
    // 正文不可知；写一条空正文只会污染消息列表。
    if (!slot || now - slot.time > OUTBOUND_SLOT_TTL || !slot.content) return
    // 去重键不含 selfId：同一条出站可能被多个 bot 实例/适配器各上报一次。
    const dedupeKey = channelId + '\u0000' + slot.content
    const seenAt = outboundSeen.get(dedupeKey)
    if (seenAt !== undefined && now - seenAt <= OUTBOUND_DEDUPE_MS) return
    outboundSeen.set(dedupeKey, now)
    pruneOutbound()

    const entry = messageEntry(session, 'out')
    entry.content = clipContent(slot.content)
    // 出站消息的作者是 bot 自己：`send` 的 session 是新造的，没有 user。
    if (!entry.userId) entry.userId = entry.selfId
    // 平台回了消息 id 就用它；否则退回本地键——客户端靠 id 去重，空 id 会让同一条消息反复出现。
    const messageId = textOf(session.messageId)
    entry.id = messageId || `out-${entry.selfId}:${now}:${++outboundSeq}`

    const inboundKey = inboundKeys.get(entry.platform + '\u0000' + entry.channelId)
    const key = inboundKey || slot.conversationKey || conversationKeyOf(session) || entry.channelId
    if (!key) return
    const message = record(key, entry)
    if (message) notify(key, message)
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

  const sendJson = (res, payload, status = 200) => {
    res.status = status
    res.headers.set('content-type', 'application/json; charset=utf-8')
    res.headers.set('cache-control', 'no-store')
    res.body = JSON.stringify(payload)
  }

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

  // 会话列表：按最后一条消息倒序；count 是当前环形缓冲里的条数（cap 300）。
  ctx.server.get('/api/platform/conversations', async (req, res) => {
    const items = []
    for (const conversation of conversations.values()) {
      const last = conversation.messages[conversation.messages.length - 1]
      items.push({
        key: conversation.key,
        platform: conversation.platform,
        selfId: conversation.selfId,
        channelId: conversation.channelId,
        guildId: conversation.guildId,
        kind: conversation.kind,
        title: conversation.title,
        count: conversation.messages.length,
        last: last
          ? { id: last.id, time: last.time, dir: last.dir, text: last.content }
          : null
      })
    }
    items.sort((a, b) => (b.last?.time ?? 0) - (a.last?.time ?? 0))
    sendJson(res, { items })
  })

  // 消息分页：时间升序（旧 → 新）；`before` 取更早一页，`hasMore` 表示还有更早的。
  ctx.server.get('/api/platform/messages', async (req, res) => {
    const key = query(req, 'key').trim()
    if (!key) return sendJson(res, { error: 'missing key' }, 400)
    const limit = intParam(query(req, 'limit'), 50, 1, 200)
    const before = Number.parseInt(query(req, 'before') ?? '', 10)

    const messages = conversations.get(key)?.messages ?? []
    // end 是开区间：满足 time < before 的最后一条之后。
    let end = messages.length
    if (Number.isSafeInteger(before)) {
      end = 0
      while (end < messages.length && messages[end].time < before) end++
    }
    const start = Math.max(0, end - limit)
    const items = messages.slice(start, end).map(publicMessage)
    sendJson(res, { items, hasMore: start > 0 })
  })

  // SSE：连上先按时间顺序回放每个会话最近 5 条，之后实时推。
  // openStream 负责 text/event-stream 头、flushHeaders、15s `: ping` 心跳与断开清理。
  // 帧格式：`event: platform`，`data` 为 `{key, message}`。
  ctx.server.get('/api/platform/stream', async (req, res) => {
    const stream = openStream(ctx, res)
    subscribers.add(stream)
    stream.onClose(() => subscribers.delete(stream))

    const replay = []
    for (const conversation of conversations.values()) {
      for (const message of conversation.messages.slice(-STREAM_REPLAY)) {
        replay.push({ key: conversation.key, message: publicMessage(message) })
      }
    }
    replay.sort((a, b) => a.message.time - b.message.time)
    for (const frame of replay) stream.send({ event: 'platform', data: frame })
  })
}
