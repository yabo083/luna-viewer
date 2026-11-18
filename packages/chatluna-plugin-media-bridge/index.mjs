// chatluna-plugin-media-bridge
// 把 agent 工作区（data/chatluna/agents-work）里的文件通过 Bearer 保护的
// GET /api/workspace?path=<相对路径> 暴露给客户端（移动端渲染消息里的图片）。
// 只读；路径必须落在工作区内。
//
// 同时是本实例的平台消息真源：App 只消费 /api/platform/* 三件套（会话列表、消息分页、
// 实时流）。消息有两个来源，按同一套 id/时间去重后合并成一条流：
//   1. ChatLuna 会话日志（`data/chatluna.db` 的 `chatluna_session_entry`）——进过 agent 的
//      普通消息，重启后仍在，是普通消息的真源；
//   2. 事件层捕获——指令回复、群聊里没 @bot 的消息等「不进日志」的消息，落盘保存增量。
import { mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from 'node:fs'
import { readdir, readFile, rename, stat, unlink, writeFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { dirname, extname, join, normalize, resolve, sep } from 'node:path'
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
  '.bmp': 'image/bmp',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.mov': 'video/quicktime',
  '.m4a': 'audio/mp4',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.ogg': 'audio/ogg',
  '.opus': 'audio/ogg',
  '.amr': 'audio/amr',
  '.silk': 'audio/silk',
  '.pdf': 'application/pdf',
  '.zip': 'application/zip',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/plain; charset=utf-8',
  '.json': 'application/json',
  '.bin': 'application/octet-stream'
}

// 每个会话独立环形缓冲：300 条足够 App 翻最近几屏；会话表 200 个，淘汰最久未活跃的。
const MESSAGE_CAPACITY = 300
const CONVERSATION_CAPACITY = 200
const MESSAGE_MAX_CONTENT = 500
// 新连接先回放每个会话最近 5 条，够 App 把当前屏幕接上；更早的走分页接口。
const STREAM_REPLAY = 5

// ── 会话日志投影 ────────────────────────────────────────────────────────
// 只读打开 ChatLuna 的 sqlite（Node 24 内置 node:sqlite）。会话按 lastActiveAt 取前 200 个、
// 每个读最近 300 条 message 条目；之后每 1.5s 按每会话游标补增量。
const LOG_POLL_MS = 1500
const LOG_SESSION_LIMIT = 200
const LOG_ENTRY_WINDOW = 300
// 首次全量按批跑（setImmediate），单批 4 个会话，避免启动时长时间占住事件循环。
const LOG_FULL_LOAD_CHUNK = 4
// 增量查询一次最多读多少条：正常只有个位数，上限只用于异常场景兜底。
const LOG_INCREMENT_LIMIT = 1000
// DB 打不开（文件缺失/被锁）时的重试间隔。
const LOG_DB_RETRY_MS = 30_000

// 捕获增量落盘：只存「日志里没有的那部分」与每会话游标；日志本身不落盘（重启从 DB 重读）。
const CAPTURE_FLUSH_MS = 1000
const CAPTURE_MAX_BYTES = 5 * 1024 * 1024
// 同一句话的两个视角：正文压空白后相同 + |Δt| ≤ 3s 视为同一条。时间戳完全对得上
// （平台消息 id 相同）时放宽到 10s——多段回复的日志条目时间是整轮结束时刻。
const DEDUPE_WINDOW = 3000
const DEDUPE_EXACT_WINDOW = 10_000

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

// ── 日志条目 → 消息 ────────────────────────────────────────────────────
// 去重键里的「压缩空白正文」：空白位置在不同渲染路径里不一致，直接抹掉。
function compactText(value) {
  return textOf(value).replace(/\s+/g, '')
}

// 捕获侧正文是渲染后的文本，日志侧还留着 markdown 标记（`**`、`` ` ``、`~`）：
// 去重比对时一并抹掉，两边才可比。
function twinText(value) {
  return compactText(value).replace(/[*_`~]/g, '')
}

// 日志里的正文是给平台渲染的标记串：`<message>` 是分条边界，`<status/>`/`<silence/>`
// 是元信息，`<markdown>` 是排版。剥完标签再压空白，与捕获侧（元素已渲染）的正文可比。
function plainLogText(value) {
  return stripRawTags(textOf(value)).replace(/\s+/g, ' ').trim()
}

// 一轮回复可能写成多条平台消息：`<message>a</message><message>b</message>`。没有边界标记
// 时整段算一条（`<silence/>` 剥完为空，自然被丢掉）。
function replySegments(value) {
  const raw = textOf(value)
  if (!raw.trim()) return []
  const segments = []
  for (const match of raw.matchAll(/<message(?:\s[^>]*)?>([\s\S]*?)<\/message>/gi)) segments.push(match[1])
  return segments.length ? segments : [raw]
}

const REPLY_TOOLS = new Set(['reply', 'send'])

function parseJsonText(value) {
  try {
    return JSON.parse(textOf(value))
  } catch {
    return null
  }
}

export function apply(ctx) {
  const logger = ctx.logger('media-bridge')
  const root = resolve(process.env.CHATLUNA_WORKSPACE ?? join(process.cwd(), 'data/chatluna/agents-work'))
  logger.info('serving workspace files from %s', root)

  // 会话表：插入顺序即最近活跃顺序；每条消息按 time 去重、升序保存在 messages 里。
  const conversations = new Map()
  // 在线 SSE 订阅者；连接关闭时自己摘除，插件卸载时统一收尾，避免计时器/写句柄泄漏。
  const subscribers = new Set()
  ctx.on('dispose', () => {
    for (const stream of subscribers) stream.close()
    subscribers.clear()
  })

  // 归一键 → 会话键。App 侧把 `route:` 前缀与 `:user:` / `:lane:` 后缀归一后比较，插件这边
  // 用同一套规则把日志会话与捕获会话合到同一个桶：先见到的键（通常是捕获的
  // `session.conversation.key`）为准。
  const keyAliases = new Map()
  const normalizeKey = (value) => {
    const text = textOf(value)
    const stripped = text.startsWith('route:') ? text.slice(6) : text
    const cut = stripped.search(/:(?:user|lane):/)
    return cut > 0 ? stripped.slice(0, cut) : stripped
  }
  const canonicalKey = (value) => {
    const normalized = normalizeKey(value)
    return (normalized && keyAliases.get(normalized)) || textOf(value)
  }
  const rememberKey = (value) => {
    const normalized = normalizeKey(value)
    if (normalized && !keyAliases.has(normalized)) keyAliases.set(normalized, textOf(value))
  }

  // 上次落盘的会话展示信息（群名/昵称/头像）。日志投影按 key 建会话时先套这一层，
  // 重启后不会退化成「群聊 · 尾号」。
  const savedMeta = new Map()
  // 捕获增量有变化；真正的写盘函数在后面定义（防抖 1s）。
  let markCaptureDirty = () => {}

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

  // ── 媒体自托管 ───────────────────────────────────────────────────────
  // 平台 CDN 的地址带时效签名（QQ `rkey`）过期后永久 404，`storage://` 的临时文件也会被
  // 清理：消息里能渲染的东西先落到实例本地，客户端拿到的是不会失效的
  // `/api/platform/media/<file>`。文件名是内容 sha256 的前 16 位 + 扩展名，同一张图重复
  // 出现只占一份。
  const mediaDir = resolve(
    process.env.CHATLUNA_MEDIA_CACHE ?? join(process.cwd(), 'data/chatluna/platform-media')
  )
  const mediaIndexFile = join(mediaDir, 'index.json')
  const MEDIA_CACHE_ROUTE = '/api/platform/media/'
  // 默认 500MB；`CHATLUNA_MEDIA_LIMIT_BYTES` 只用于运维/验证时缩小上限。
  const mediaLimitSetting = Number(process.env.CHATLUNA_MEDIA_LIMIT_BYTES)
  const MEDIA_CACHE_LIMIT_BYTES = Number.isFinite(mediaLimitSetting) && mediaLimitSetting > 0
    ? Math.floor(mediaLimitSetting)
    : 500 * 1024 * 1024
  const MEDIA_DOWNLOAD_CONCURRENCY = 2
  const MEDIA_DOWNLOAD_LIMIT_BYTES = 15 * 1024 * 1024
  const MEDIA_DOWNLOAD_TIMEOUT = 20_000
  // 新消息等本地地址的预算：超时的下载继续在后台跑（完成后再改写同一个 media 对象），
  // 消息本体先按原地址发出去，不让一次慢下载拖住入站事件。
  const MEDIA_LOCALIZE_BUDGET = 4000
  // 下载失败的 URL 在 10 分钟内不再尝试：过期签名重试多少次都是 404。
  const MEDIA_FAILURE_TTL = 10 * 60_000
  // `storage://<id>` → `/files/<id>` 的存在性检查结果；临时文件 24h 过期，缓存 5 分钟够用。
  const STORAGE_CHECK_TTL = 5 * 60_000
  const STORAGE_CHECK_TIMEOUT = 3000

  const MEDIA_EXT_BY_MIME = {
    'image/png': '.png',
    'image/jpeg': '.jpg',
    'image/jpg': '.jpg',
    'image/webp': '.webp',
    'image/gif': '.gif',
    'image/bmp': '.bmp',
    'image/svg+xml': '.svg',
    'video/mp4': '.mp4',
    'video/webm': '.webm',
    'video/quicktime': '.mov',
    'audio/mpeg': '.mp3',
    'audio/mp4': '.m4a',
    'audio/wav': '.wav',
    'audio/x-wav': '.wav',
    'audio/ogg': '.ogg',
    'audio/amr': '.amr',
    'audio/silk': '.silk',
    'application/pdf': '.pdf',
    'application/zip': '.zip'
  }

  mkdirSync(mediaDir, { recursive: true })
  // 原始 URL → {file, mime, size, at}；重启时从 index.json 恢复，之后先查它再下载。
  const mediaByUrl = new Map()
  // 目录里实际存在的文件名（内容哈希命名）；用它做「落盘命中」，不每条消息都 stat。
  const mediaFiles = new Set()
  const mediaFailures = new Map()

  const isMediaFile = (name) => /^[0-9a-f]{16}\.[a-z0-9]{2,5}$/i.test(name)

  const loadMediaCache = () => {
    try {
      for (const entry of readdirSync(mediaDir, { withFileTypes: true })) {
        if (entry.isFile() && isMediaFile(entry.name)) mediaFiles.add(entry.name)
      }
    } catch {}
    try {
      const index = parseJsonText(readFileSync(mediaIndexFile, 'utf8'))
      for (const [url, entry] of Object.entries(index?.urls ?? {})) {
        const file = textOf(entry?.file)
        if (!isMediaFile(file) || !mediaFiles.has(file)) continue
        mediaByUrl.set(url, {
          file,
          mime: textOf(entry.mime),
          size: Number(entry.size) || 0,
          at: Number(entry.at) || 0
        })
      }
    } catch {}
  }
  loadMediaCache()

  let mediaIndexTimer = null
  const flushMediaIndex = () => {
    if (mediaIndexTimer !== null) {
      clearTimeout(mediaIndexTimer)
      mediaIndexTimer = null
    }
    const urls = {}
    for (const [url, entry] of mediaByUrl) {
      urls[url] = { file: entry.file, mime: entry.mime, size: entry.size, at: entry.at }
    }
    try {
      mkdirSync(mediaDir, { recursive: true })
      const temp = mediaIndexFile + '.tmp'
      writeFileSync(temp, JSON.stringify({ version: 1, savedAt: Date.now(), urls }))
      renameSync(temp, mediaIndexFile)
    } catch (error) {
      logger.warn('platform media index flush failed (%s): %s', mediaIndexFile, error?.message ?? error)
    }
  }
  const markMediaIndexDirty = () => {
    if (mediaIndexTimer !== null) return
    mediaIndexTimer = setTimeout(flushMediaIndex, 1000)
    mediaIndexTimer.unref?.()
  }

  // 下载队列：并发 2，排队的是 Promise 工厂；单文件 15MB / 20s 上限在 fetchMedia 里。
  let downloadsActive = 0
  const downloadQueue = []
  const downloadPending = new Map()
  const pumpDownloads = () => {
    while (downloadsActive < MEDIA_DOWNLOAD_CONCURRENCY && downloadQueue.length) {
      const job = downloadQueue.shift()
      downloadsActive += 1
      job.run()
        .then(job.resolve, () => job.resolve(null))
        .finally(() => {
          downloadsActive -= 1
          pumpDownloads()
        })
    }
  }
  const withDownloadSlot = (run) => new Promise((resolve) => {
    downloadQueue.push({ run, resolve })
    pumpDownloads()
  })

  const extensionFor = (mime, url) => {
    const type = textOf(mime).split(';')[0].trim().toLowerCase()
    if (MEDIA_EXT_BY_MIME[type]) return MEDIA_EXT_BY_MIME[type]
    try {
      const ext = extname(new URL(url).pathname).toLowerCase()
      if (/^\.[a-z0-9]{2,5}$/.test(ext)) return ext
    } catch {}
    return '.bin'
  }

  // 流式下载 → 按内容哈希命名落盘。任何失败（状态码、超 15MB、超时、网络）都返回 null，
  // 由调用方保留原 URL 并标 `cached:false`。
  const fetchMedia = async (url) => {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), MEDIA_DOWNLOAD_TIMEOUT)
    timer.unref?.()
    try {
      const response = await fetch(url, {
        signal: controller.signal,
        headers: { 'user-agent': 'chatluna-media-bridge/1.0' }
      })
      if (!response.ok || !response.body) return null
      const declared = Number(response.headers.get('content-length'))
      if (Number.isFinite(declared) && declared > MEDIA_DOWNLOAD_LIMIT_BYTES) return null
      const reader = response.body.getReader()
      const chunks = []
      let total = 0
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        if (!value?.byteLength) continue
        total += value.byteLength
        if (total > MEDIA_DOWNLOAD_LIMIT_BYTES) {
          await reader.cancel().catch(() => {})
          return null
        }
        chunks.push(value)
      }
      if (!total) return null
      const body = Buffer.concat(
        chunks.map((chunk) => Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength)),
        total
      )
      const digest = createHash('sha256').update(body).digest('hex').slice(0, 16)
      const file = digest + extensionFor(response.headers.get('content-type'), response.url || url)
      if (!mediaFiles.has(file)) {
        const temp = join(mediaDir, `.${digest}-${process.pid}-${Date.now()}.tmp`)
        await writeFile(temp, body)
        await rename(temp, join(mediaDir, file))
        mediaFiles.add(file)
      }
      const entry = {
        file,
        mime: textOf(response.headers.get('content-type')),
        size: total,
        at: Date.now()
      }
      mediaByUrl.set(url, entry)
      markMediaIndexDirty()
      void enforceMediaLimit()
      return entry
    } catch {
      return null
    } finally {
      clearTimeout(timer)
      controller.abort()
    }
  }

  // 同一个 URL 只下一次：进行中的请求共用同一个 Promise；成功结果留在 mediaByUrl 里，
  // 重启后由 index.json 恢复，命中即不再发请求。
  const downloadMedia = async (url) => {
    const known = mediaByUrl.get(url)
    if (known && mediaFiles.has(known.file)) return known
    const failedAt = mediaFailures.get(url)
    if (failedAt !== undefined && Date.now() - failedAt < MEDIA_FAILURE_TTL) return null
    let pending = downloadPending.get(url)
    if (!pending) {
      pending = withDownloadSlot(() => fetchMedia(url))
      downloadPending.set(url, pending)
      void pending.then(
        (entry) => {
          downloadPending.delete(url)
          if (entry) {
            mediaFailures.delete(url)
            return
          }
          if (mediaFailures.size > 1024) {
            for (const [key, at] of mediaFailures) {
              if (Date.now() - at >= MEDIA_FAILURE_TTL) mediaFailures.delete(key)
            }
          }
          mediaFailures.set(url, Date.now())
        },
        () => downloadPending.delete(url)
      )
    }
    return pending
  }

  // 磁盘上限：超过 500MB 按 mtime 淘汰最旧的；索引里指向被删文件的条目一并清掉。
  let mediaLimitRunning = false
  const enforceMediaLimit = async () => {
    if (mediaLimitRunning) return
    mediaLimitRunning = true
    try {
      const entries = []
      for (const entry of await readdir(mediaDir, { withFileTypes: true })) {
        if (!entry.isFile()) continue
        if (entry.name.startsWith('.') && entry.name.endsWith('.tmp')) {
          // 写盘被中断留下的临时文件：一小时后清掉，不参与上限计算。
          const info = await stat(join(mediaDir, entry.name)).catch(() => undefined)
          if (info && Date.now() - info.mtimeMs > 3_600_000) {
            await unlink(join(mediaDir, entry.name)).catch(() => {})
          }
          continue
        }
        if (!isMediaFile(entry.name)) continue
        const info = await stat(join(mediaDir, entry.name)).catch(() => undefined)
        if (info === undefined) {
          mediaFiles.delete(entry.name)
          continue
        }
        entries.push({ name: entry.name, size: info.size, at: info.mtimeMs })
      }
      let total = entries.reduce((sum, entry) => sum + entry.size, 0)
      if (total <= MEDIA_CACHE_LIMIT_BYTES) return
      entries.sort((a, b) => a.at - b.at)
      let removed = 0
      for (const entry of entries) {
        if (total <= MEDIA_CACHE_LIMIT_BYTES) break
        await unlink(join(mediaDir, entry.name)).catch(() => {})
        total -= entry.size
        removed += 1
        mediaFiles.delete(entry.name)
        for (const [url, cached] of mediaByUrl) {
          if (cached.file === entry.name) mediaByUrl.delete(url)
        }
      }
      markMediaIndexDirty()
      logger.info('platform media cache trimmed: %d files, now %d bytes', removed, total)
    } catch (error) {
      logger.warn('platform media cache trim failed: %s', error?.message ?? error)
    } finally {
      mediaLimitRunning = false
    }
  }
  void enforceMediaLimit()

  // `storage://<id>` 是 24h 临时文件：只把还存在的换成实例内 `/files/<id>`，过期的保留
  // `ref`（客户端显示占位），别给一个必然 404 的 URL。检查走本机 `/files/<id>`。
  const storageState = new Map()
  const storagePending = new Map()
  // 启动全量投影可能一次遇到很多 `storage://`：检查也排队（并发 4），别把本机端口打满。
  let storageActive = 0
  const storageQueue = []
  const pumpStorage = () => {
    while (storageActive < 4 && storageQueue.length) {
      const job = storageQueue.shift()
      storageActive += 1
      job.run()
        .then(job.resolve, () => job.resolve(false))
        .finally(() => {
          storageActive -= 1
          pumpStorage()
        })
    }
  }
  const withStorageSlot = (run) => new Promise((resolve) => {
    storageQueue.push({ run, resolve })
    pumpStorage()
  })
  const instanceOrigin = () => {
    const explicit = textOf(process.env.CHATLUNA_MEDIA_ORIGIN).trim()
    if (explicit) return explicit.replace(/\/+$/, '')
    const port = ctx.server?.port ?? ctx.server?.config?.port
    if (port) return `http://127.0.0.1:${port}`
    return textOf(ctx.server?.baseUrl).replace(/\/+$/, '')
  }
  const storageIdOf = (value) => {
    const raw = textOf(value).trim()
    if (!/^storage:\/\//i.test(raw)) return ''
    return raw.slice('storage://'.length)
  }
  const storageExists = async (id) => {
    const checked = storageState.get(id)
    if (checked && Date.now() - checked.at < STORAGE_CHECK_TTL) return checked.ok
    // 服务器还没起来（apply 早期）：这次不缓存，等有地址了再查。
    const origin = instanceOrigin()
    if (!origin) return false
    let pending = storagePending.get(id)
    if (!pending) {
      pending = withStorageSlot(async () => {
        try {
          const response = await fetch(`${origin}/files/${encodeURIComponent(id)}`, {
            signal: AbortSignal.timeout(STORAGE_CHECK_TIMEOUT)
          })
          const ok = response.status === 200
          await response.body?.cancel?.()
          return ok
        } catch {
          return false
        }
      })
      storagePending.set(id, pending)
      void pending.then((ok) => {
        storagePending.delete(id)
        if (storageState.size > 512) {
          const oldest = storageState.keys().next().value
          if (oldest !== undefined) storageState.delete(oldest)
        }
        storageState.set(id, { ok, at: Date.now() })
      }, () => storagePending.delete(id))
    }
    return pending
  }

  const mediaRouteOf = (file) => MEDIA_CACHE_ROUTE + file

  const localizeItem = async (item, { downloads = true, deadline = 0 } = {}) => {
    if (!item || typeof item !== 'object') return item
    const storageId = storageIdOf(item.ref) || storageIdOf(item.url)
    if (storageId) {
      if (await storageExists(storageId)) {
        item.url = '/files/' + encodeURIComponent(storageId)
        delete item.ref
        item.cached = true
      }
      // 过期/未知时保留 ref，不再尝试当 CDN 链接下载。
      return item
    }
    const url = textOf(item.url)
    if (!/^https?:\/\//i.test(url)) return item
    const known = mediaByUrl.get(url)
    if (known && mediaFiles.has(known.file)) {
      item.url = mediaRouteOf(known.file)
      item.cached = true
      return item
    }
    // 历史回填策略：只在「消息产出」时下载；启动全量投影只做索引命中与 storage 校验，
    // 不把几百条旧消息里的过期 CDN 地址重新拉一遍。
    if (!downloads) return item
    const pending = downloadMedia(url).then((entry) => {
      if (entry) {
        item.url = mediaRouteOf(entry.file)
        item.cached = true
      } else {
        item.cached = false
      }
      return entry
    })
    if (deadline > 0) {
      const remaining = deadline - Date.now()
      // 预算已经用完：不 await，后台下载完成后再改写同一个对象。
      if (remaining > 0) await withTimeout(() => pending, remaining)
    } else {
      await pending
    }
    return item
  }

  // 对一组 media 原地改写。同步段会先把「落盘命中」的地址换掉（调用方不 await 也有用），
  // 下载在后台继续并修改同一个对象。
  const localizeMedia = async (items, options) => {
    if (!Array.isArray(items) || !items.length) return items
    await Promise.all(items.map((item) => localizeItem(item, options))).catch(() => {})
    return items
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
    // 能落地的立刻换成本实例地址（下载受队伍/上限约束；超预算的部分后台继续）。
    await localizeMedia(items, { deadline: Date.now() + MEDIA_LOCALIZE_BUDGET })
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

  // 按时间升序插入：正常是追加；时间戳回退（适配器补发/重试、日志与捕获差几百毫秒）
  // 时插到正确位置，接口永远返回升序。
  const insertSorted = (messages, message) => {
    if (!messages.length || message.time >= messages[messages.length - 1].time) {
      messages.push(message)
      return
    }
    let index = messages.length - 1
    while (index >= 0 && messages[index].time > message.time) index -= 1
    messages.splice(index + 1, 0, message)
  }

  // 落一条消息。两个来源（会话日志 `log` / 事件捕获 `captured`）各自上报，同一句话只留一条。
  // 返回需要推实时帧的消息；重复/被合并/已推过则 null。
  const record = (key, entry, source = 'captured') => {
    const time = Number(entry.time) || Date.now()
    const channelId = textOf(entry.channelId)
    const guildId = entry.guildId ? textOf(entry.guildId) : null

    let conversation = conversations.get(key)
    if (conversation) {
      // 末尾即最新活跃；删了重插把这次活动挪到 LRU 尾部。
      conversations.delete(key)
    } else {
      const saved = savedMeta.get(key)
      conversation = {
        key,
        platform: saved?.platform ?? '',
        selfId: saved?.selfId ?? '',
        channelId: saved?.channelId ?? '',
        guildId: saved?.guildId ?? null,
        kind: 'private',
        name: saved?.name ?? '',
        nameKind: saved?.nameKind ?? 'private',
        title: '',
        avatar: saved?.avatar ?? null,
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

    const message = {
      id: textOf(entry.id),
      time,
      dir: entry.dir === 'out' ? 'out' : 'in',
      userId: textOf(entry.userId),
      userName: textOf(entry.userName),
      avatar: entry.avatar ? textOf(entry.avatar) : null,
      content: textOf(entry.content),
      media: Array.isArray(entry.media) ? entry.media : [],
      // 内部字段：`captured` 的部分才落盘，`log` 的部分每次从 DB 重读。
      _src: source
    }

    // 同一句话的另一个视角已经在了：不新增条目，把信息并进已有那条。
    // 已被 App 收到过的那条保留自己的 id（换 id 会让客户端当成两条），时间改成日志里的
    // ——日志是时间的真源，重新起进程后同一个会话的最后一条才会和重启前完全一致。
    const twin = findTwin(conversation.messages, message)
    if (twin) {
      if (source === 'log') {
        // 日志优先：正文与时间以日志为准，媒体/昵称/头像从捕获副本补。
        const index = conversation.messages.indexOf(twin)
        if (index >= 0) conversation.messages.splice(index, 1)
        twin.content = message.content
        twin.dir = message.dir
        twin.time = message.time
        if (!twin.media.length && message.media.length) twin.media = message.media
        if (!twin.userId && message.userId) twin.userId = message.userId
        if (!twin.userName && message.userName) twin.userName = message.userName
        twin.avatar = twin.avatar ?? message.avatar
        // 并完这条就是日志条目了，捕获副本不再需要落盘。
        if (twin._src !== 'log') markCaptureDirty()
        twin._src = 'log'
        insertSorted(conversation.messages, twin)
      } else {
        if (!twin.media.length && message.media.length) twin.media = message.media
        if (!twin.userName && message.userName) twin.userName = message.userName
        if (!twin.avatar && message.avatar) twin.avatar = message.avatar
      }
      return null
    }

    // 正常是追加；时间戳回退（适配器补发/重试）时插到正确位置，保持升序。
    insertSorted(conversation.messages, message)
    if (conversation.messages.length > MESSAGE_CAPACITY) {
      conversation.messages.splice(0, conversation.messages.length - MESSAGE_CAPACITY)
    }

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
      if (oldestKey !== null) {
        conversations.delete(oldestKey)
        // 被淘汰会话的捕获增量仍然落盘：App 翻旧会话时还能补齐。
        markCaptureDirty()
      }
    }

    // 捕获增量要落盘（日志部分不落盘）。
    if (source === 'captured') markCaptureDirty()
    return message
  }

  // 同一条消息的另一个来源/另一次上报。判定顺序：
  // 1. 平台消息 id 相同（捕获的 `messageId` 与日志 envelope 的 `externalId` 是同一个）；
  // 2. 同来源：正文压空白相同且 500ms 内（多 bot 实例/适配器重复上报）；
  // 3. 跨来源：正文压空白相同（或多出的部分只是媒体占位）且 3s 内；时间戳对不上但
  //    正文完全相同时放宽到 10s（多段回复的日志条目时间是整轮结束时刻）。
  function findTwin(messages, message) {
    const content = twinText(message.content)
    let best = null
    let bestDelta = Infinity
    for (const candidate of messages) {
      if (candidate.dir !== message.dir) continue
      const delta = Math.abs(candidate.time - message.time)
      if (message.id && candidate.id === message.id && delta <= DEDUPE_EXACT_WINDOW) return candidate
      const candidateContent = twinText(candidate.content)
      if (candidate._src === message._src) {
        // 只有捕获侧会被多个 bot 实例/适配器重复上报；日志条目 id 唯一，正文相同也是
        // 两条不同的消息（连发两张图就是这样），不能合并。
        if (message._src === 'captured' && delta <= OUTBOUND_DEDUPE_MS && content && candidateContent === content) {
          return candidate
        }
        continue
      }
      if (!content) continue
      const exact = candidateContent === content
      const contained = !exact && content.length >= 4 && candidateContent.length >= 4 &&
        (candidateContent.startsWith(content) || content.startsWith(candidateContent))
      if (!exact && !contained) continue
      if (delta > (exact ? DEDUPE_EXACT_WINDOW : DEDUPE_WINDOW)) continue
      if (delta < bestDelta) {
        bestDelta = delta
        best = candidate
      }
    }
    return best
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
    rememberKey(key)
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
    rememberKey(key)
    const message = record(key, entry)
    if (message) notify(key, message)
  })

  // ── 捕获增量持久化 ────────────────────────────────────────────────────
  // 只存「日志里没有的那部分」（指令回复、未触发 agent 的群消息）与每会话游标；日志部分
  // 每次启动从 DB 重读，所以文件很小。原子写（tmp + rename）、1s 防抖、进程退出前刷一次。
  const captureFile = resolve(
    process.env.CHATLUNA_PLATFORM_CAPTURE ?? join(process.cwd(), 'data/chatluna/platform-capture.json')
  )
  const persistedCursors = new Map()
  let captureTimer = null

  const captureMeta = (conversation) => ({
    platform: conversation.platform,
    selfId: conversation.selfId,
    channelId: conversation.channelId,
    guildId: conversation.guildId,
    name: conversation.name,
    nameKind: conversation.nameKind,
    avatar: conversation.avatar
  })

  const captureSnapshot = () => {
    const items = []
    const seen = new Set()
    for (const conversation of conversations.values()) {
      seen.add(conversation.key)
      items.push({
        key: conversation.key,
        ...captureMeta(conversation),
        messages: conversation.messages
          .filter((message) => message._src === 'captured')
          .map((message) => ({
            id: message.id,
            time: message.time,
            dir: message.dir,
            userId: message.userId,
            userName: message.userName,
            avatar: message.avatar,
            content: message.content,
            media: message.media
          }))
      })
    }
    // 已被 LRU 淘汰、但还没再出现消息的会话只留展示信息。
    for (const [key, meta] of savedMeta) {
      if (seen.has(key)) continue
      items.push({ key, ...meta, messages: [] })
    }
    return { version: 2, savedAt: Date.now(), cursors: Object.fromEntries(logCursors), conversations: items }
  }

  // 体积上限 5MB：超了先丢最旧的捕获消息（日志那份还在 DB 里，丢了也能重读）。
  const captureJson = (snapshot) => {
    let json = JSON.stringify(snapshot)
    if (Buffer.byteLength(json) <= CAPTURE_MAX_BYTES) return json
    const entries = []
    for (const conversation of snapshot.conversations) {
      for (const message of conversation.messages) entries.push({ conversation, message })
    }
    entries.sort((a, b) => a.message.time - b.message.time)
    let index = 0
    while (Buffer.byteLength(json) > CAPTURE_MAX_BYTES && index < entries.length) {
      for (let step = 0; step < 20 && index < entries.length; step += 1, index += 1) {
        const { conversation, message } = entries[index]
        conversation.messages = conversation.messages.filter((candidate) => candidate !== message)
      }
      json = JSON.stringify(snapshot)
    }
    while (Buffer.byteLength(json) > CAPTURE_MAX_BYTES && snapshot.conversations.length > 1) {
      snapshot.conversations.pop()
      json = JSON.stringify(snapshot)
    }
    return json
  }

  const flushCapture = () => {
    if (captureTimer !== null) {
      clearTimeout(captureTimer)
      captureTimer = null
    }
    const json = captureJson(captureSnapshot())
    try {
      mkdirSync(dirname(captureFile), { recursive: true })
      const temp = captureFile + '.tmp'
      writeFileSync(temp, json)
      renameSync(temp, captureFile)
    } catch (error) {
      logger.warn('platform capture flush failed (%s): %s', captureFile, error?.message ?? error)
    }
  }

  // 先恢复上次的增量，再后台跑日志全量：服务启动不被 DB 读取挡住。
  const restoreCapture = () => {
    let raw
    try {
      raw = readFileSync(captureFile, 'utf8')
    } catch {
      return
    }
    const data = parseJsonText(raw)
    if (!data || typeof data !== 'object') return
    for (const [sessionId, value] of Object.entries(data.cursors ?? {})) {
      const n = Number(value)
      if (Number.isSafeInteger(n) && n > 0) persistedCursors.set(textOf(sessionId), n)
    }
    const restored = []
    for (const conversation of Array.isArray(data.conversations) ? data.conversations : []) {
      const key = textOf(conversation?.key)
      if (!key) continue
      rememberKey(key)
      savedMeta.set(key, {
        platform: textOf(conversation.platform),
        selfId: textOf(conversation.selfId),
        channelId: textOf(conversation.channelId),
        guildId: conversation.guildId ? textOf(conversation.guildId) : null,
        name: textOf(conversation.name),
        nameKind: textOf(conversation.nameKind) || 'private',
        avatar: conversation.avatar ? textOf(conversation.avatar) : null
      })
      for (const message of Array.isArray(conversation.messages) ? conversation.messages : []) {
        if (!message || !Number.isFinite(Number(message.time))) continue
        restored.push({ key, message })
      }
    }
    restored.sort((a, b) => Number(a.message.time) - Number(b.message.time))
    for (const { key, message } of restored) {
      // 上次落盘的媒体地址可能还是原 CDN 地址：索引里有就能直接换成本地地址（不再下载）。
      void localizeMedia(Array.isArray(message.media) ? message.media : [], { downloads: false })
      record(key, {
        id: textOf(message.id),
        time: Number(message.time),
        dir: message.dir,
        userId: textOf(message.userId),
        userName: textOf(message.userName),
        avatar: message.avatar ? textOf(message.avatar) : null,
        content: textOf(message.content),
        media: Array.isArray(message.media) ? message.media : []
      }, 'captured')
    }
    if (restored.length) logger.info('platform capture restored: %d messages from %s', restored.length, captureFile)
  }

  restoreCapture()

  markCaptureDirty = () => {
    if (captureTimer !== null) return
    captureTimer = setTimeout(flushCapture, CAPTURE_FLUSH_MS)
    captureTimer.unref?.()
  }
  // 退出前把没落盘的增量刷掉：daemon 正常停止走 dispose，强杀走 exit。
  const flushOnExit = () => {
    flushCapture()
    flushMediaIndex()
  }
  process.once('exit', flushOnExit)

  // ── 会话日志投影 ──────────────────────────────────────────────────────
  // 普通消息的真源是 ChatLuna 的会话日志：`chatluna_sessions` 给会话（键 = conversationKey，
  // 与捕获侧 `session.conversation.key` 同源），`chatluna_session_entry.kind = 'message'`
  // 给消息（user → in，assistant → out）。web / subagent 会话不是平台对话，不投影。
  const logDbPath = resolve(process.env.CHATLUNA_DB ?? join(process.cwd(), 'data/chatluna.db'))
  const logCursors = new Map()
  const loadedSessions = new Set()
  const peerCache = new Map()
  let peerCacheAt = 0
  let logDb = null
  let logStatements = null
  let logSessions = []
  let logSessionIndex = new Map()
  let dbRetryAt = 0
  let dbWarnAt = 0
  let tickBusy = false
  let disposed = false
  let fullLoadRunning = false
  let fullLoadDone = false
  let pollTimer = null

  const peerParts = (value) => {
    const text = textOf(value)
    const parts = text.split(':')
    if (parts.length < 4) return null
    return { platform: parts[0], selfId: parts[1], kind: parts[2], id: parts.slice(3).join(':') }
  }

  const peerKey = (platform, selfId, kind, id) => [platform, selfId, kind, id].join('\u0000')

  const peerDisplay = (platform, selfId, kind, id) => {
    if (!platform || !id) return null
    return peerCache.get(peerKey(platform, selfId, kind, id)) ?? null
  }

  const refreshPeers = () => {
    const next = new Map()
    for (const row of logStatements.peers.all()) {
      next.set(peerKey(textOf(row.platform), textOf(row.selfId), textOf(row.kind), textOf(row.id)), {
        name: textOf(row.name),
        avatar: textOf(row.avatar)
      })
    }
    peerCache.clear()
    for (const [key, value] of next) peerCache.set(key, value)
    peerCacheAt = Date.now()
  }

  const metaOf = (row) => {
    const identity = parseJsonText(row.identity) ?? {}
    const peer = peerParts(row.peer) ?? peerParts(row.convPeer)
    const platform = textOf(identity.platform) || peer?.platform || textOf(row.origin)
    const selfId = textOf(identity.selfId) || peer?.selfId || ''
    const channelId = textOf(identity.channelId) || peer?.id || ''
    const guildId = textOf(identity.guildId) || (peer?.kind === 'guild' ? peer.id : '') || null
    const kind = conversationKind(guildId, channelId)
    const conversationPeer = peer && peer.kind === (kind === 'group' ? 'guild' : 'user')
      ? { name: textOf(row.peerName), avatar: textOf(row.peerAvatar) }
      : peerDisplay(platform, selfId, kind === 'group' ? 'guild' : 'user', kind === 'group' ? guildId : channelId)
    const bot = peerDisplay(platform, selfId, 'bot', selfId)
    return {
      platform,
      selfId,
      channelId,
      guildId,
      kind,
      name: cleanName(conversationPeer?.name),
      avatar: textOf(conversationPeer?.avatar) || null,
      botName: cleanName(bot?.name),
      botAvatar: textOf(bot?.avatar) || null
    }
  }

  const refreshSessions = () => {
    if (Date.now() - peerCacheAt > 30_000) refreshPeers()
    const next = []
    const index = new Map()
    for (const row of logStatements.sessions.all()) {
      const id = textOf(row.id)
      const rawKey = textOf(row.conversationKey)
      if (!id || !rawKey) continue
      rememberKey(rawKey)
      const session = {
        id,
        key: canonicalKey(rawKey),
        meta: metaOf(row),
        lastActiveAt: Number(row.lastActiveAt) || 0
      }
      next.push(session)
      index.set(id, session)
    }
    logSessions = next
    logSessionIndex = index
  }

  const MEDIA_TEXT = { image: '[图片]', video: '[视频]', audio: '[语音]', file: '[文件]' }

  const mediaItemOf = (descriptor) => {
    const source = textOf(descriptor?.source).trim()
    if (!source) return null
    const kind = descriptor?.kind || 'file'
    const item = { kind }
    const url = workspaceRelativeOf(source) || (isWorkspacePath(source) ? source : '') || normalizeMediaUrl(source)
    if (url) item.url = url
    else item.ref = unescapeAttr(source)
    if (descriptor?.mime) item.mime = textOf(descriptor.mime)
    const name = cleanName(descriptor?.name)
    if (name) item.name = name
    const size = Number(descriptor?.size)
    if (Number.isFinite(size) && size > 0) item.size = size
    return item
  }

  // ChatLuna 的 `file` 块：`{mediaType, data:{type:'reference', reference:'storage://…'}}`。
  // 参考值不是可访问地址，`mediaItemOf` 会把它留成 `ref`，客户端按占位处理。
  const fileDescriptor = (block) => {
    const mime = textOf(block?.mediaType ?? block?.mimeType ?? block?.mime)
    const data = block?.data
    const source = textOf(
      (typeof data === 'string' ? data : '') ||
      data?.url || data?.reference || data?.data || data?.src ||
      block?.url || block?.reference || block?.src
    )
    return { kind: mediaKind('file', mime) || 'file', mime, source }
  }

  const withMeta = (session, item) => ({
    ...item,
    platform: session.meta.platform,
    selfId: session.meta.selfId,
    channelId: session.meta.channelId,
    guildId: session.meta.guildId,
    conversationName: session.meta.name,
    conversationAvatar: session.meta.avatar
  })

  // 入站：真正来自平台的只有 `envelope` 块（`kind: 'message'`），一个 envelope 就是一条
  // 平台消息，`externalId` 就是平台消息 id。同一轮里被折叠进来的记忆/状态块是纯 `text`，
  // 不是用户发言，跳过。
  const envelopeMessages = (blocks, row, session) => {
    const out = []
    const entryTime = Number(row.time) || Number(row.n) || Date.now()
    for (const block of Array.isArray(blocks) ? blocks : []) {
      if (block?.type !== 'envelope') continue
      if (block.kind && block.kind !== 'message') continue
      const media = []
      let text = ''
      for (const child of Array.isArray(block.content) ? block.content : []) {
        if (child?.type === 'text') text += textOf(child.text)
        else if (child?.type === 'file') {
          const item = mediaItemOf(fileDescriptor(child))
          if (item) {
            media.push(item)
            text += MEDIA_TEXT[item.kind] ?? '[文件]'
          }
        }
      }
      const content = clipContent(plainLogText(text))
      if (!content && !media.length) continue
      const senderId = textOf(block.sender?.id)
      const sender = senderId ? peerDisplay(session.meta.platform, session.meta.selfId, 'user', senderId) : null
      out.push(withMeta(session, {
        id: textOf(block.externalId) || textOf(block.id) || `${session.id}:${row.n}`,
        dir: 'in',
        time: Number(block.time) || entryTime,
        userId: senderId,
        userName: cleanName(block.sender?.name) || cleanName(sender?.name) || shortId(senderId),
        avatar: textOf(sender?.avatar) || null,
        content,
        media
      }))
    }
    return out
  }

  // 出站：正文可能在 `text` 块里（多段用 `<message>` 分条），也可能在 `reply` 工具的
  // `input.content` 里。一段平台消息 = 一条消息，媒体从该段里的 `<img src=…>` 取。
  const assistantMessages = (message, row, session) => {
    const blocks = Array.isArray(message.content) ? message.content : []
    let source = ''
    for (const block of blocks) if (block?.type === 'text') source += textOf(block.text)
    if (!source.trim()) {
      for (const block of blocks) {
        if (block?.type !== 'tool-call' || !REPLY_TOOLS.has(textOf(block.toolName))) continue
        source += textOf(block.input?.content ?? block.input?.text)
      }
    }
    const out = []
    const entryTime = Number(row.time) || Date.now()
    for (const segment of replySegments(source)) {
      const content = clipContent(plainLogText(segment))
      const media = rawMediaTags(segment).map(mediaItemOf).filter(Boolean)
      if (!content && !media.length) continue
      out.push(withMeta(session, {
        id: `${textOf(message.id) || `${session.id}:${row.n}`}:${out.length}`,
        dir: 'out',
        time: entryTime + out.length,
        userId: session.meta.selfId,
        userName: session.meta.botName || session.meta.selfId,
        avatar: session.meta.botAvatar,
        content,
        media
      }))
    }
    return out
  }

  const projectRow = (session, row, publish) => {
    const payload = parseJsonText(row.payloadJson)
    const message = payload?.message ?? payload
    if (!message || typeof message !== 'object') return 0
    const items = message.role === 'user'
      ? envelopeMessages(message.content, row, session)
      : message.role === 'assistant'
        ? assistantMessages(message, row, session)
        : []
    let count = 0
    for (const item of items) {
      // 历史只做索引命中与 storage 校验；只有增量（实时流要立刻发出去的）才触发新下载。
      void localizeMedia(item.media, { downloads: publish })
      const recorded = record(session.key, item, 'log')
      count += 1
      if (recorded && publish) notify(session.key, recorded)
    }
    return count
  }

  const advanceCursor = (session, row) => {
    const n = Number(row.n) || 0
    const previous = logCursors.get(session.id) ?? 0
    if (n > previous) logCursors.set(session.id, n)
    return n > previous
  }

  // 首次全量：一个会话最近 300 条 message 条目（多会话的同一会话键会先后并入同一列表）。
  // 不推实时帧——App 连上时的回放与分页已经覆盖这批历史。
  const loadWindow = (session) => {
    if (!logStatements) return 0
    let rows
    try {
      rows = logStatements.window.all(session.id)
    } catch (error) {
      dbFailure('window', error)
      return 0
    }
    let count = 0
    for (let index = rows.length - 1; index >= 0; index -= 1) {
      const row = rows[index]
      if (advanceCursor(session, row)) markCaptureDirty()
      count += projectRow(session, row, false)
    }
    loadedSessions.add(session.id)
    return count
  }

  const loadNew = (session) => {
    if (!logStatements) return 0
    const cursor = logCursors.get(session.id) ?? 0
    let rows
    try {
      rows = logStatements.newer.all(session.id, cursor)
    } catch (error) {
      dbFailure('increment', error)
      return 0
    }
    let count = 0
    for (const row of rows) {
      if (advanceCursor(session, row)) markCaptureDirty()
      count += projectRow(session, row, true)
    }
    return count
  }

  function dbFailure(stage, error) {
    logger.warn('chatluna log projection %s failed: %s', stage, error?.message ?? error)
    // 查询失败（例如 DB 被独占/文件被替换）：关掉连接，稍后重开并重跑全量。
    try {
      logDb?.close()
    } catch {}
    logDb = null
    logStatements = null
    fullLoadDone = false
    loadedSessions.clear()
    dbRetryAt = Date.now() + LOG_DB_RETRY_MS
  }

  const openLogDb = async () => {
    if (logDb) return true
    if (Date.now() < dbRetryAt) return false
    try {
      const { DatabaseSync } = await import('node:sqlite')
      logDb = new DatabaseSync(logDbPath, { readOnly: true })
      try {
        logDb.exec('pragma busy_timeout = 1000')
      } catch {}
      logStatements = {
        sessions: logDb.prepare(`
          select s.id as id, s.conversationKey as conversationKey, s.origin as origin,
                 s.peer as peer, s.lastActiveAt as lastActiveAt,
                 c.identity as identity, c.peer as convPeer,
                 p.name as peerName, p.avatar as peerAvatar
            from chatluna_sessions s
            left join chatluna_conversations c on c.key = s.conversationKey
            left join chatluna_peers p on p.key = s.peer
           where s.conversationKey is not null
             and s.origin not in ('web', 'subagent')
             and s.messageCount > 0
           order by s.lastActiveAt desc
           limit ${LOG_SESSION_LIMIT}
        `),
        window: logDb.prepare(`
          select n, time, payloadJson from chatluna_session_entry
           where sessionId = ? and kind = 'message'
           order by n desc limit ${LOG_ENTRY_WINDOW}
        `),
        newer: logDb.prepare(`
          select n, time, payloadJson from chatluna_session_entry
           where sessionId = ? and kind = 'message' and n > ?
           order by n asc limit ${LOG_INCREMENT_LIMIT}
        `),
        peers: logDb.prepare('select platform, selfId, kind, id, name, avatar from chatluna_peers')
      }
      logger.info('chatluna log projection: reading %s', logDbPath)
      return true
    } catch (error) {
      logDb = null
      logStatements = null
      dbRetryAt = Date.now() + LOG_DB_RETRY_MS
      if (Date.now() > dbWarnAt) {
        dbWarnAt = Date.now() + 60_000
        logger.warn('chatluna log projection unavailable (%s): %s', logDbPath, error?.message ?? error)
      }
      return false
    }
  }

  // 首次全量按批跑：每批 4 个会话，中间让出事件循环，启动时不会长时间卡住 HTTP。
  const startFullLoad = () => {
    if (fullLoadRunning || fullLoadDone || disposed) return
    fullLoadRunning = true
    const startedAt = Date.now()
    let messages = 0
    let restoredCursors = 0
    const pending = logSessions.slice()
    const step = () => {
      if (disposed) {
        fullLoadRunning = false
        return
      }
      const batch = pending.splice(0, LOG_FULL_LOAD_CHUNK)
      for (const session of batch) {
        if (loadedSessions.has(session.id)) continue
        messages += loadWindow(session)
      }
      if (pending.length) {
        // DB 在批量加载中掉线：停下，等 pollLog 重连后重跑。
        if (!logStatements) {
          fullLoadRunning = false
          return
        }
        setImmediate(step)
        return
      }
      if (!logStatements) {
        fullLoadRunning = false
        return
      }
      for (const session of logSessions) {
        if (loadedSessions.has(session.id) && (persistedCursors.get(session.id) ?? 0) < (logCursors.get(session.id) ?? 0)) {
          restoredCursors += 1
        }
      }
      fullLoadDone = true
      fullLoadRunning = false
      logger.info(
        'log projection loaded: %d sessions, %d messages, %d conversations in %dms (%d sessions advanced while down)',
        loadedSessions.size, messages, conversations.size, Date.now() - startedAt, restoredCursors
      )
    }
    step()
  }

  const pollLog = async () => {
    if (tickBusy || disposed) return
    tickBusy = true
    try {
      if (!(await openLogDb())) return
      try {
        refreshSessions()
      } catch (error) {
        dbFailure('sessions', error)
        return
      }
      // 全量还没跑完（首次启动，或 DB 断开后重连）：先补历史，增量下一轮再说。
      if (!fullLoadDone) {
        startFullLoad()
        return
      }
      for (const session of logSessions) {
        if (!loadedSessions.has(session.id)) {
          loadWindow(session)
          continue
        }
        loadNew(session)
      }
    } finally {
      tickBusy = false
    }
  }

  void (async () => {
    await openLogDb()
    if (disposed) return
    try {
      refreshSessions()
    } catch (error) {
      dbFailure('sessions', error)
    }
    startFullLoad()
    pollTimer = setInterval(pollLog, LOG_POLL_MS)
    pollTimer.unref?.()
  })()

  ctx.on('dispose', () => {
    disposed = true
    clearInterval(pollTimer)
    process.removeListener('exit', flushOnExit)
    flushCapture()
    flushMediaIndex()
    try {
      logDb?.close()
    } catch {}
    logDb = null
    logStatements = null
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

  // 自托管媒体：文件名是内容 sha256 前 16 位 + 扩展名，只允许 platform-media 目录内的
  // 直接子文件。内容不可变（同一文件名永远是同一份字节），可以长缓存。
  ctx.server.get('/api/platform/media/:file', async (req, res) => {
    const raw = req.params?.file ?? ''
    let name
    try {
      name = decodeURIComponent(raw)
    } catch {
      name = raw
    }
    if (!name || name === '.' || name === '..' || name.startsWith('.') || !isMediaFile(name)) {
      res.status = 400
      res.body = 'invalid file name'
      return
    }
    const target = resolve(mediaDir, name)
    if (dirname(target) !== mediaDir) {
      res.status = 400
      res.body = 'path outside platform media'
      return
    }
    const info = await stat(target).catch(() => undefined)
    if (info === undefined || !info.isFile()) {
      res.status = 404
      res.body = 'file not found'
      return
    }
    res.status = 200
    res.headers.set('content-type', MIME[extname(name).toLowerCase()] ?? 'application/octet-stream')
    res.headers.set('cache-control', 'public, max-age=31536000, immutable')
    res.body = await readFile(target)
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
