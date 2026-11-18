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
import { fileURLToPath } from 'node:url'
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

// 一条消息最多带 8 个媒体：再多的图片/语音客户端也不会在一屏里渲染完。
const MEDIA_LIMIT = 8
// `file://` / 裸文件 id 换可访问地址（`bot.internal.getFile`）的等待上限；拿不到就退回 `ref`。
const MEDIA_FETCH_TIMEOUT = 1200
// 换地址的结果（含失败）缓存 60s：同一条消息被重复上报时不再打平台接口。
const MEDIA_REF_TTL = 60_000

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
  voice: '[语音]',
  record: '[语音]',
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

// 平台偶尔把 UTF-8 字节按 latin1 解出，名称会出现 `Ã©` / `ðŸ` 这类乱码：按 latin1 还原
// 成字节再用 UTF-8 解一次。修完出现替换字符说明不是这种损坏，保留原值。
function fixEncoding(value) {
  const text = textOf(value)
  if (!text || !/[\u0080-\u00ff]/.test(text)) return text
  const repaired = Buffer.from(text, 'latin1').toString('utf8')
  return repaired.includes('\uFFFD') ? text : repaired
}

// 名称专用：latin1 修复后仍有坏片段时，删掉带控制字符或 Latin 扩展字符的 `<...>`
// （QQ 群名里出现过 `<$ǿĀD\u000e>` 这种前缀），其余零散控制字符压成空格。
function cleanName(value) {
  let name = fixEncoding(value)
  if (!name) return ''
  name = name.replace(/<[^<>]*>/g, (segment) =>
    /[\u0000-\u001f\u007f-\u009f\u0080-\u024f]/.test(segment) ? '' : segment
  )
  name = name.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ')
  return name.replace(/\s+/g, ' ').trim()
}

// `rest` 是标签名之后的原始属性串；QQ 的附件标记用逗号分隔属性，且允许无引号，
// 所以不能按标准 HTML 解析，只按 `key=value` 抓值。
function attrOf(rest, name) {
  const matched = rest.match(new RegExp(
    `(?:^|[\\s,])${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s,>]+))`,
    'i'
  ))
  return matched ? matched[1] ?? matched[2] ?? matched[3] ?? '' : ''
}

// `<attachmentType="image/jpeg",...>` / `<attachment type="file">` 这类标记只带 MIME，
// 按类型翻成可读占位符。
function attachmentLabel(rest) {
  const type = (
    attrOf(rest, 'type') ||
    attrOf(rest, 'contentType') ||
    attrOf(rest, 'content_type') ||
    attrOf(rest, 'mimeType') ||
    attrOf(rest, 'mime_type') ||
    rest
  ).toLowerCase()
  if (type.includes('image')) return '[图片]'
  if (type.includes('video')) return '[视频]'
  if (type.includes('audio') || type.includes('voice') || type.includes('record')) return '[语音]'
  if (type.includes('file')) return '[文件]'
  return '[附件]'
}

// 原始 platform content 里残留的 Satori/QQ 标记：认识的映射，不认识的剥掉。
// 只匹配 `<字母` 或 `</字母` 形式，普通文本里的 `<` 不会误伤。
function stripRawTags(text) {
  if (!text.includes('<')) return text
  return text.replace(/<(\/?)([a-zA-Z][\w:-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/g, (_, closing, rawTag, rest) => {
    if (closing) return ''
    const tag = rawTag.toLowerCase()
    if (tag === 'at') {
      const name = attrOf(rest, 'name')
      const id = attrOf(rest, 'id')
      return '@' + (name || id.slice(-4))
    }
    if (tag.startsWith('attachment')) return attachmentLabel(rest)
    return ELEMENT_LABELS[tag] ?? ''
  })
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
    } else if (type === 'attachment') {
      text += attachmentLabel(
        [
          textOf(element.attrs?.type),
          textOf(element.attrs?.contentType ?? element.attrs?.content_type),
          textOf(element.attrs?.mimeType ?? element.attrs?.mime_type),
          textOf(element.attrs?.filename)
        ].join(' ')
      )
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

// 元素拿不到时（老适配器）退回 content；两条路都先归一残留标记，再压成一行。
function normalizeContent(elements, fallback) {
  return stripRawTags(describeElements(elements) || textOf(fallback)).replace(/\s+/g, ' ').trim()
}

// ── 媒体 ───────────────────────────────────────────────────────────────
// `content` 只保留可读占位（`[图片]`）；能渲染的东西另放 `media`，客户端据此画
// 缩略图/播放器。取不到可访问地址时给 `ref`，客户端退回占位。
const IMAGE_ELEMENTS = new Set(['img', 'image', 'mface', 'sticker'])
const VIDEO_ELEMENTS = new Set(['video'])
const AUDIO_ELEMENTS = new Set(['audio', 'voice', 'record'])

// 元素类型/附件 MIME → `media.kind`。QQ 附件把 `voice`/`file` 直接写在 content_type 里。
// MIME 比标签名更具体：`<file type="image/png">` 是图片，客户端可以按 image 渲染。
function mediaKind(type, mime) {
  const tag = textOf(type).toLowerCase()
  const value = textOf(mime).toLowerCase()
  if (IMAGE_ELEMENTS.has(tag) || value.startsWith('image/')) return 'image'
  if (VIDEO_ELEMENTS.has(tag) || value.startsWith('video/')) return 'video'
  if (AUDIO_ELEMENTS.has(tag) || value === 'voice' || value.startsWith('audio/')) return 'audio'
  if (tag === 'file' || value === 'file' || value) return 'file'
  if (tag.startsWith('attachment')) return 'file'
  return ''
}

// 序列化元素（`session.content`）里的属性是 HTML 转义的：`&amp;` 会让 QQ 附件的
// `fileid` 断掉，也让同一条消息的元素/标记串两条来源去重失败。
const HTML_ENTITIES = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'", '&apos;': "'" }

function unescapeAttr(value) {
  return value.replace(/&(?:amp|lt|gt|quot|#39|apos);/g, (entity) => HTML_ENTITIES[entity] ?? entity)
}

// 能直接交给客户端的值：`https://`、`//host/path`（QQ 附件常见）、`base64://`、
// `data:`。其余（`file://`、裸文件 id）交给 resolveReference 换地址。
function normalizeMediaUrl(value) {
  const raw = unescapeAttr(textOf(value).trim())
  if (!raw) return ''
  if (/^https?:\/\//i.test(raw)) return raw
  if (raw.startsWith('//')) return 'https:' + raw
  if (/^(base64:|data:)/i.test(raw)) return raw
  if (/^[\w-]+(\.[\w-]+)+\//.test(raw)) return 'https://' + raw
  return ''
}

// 工作区相对路径（`medialuna/angela_cloak.png`）：客户端本来就按这个形态走
// `/api/workspace`，可以直接当 `url` 用。
function isWorkspacePath(value) {
  const raw = textOf(value)
  return /^[\w.-]+(\/[\w.\- ]+)+$/.test(raw) && /\.[a-z0-9]{2,5}$/i.test(raw)
}

// 没有 mime 的 base64 载荷补成 `data:` URI；客户端只认 `data:` / `base64://` / URL。
function isBase64Payload(value) {
  const raw = textOf(value).replace(/\s+/g, '')
  return raw.length >= 64 && /^[A-Za-z0-9+/=]+$/.test(raw)
}

// `<attachmentType="image/jpeg",...>`：标记名后紧跟的值就是 MIME，`attrOf` 只认
// `key=value`，所以单独取一次。
function leadingAttrValue(rest) {
  const matched = rest.match(/^\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,>]+))/)
  return matched ? matched[1] ?? matched[2] ?? matched[3] ?? '' : ''
}

// 原始标记串里的媒体：`<img src=.../>`、`<attachment url=.../>`、`<file .../>`、
// `<attachmentType="image/jpeg",url=...>`（QQ 附件标记，逗号分隔属性）。
function rawMediaTags(text) {
  const found = []
  if (typeof text !== 'string' || !text.includes('<')) return found
  const pattern = /<(\/?)([a-zA-Z][\w:-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/g
  for (const match of text.matchAll(pattern)) {
    if (match[1]) continue
    const tag = match[2].toLowerCase()
    const rest = match[3]
    const attachment = tag.startsWith('attachment')
    const mime = attrOf(rest, 'mediaType') ||
      attrOf(rest, 'mimeType') ||
      attrOf(rest, 'contentType') ||
      attrOf(rest, 'content_type') ||
      attrOf(rest, 'type') ||
      (attachment ? leadingAttrValue(rest) : '')
    const kind = mediaKind(attachment ? 'attachment' : tag, mime)
    if (!kind) continue
    found.push({
      kind,
      mime,
      source: attrOf(rest, 'src') ||
        attrOf(rest, 'url') ||
        attrOf(rest, 'file') ||
        attrOf(rest, 'fileId') ||
        attrOf(rest, 'file_id') ||
        attrOf(rest, 'reference'),
      name: attrOf(rest, 'filename') || attrOf(rest, 'name') || attrOf(rest, 'title'),
      size: attrOf(rest, 'size')
    })
  }
  return found
}

// 一个 Satori 元素 → 媒体候选。`src` 是标准字段，`url` 是部分适配器的写法；
// ChatLuna 的 `file` 块把载荷放在 `data`（`{type:'url'|'data'|'reference', ...}`）。
function elementMedia(element) {
  const type = textOf(element?.type).toLowerCase()
  const attrs = element?.attrs ?? {}
  const mime = textOf(
    attrs.mediaType ?? attrs.mimeType ?? attrs.mime_type ??
    attrs.contentType ?? attrs.content_type ?? attrs.type
  )
  const kind = mediaKind(type, mime)
  if (!kind) return null
  const block = attrs.data && typeof attrs.data === 'object' ? attrs.data : null
  const source = textOf(attrs.src) ||
    textOf(attrs.url) ||
    textOf(typeof attrs.data === 'string' ? attrs.data : '') ||
    textOf(block?.url) ||
    textOf(block?.reference) ||
    textOf(block?.data) ||
    textOf(attrs.reference) ||
    textOf(attrs.fileId ?? attrs.file_id) ||
    textOf(attrs.id)
  return {
    kind,
    mime,
    source,
    name: textOf(attrs.filename ?? attrs.name ?? attrs.title),
    size: attrs.size
  }
}

// `getFile` 这类接口的返回形状各适配器不同：字符串、`{url}`、`{data:{url}}` 都见过。
function urlOfFileResult(result) {
  if (!result) return ''
  if (typeof result === 'string') return normalizeMediaUrl(result)
  for (const candidate of [
    result.url,
    result.src,
    result.data?.url,
    result.data?.src,
    result.file?.url
  ]) {
    const url = normalizeMediaUrl(candidate)
    if (url) return url
  }
  return ''
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

// 服务端拿不到群名/昵称时，尾 6 位是唯一能区分会话的信息。
function tailOf(value, length) {
  const text = textOf(value)
  return text.length <= length ? text : text.slice(-length)
}

function conversationTitle(kind, channelId, key, name) {
  const clean = cleanName(name)
  if (clean) return clean
  const source = channelId || key
  return (kind === 'group' ? '群聊 · ' : '私聊 · ') + tailOf(source, 6)
}

// `<at>` 等场景的短 id；没有 id 时返回空串。
function shortId(value) {
  return tailOf(value, 4)
}

function messageEntry(session, dir = 'in') {
  return {
    id: textOf(session.messageId ?? session.id),
    dir,
    time: Number(session.timestamp) || Date.now(),
    platform: textOf(session.platform),
    selfId: textOf(session.selfId),
    userId: textOf(session.userId),
    userName: '',
    avatar: null,
    channelId: textOf(session.channelId),
    guildId: session.guildId ? textOf(session.guildId) : null,
    // 由 resolveIdentity 填充；record 只认非空值，避免出站消息覆盖已有群名/昵称。
    conversationName: '',
    conversationAvatar: null,
    content: clipContent(normalizeContent(session.elements, session.content)),
    // 由 collectMedia 填充：可渲染的图片/视频/语音/文件，`content` 里只有占位。
    media: []
  }
}

function publicMessage(message) {
  return {
    id: message.id,
    time: message.time,
    dir: message.dir,
    userId: message.userId,
    userName: message.userName,
    avatar: message.avatar,
    content: message.content,
    media: message.media ?? []
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

  // 名称/头像缓存：`g:<platform>\0<guildId>` / `u:<platform>\0<userId>` → {name, avatar}。
  // 事件里带名字就直接记下来（零开销）；缺失时才问 bot，一次查询的结果后续消息复用。
  const profileCache = new Map()
  const profilePending = new Map()
  const PROFILE_TIMEOUT = 1200

  const withTimeout = (factory, ms) => new Promise((resolve) => {
    const timer = setTimeout(() => resolve(null), ms)
    Promise.resolve().then(factory).then(
      (value) => { clearTimeout(timer); resolve(value) },
      () => { clearTimeout(timer); resolve(null) }
    )
  })

  // `requireAvatar` 给群头像用：入站事件的 `guild` 通常只有名字、没有头像，必须再问一次
  // `bot.getGuild`。查到（或查明没有）就记进缓存，之后同一群的消息不再重复请求；
  // 失败一律 `null`，**不回退 bot 自己头像**（群会话顶着 bot 头像比空着更误导）。
  const resolveProfile = async (scope, platform, id, seed, fetcher, { requireAvatar = false } = {}) => {
    if (!id) return null
    const cacheKey = scope + ':' + platform + '\u0000' + id
    const cached = profileCache.get(cacheKey)
    const seedName = cleanName(seed?.name)
    const seedAvatar = textOf(seed?.avatar) || null
    const known = {
      name: seedName || cached?.name || '',
      avatar: seedAvatar || cached?.avatar || null,
      fetched: cached?.fetched === true
    }
    // 事件里已经给全了（名字齐全；要求头像时还要有头像）就不用问 bot。
    if (known.fetched || (known.name && (!requireAvatar || known.avatar))) {
      profileCache.set(cacheKey, known)
      return known
    }
    const pending = profilePending.get(cacheKey)
    if (pending) return pending
    const promise = (async () => {
      let value
      try {
        const profile = await withTimeout(fetcher, PROFILE_TIMEOUT)
        value = {
          name: known.name || cleanName(profile?.name) || cleanName(profile?.nick) || '',
          avatar: known.avatar || textOf(profile?.avatar) || null,
          fetched: true
        }
      } catch {
        value = { ...known, fetched: true }
      } finally {
        profilePending.delete(cacheKey)
      }
      // `fetched` 连同空结果一起缓存：查不到的群不会每条消息都再打一次接口。
      profileCache.set(cacheKey, value)
      return value
    })()
    profilePending.set(cacheKey, promise)
    return promise
  }

  // 入站消息的显示名/头像：群昵称（member.name/nick）优先，其次全局昵称；
  // 群会话标题取群名，私聊标题取对方昵称。事件里没有才走 bot.getGuild / bot.getUser。
  const resolveIdentity = async (session, entry) => {
    const event = session.event ?? {}
    const member = event.member
    const user = event.user ?? member?.user
    const guild = event.guild
    const channel = event.channel
    const platform = entry.platform
    const kind = conversationKind(entry.guildId, entry.channelId)

    const sender = await resolveProfile(
      'u',
      platform,
      entry.userId,
      {
        name: textOf(member?.name) || textOf(member?.nick) || textOf(user?.name) || textOf(user?.nick),
        avatar: textOf(member?.avatar) || textOf(user?.avatar) || null
      },
      () => session.bot?.getUser?.(entry.userId, entry.guildId || undefined)
    )
    entry.userName = sender?.name || shortId(entry.userId)
    entry.avatar = sender?.avatar ?? null

    if (kind === 'group') {
      const profile = await resolveProfile(
        'g',
        platform,
        entry.guildId,
        { name: textOf(guild?.name), avatar: textOf(guild?.avatar) },
        () => session.bot?.getGuild?.(entry.guildId),
        { requireAvatar: true }
      )
      entry.conversationName = profile?.name || cleanName(channel?.name) || ''
      entry.conversationAvatar = profile?.avatar ?? null
    } else {
      entry.conversationName = sender?.name || cleanName(channel?.name) || ''
      entry.conversationAvatar = sender?.avatar ?? null
    }
  }

  // ── 媒体 ─────────────────────────────────────────────────────────────
  // 换地址的结果（含失败）短期缓存：同一条消息被重复上报、或同一文件被多次引用时不再打接口。
  const mediaRefCache = new Map()
  // 单条消息换地址的总预算：拿不到就退回 `ref`，不让入站事件被慢接口拖住。
  const MEDIA_RESOLVE_BUDGET = 3000

  // `file://` 落在工作区里时直接换成 `/api/workspace` 能取的相对路径，客户端本来就认这个形态。
  const workspaceRelativeOf = (value) => {
    const raw = textOf(value)
    if (!/^file:\/\//i.test(raw)) return ''
    let path
    try {
      path = fileURLToPath(raw)
    } catch {
      return ''
    }
    const target = resolve(path)
    if (target === root || !target.startsWith(root + sep)) return ''
    return target.slice(root.length + 1).split(sep).join('/')
  }

  // `file://` 或裸文件 id → 平台可访问 URL。适配器各写各的：`bot.internal.getFile`
  // （onebot 系）最常用，其次 `bot.getFile`，再 `internal.getFileUrl`；都拿不到返回空串。
  const resolveReference = async (bot, reference) => {
    const cached = mediaRefCache.get(reference)
    if (cached && Date.now() - cached.at < MEDIA_REF_TTL) return cached.url
    const internal = bot?.internal
    const attempts = [
      () => internal?.getFile?.(reference),
      () => bot?.getFile?.(reference),
      () => internal?.getFileUrl?.(reference)
    ]
    let url = ''
    for (const attempt of attempts) {
      const result = await withTimeout(attempt, MEDIA_FETCH_TIMEOUT)
      url = urlOfFileResult(result)
      if (url) break
    }
    if (mediaRefCache.size > 64) mediaRefCache.clear()
    mediaRefCache.set(reference, { url, at: Date.now() })
    return url
  }

  // 入站/出站统一入口：元素优先，其次 `event.message` 的原始附件与标记串，
  // 最后退回 `content`（老适配器只给序列化文本）。同一个 URL 只留一条。
  const collectMedia = async (source) => {
    const bot = source?.bot
    const items = []
    const seen = new Set()
    const deadline = Date.now() + MEDIA_RESOLVE_BUDGET

    const add = async (descriptor) => {
      if (!descriptor || items.length >= MEDIA_LIMIT) return
      const raw = unescapeAttr(textOf(descriptor.source).trim())
      const mime = textOf(descriptor.mime).trim()
      const name = cleanName(descriptor.name)
      const size = Number(descriptor.size) > 0 ? Number(descriptor.size) : undefined

      let url = ''
      let ref = ''
      if (raw) {
        const local = workspaceRelativeOf(raw)
        if (local) url = local
        else url = normalizeMediaUrl(raw)
        if (!url && isWorkspacePath(raw)) url = raw
        if (!url && mime && isBase64Payload(raw)) url = `data:${mime};base64,${raw}`
        if (!url && Date.now() < deadline) {
          url = await resolveReference(bot, raw)
        }
        // 换不到地址就原样留 ref：客户端据此显示占位/重试，不会误以为是 URL。
        if (!url) ref = raw
      }
      const identity = url || ref
      if (!identity || seen.has(identity)) return
      seen.add(identity)

      const item = { kind: descriptor.kind }
      if (url) item.url = url
      if (ref) item.ref = ref
      if (name) item.name = name
      if (mime) item.mime = mime
      if (size) item.size = size
      items.push(item)
    }

    for (const element of Array.isArray(source?.elements) ? source.elements : []) {
      await add(elementMedia(element))
    }
    const eventMessage = source?.event
    if (eventMessage && typeof eventMessage === 'object') {
      for (const element of Array.isArray(eventMessage.elements) ? eventMessage.elements : []) {
        await add(elementMedia(element))
      }
      for (const attachment of Array.isArray(eventMessage.attachments) ? eventMessage.attachments : []) {
        const mime = textOf(attachment?.content_type ?? attachment?.contentType)
        await add({
          kind: mediaKind('attachment', mime),
          source: textOf(attachment?.url ?? attachment?.src),
          mime,
          name: textOf(attachment?.filename),
          size: attachment?.size
        })
      }
      for (const descriptor of rawMediaTags(textOf(eventMessage.content))) await add(descriptor)
    }
    for (const descriptor of rawMediaTags(textOf(source?.content))) await add(descriptor)
    return items
  }

  // 消息里所有能换地址的地方：`session.elements`、`session.content` 与事件原始消息。
  // 出站只能在 `before-send` 抓到这份快照（`send` 的 session 没有 elements）。
  const mediaSnapshot = (session) => ({
    bot: session.bot,
    elements: session.elements,
    content: session.content,
    event: session.event?.message
  })

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
        name: '',
        nameKind: 'private',
        title: '',
        avatar: null,
        messages: []
      }
    }

    // 后到的消息可能补全频道元信息（出站 session 的 guildId / channelId 可能为空）。
    conversation.platform = textOf(entry.platform) || conversation.platform
    conversation.selfId = textOf(entry.selfId) || conversation.selfId
    conversation.channelId = channelId || conversation.channelId
    if (guildId) conversation.guildId = guildId
    conversation.kind = conversationKind(conversation.guildId, conversation.channelId)
    // 群名/对方昵称只在入站解析出来时写入，且不能跨 kind 复用（私聊昵称不会变成群名）。
    if (conversation.nameKind !== conversation.kind) {
      conversation.name = ''
      conversation.nameKind = conversation.kind
    }
    if (entry.conversationName) conversation.name = textOf(entry.conversationName)
    if (entry.conversationAvatar) conversation.avatar = textOf(entry.conversationAvatar)
    conversation.title = conversationTitle(conversation.kind, conversation.channelId, key, conversation.name)
    conversations.set(key, conversation)

    const messages = conversation.messages
    const last = messages[messages.length - 1]
    if (last && last.time === time) return null

    const message = {
      id: textOf(entry.id),
      time,
      dir: entry.dir === 'out' ? 'out' : 'in',
      userId: textOf(entry.userId),
      userName: textOf(entry.userName),
      avatar: entry.avatar ? textOf(entry.avatar) : null,
      content: textOf(entry.content),
      media: Array.isArray(entry.media) ? entry.media : []
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
  ctx.on('message', async (session) => {
    const key = conversationKeyOf(session)
    if (!key) return
    const entry = messageEntry(session, 'in')
    await resolveIdentity(session, entry)
    entry.media = await collectMedia(mediaSnapshot(session))
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
      // `send` 的 session 没有 elements，媒体也只能在这一刻抓。
      media: mediaSnapshot(session),
      conversationKey: conversationKeyOf(session),
      time: Date.now()
    })
    pruneOutbound()
  })

  ctx.on('send', async (session) => {
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
    entry.media = await collectMedia(slot.media)
    // 出站消息的作者是 bot 自己：`send` 的 session 是新造的，没有 user。
    if (!entry.userId) entry.userId = entry.selfId
    const botUser = session.bot?.user
    entry.userName = cleanName(botUser?.name) || entry.selfId
    entry.avatar = textOf(botUser?.avatar) || null
    // 主动推送时可能没有入站消息打过底，这里顺手用 send 事件自带的 guild 补群名。
    const eventGuild = session.event?.guild
    if (conversationKind(entry.guildId, entry.channelId) === 'group' && eventGuild?.name) {
      entry.conversationName = cleanName(eventGuild.name)
      entry.conversationAvatar = textOf(eventGuild.avatar) || null
    }
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
        avatar: conversation.avatar,
        count: conversation.messages.length,
        last: last
          ? {
              id: last.id,
              time: last.time,
              dir: last.dir,
              userId: last.userId,
              userName: last.userName,
              avatar: last.avatar,
              text: last.content
            }
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
