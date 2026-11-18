# chatluna-plugin-media-bridge

ChatLuna v2（Cordis 4）单文件插件，提供两件事：

1. 把实例 agent 工作区里的文件通过**带鉴权**的 HTTP 路由暴露给客户端（移动端消息里的图片）；
2. 作为 App 的**唯一消息源**：普通消息从 ChatLuna 会话日志投影，指令/未进日志的消息由事件层
   捕获补齐，两路合并、去重后从 `/api/platform/*` 输出。

移动端会话里图片的 src 是工作区相对路径（如 `medialuna/angela_cloak.png`），默认没有任何 HTTP 出口，
本插件补上这一层：

```
GET /api/workspace?path=medialuna/angela_cloak.png
Authorization: Bearer <实例 token 或登录 session>
```

- 只读；路径解析后必须落在 `data/chatluna/agents-work` 内，`../` 一律 400。
- 文件不存在 → 404；未带凭证 → 401（`/api` 前缀由 `@chatluna/server` 的守卫统一拦截）。
- 响应带 `cache-control: public, max-age=3600` 与常见图片/音视频 MIME。

## 数据源（会话日志 vs 事件捕获）

平台消息有两个来源，插件把它们合并成同一条时间线，App 不需要知道消息是从哪一路来的：

| 来源 | 覆盖的消息 | 生命周期 |
|---|---|---|
| **会话日志投影** | 进过 agent 的普通消息（用户发言、bot 回复，含多段回复里的每一段） | 每次都从 DB 重读，重启不丢 |
| **事件捕获** | 指令与指令回复、群里没 @bot 的消息、主动推送等「不进日志」的消息 | 只把增量落盘（`platform-capture.json`） |

### 会话日志

只读打开 `data/chatluna.db`（Node 24 内置 `node:sqlite`，`CHATLUNA_DB` 可覆盖）：

- `chatluna_sessions`：`conversationKey` 就是 App 的会话键（与捕获侧 `session.conversation.key`
  同一套标识）。按 `lastActiveAt` 取前 200 个会话，每会话读最近 300 条 `message` 条目。
  只投影平台会话：`origin` 为 `web` / `subagent` 的会话（WebUI 调试、子 agent）不进入列表。
- `chatluna_session_entry`（`kind='message'`）的 `payloadJson` 解析成消息：
  - `role='user'` → `dir='in'`。只认 `envelope` 块（`kind='message'`）：一个 envelope 就是一条
    平台消息，`externalId` 就是平台消息 id。同一轮里折叠进来的记忆/状态块（纯 `text`）不算发言。
  - `role='assistant'` → `dir='out'`。正文取 `text` 块（没有时取 `reply` 工具的 `input.content`），
    按 `<message>…</message>` 分条：一段就是一条平台消息，`<status/>`、`<silence/>`、
    `<thinking>` 等元信息剥掉；空段（`<silence/>`）不生成消息。
  - `time` 用条目时间（分条回复按段 +1ms 递增，保持顺序）；`id` 用日志里的消息 id +
    段序号（`msg-xxxx:2`），没有 id 时用 `<sessionId>:<n>:<段>`。
  - 媒体：`<message>` 段里的 `<img src="medialuna/x.png"/>` 换成工作区相对路径（客户端按
    `/api/workspace` 取图），`[图片]` 之类占位与捕获侧一致；用户发图的 `file` 块拿不到可访问
    地址时给 `ref`（`storage://…`），客户端按占位处理。
- 增量：每 1.5s 轮询每会话 `n > 游标` 的条目，新条目立刻走实时流；首次启动按会话窗口全量
  加载（每批 4 个会话，`setImmediate` 让出事件循环，启动时不阻塞 HTTP，实测 ~500ms 完成
  23 个会话 / 2027 条消息）。

### 事件捕获

`ctx.on('message')` 记入站，`before-send` + `send` 记出站（正文只能在 `before-send` 拿到，
平台消息 id 只有 `send` 有）。这条路径覆盖日志里没有的消息：

- 指令（如 `chatluna 菜单`）在指令层就被消费，不落会话日志，但会出现在 `message` 事件里；
- 指令回复走 `session.send`，只到平台，不进 agent 日志；
- 群里没 @bot 的消息不唤醒 agent，所以也不落日志。

### 合并与去重

- 会话键归一：去掉 `route:` 前缀、截掉 `:user:` / `:lane:` 之后的段（与 App 的
  `normalizeConversationKey` 同一规则），日志侧 `conversationKey` 与捕获侧
  `session.conversation.key` 归一后相等才进同一个会话。
- 同一句话的两个视角只留一条：平台消息 id 相同（捕获的 `messageId` = 日志 envelope 的
  `externalId`），或正文压空白后相同且 `|Δt| ≤ 3s`（正文完全相同、只是时间戳隔着多段回复的
  发送时间时放宽到 10s）。比对正文时忽略 markdown 标记（`**`、`` ` ``、`~`）。
- 日志优先：命中后保留日志的正文与时间，捕获副本丢弃；**id 与媒体取自捕获副本**——它已经
  作为实时帧发给 App 了，换 id 会让客户端当成两条，而平台图片地址只有捕获侧拿得到。
  合并后不再补推一帧，App 上同一条消息只出现一次。
- 捕获侧内部的重复上报（多 bot 实例、适配器重试）仍按「同正文 + 500ms」合并。

### 持久化

- 只落盘**捕获增量**与每会话 `lastSeenN` 游标：`data/chatluna/platform-capture.json`
  （原子写 `tmp + rename`、1s 防抖、`dispose` 与进程 `exit` 前各刷一次）。
- 文件里还带会话展示信息（群名/昵称/头像），重启后日志会话直接复用，不会退化成「群聊 · 尾号」。
- 体积上限 5MB：超了先丢最旧的捕获消息，再丢最旧的空会话元信息。
- **日志部分不落盘**：重启后从 DB 重读窗口，所以重启前后的会话条数、每条消息的
  id/time/正文/媒体完全一致（实测窗口 300 条 diff = 0）。



## 平台消息（`GET /api/platform/conversations`）

上面两路来源合并后按会话分组，App 只消费下面三个接口（形状与以前一致）。

会话列表按最后一条消息时间倒序：

```
GET /api/platform/conversations
Authorization: Bearer <实例 token 或登录 session>

{"items":[{
  "key":"r-1a2b3c4d5e6f","platform":"qq","selfId":"...",
  "channelId":"...","guildId":"..."|null,"kind":"group"|"private",
  "title":"明日方舟交流群","avatar":"https://..."|null,"count":12,
  "last":{"id":"...","time":1795...,"dir":"in","userId":"...",
          "userName":"群昵称小明","avatar":"https://..."|null,"text":"..."}
}]}
```

- `key` 是归一后的会话键：优先 `session.conversation.key`（群聊形如 `r-1a2b3c4d5e6f`，
  个人/泳道配置会带 `:user:` / `:lane:` 后缀），取不到时退回 `channelId`；日志侧用
  `chatluna_sessions.conversationKey`，两边归一后同键。与 ChatLuna App 会话 id 同一套标识，
  不要用标题里的 `A1338876…`（那是 ChatLuna 会话 id，不是平台 `C…` 频道 id）。
- `kind`：`guildId` 非空且 `guildId === channelId` → `group`，否则 `private`
  （QQ 群消息的 `guildId` 与 `channelId` 相同，私聊没有 `guildId`）。日志侧由
  `chatluna_conversations.identity`（`isDirect` / `guildId` / `channelId`）或 `peer` 推出同一结果。
- `title`：群聊优先 `session.event.guild.name`（缺失再试 `channel.name`、`bot.getGuild`、
  `chatluna_peers` 里的群名），私聊优先对方昵称（`user.name` / `member.name` / `chatluna_peers`）；
  都拿不到才退回 `群聊/私聊 · ` + 频道 id 尾 6 位（频道 id 缺失用会话键尾 6 位）。
  日志侧还复用落盘文件里的会话展示信息，重启后不会退化成尾号。
- 名称会做编码修复：UTF-8 字节被按 latin1 解出的乱码先 `latin1 → utf8` 还原；
  仍带控制字符/Latin 扩展字符的 `<...>` 片段（如 `<$ǿĀD\u000e>`）直接剥掉。
  `title`、`userName`、群名、昵称都走这一步，`avatar` 不受影响。
- `avatar`：群聊取群头像（`guild.avatar`，事件没带时调 `bot.getGuild` 取 `icon`）；
  私聊取对方头像；拿不到为 `null`。**不回退 bot 自己的头像**。
  查询结果（含「没有头像」）都进缓存，同一个群不会再重复请求。
  QQ 群（`group_openid`）的群信息里没有头像字段，所以这些群的 `avatar` 一直是 `null`。
- `count` 是当前缓冲里该会话的条数（上限 300，不是历史总数）。
- `last` 是最新一条消息的摘要，字段与消息条目一致（`text` 即 `content`，不含 `media`）。

## 消息分页（`GET /api/platform/messages`）

```
GET /api/platform/messages?key=r-1a2b3c4d5e6f&limit=50&before=1795...
Authorization: Bearer <实例 token 或登录 session>

{"items":[{"id","time","dir","userId","userName","avatar","content","media":[]}],"hasMore":true}
```

- **时间升序**（旧 → 新），直接追加到列表尾部即可。
- `limit` 默认 50（1–200），取该范围内**最新**的一页。
- `before=<毫秒时间戳>` 取比它更早的一页；把本页第一条的 `time` 传回来即可继续往前翻。
- `hasMore` 表示还有更早的消息；`before` 翻到头后为 `false`。
- `key` 缺失 → 400；会话不存在或已被淘汰 → 200 + 空 `items`（客户端按空态处理即可）。
- `dir`：`in` 是收到的消息，`out` 是 bot 自己发出的回复。两路来源都按这个规则：
  日志里 `role='user'` → `in`、`role='assistant'` → `out`；捕获侧 `ctx.on('message')` → `in`、
  `ctx.on('send')` → `out`。
- `userName`：群昵称优先（`member.name` / `member.nick`），其次全局昵称
  （`user.name` / `user.nick`），都没有才用 `userId` 尾 4 位；出站消息是 bot 名
  （`session.bot.user.name`，日志侧取 `chatluna_peers` 里 `selfId` 的 bot 名，拿不到用 `selfId`）。
  `avatar` 同理（日志侧用户名/头像来自 envelope 的 `sender` 与 `chatluna_peers`），可为 `null`。
- 名称/头像按 `平台 + guildId` / `平台 + userId` 缓存：事件自带名字时直接写入缓存，
  缺失时才调 `bot.getGuild` / `bot.getUser`（1.2s 超时），之后复用；群头像即使事件带了
  群名也一定会查一次（`fetched` 标记跟结果一起缓存）。
- `content` 由 `session.elements` 翻译成可读文本（文本原样、`at` → `@尾4位`、
  `img`/`image` → `[图片]`、`face`/`emoji` → `[表情]`、`quote` → `[引用]`、
  `file`/`audio`/`video` → `[文件]`/`[语音]`/`[视频]`，其它元素忽略），压成一行后截断 500 字。
  日志侧等价做法是剥掉回复正文里的标记（`<message>`、`<markdown>`、`<status/>` 等）后压空白，
  markdown 语法（`**`、列表）保留——App 的消息气泡本身按 markdown 渲染。
- `id`：捕获侧用平台消息 id（出站拿不到时退回 `out-<selfId>:<时间>:<序号>`）；日志侧用
  `msg-…` 加段序号（`msg-abc:2`），用户消息用 envelope 里的平台 id（`externalId`）。
  客户端按 `id` 去重即可，两条来源同一句话合并后只保留先发出去的那个 id。
- 原始平台 content 里残留的标记也会归一：QQ 卡片/附件标记
  `<attachmentType="image/jpeg",...>` 按 MIME 映射为 `[图片]` / `[视频]` / `[语音]` / `[文件]`，
  其余附件类型 → `[附件]`；`at` → `@名字（或 id 尾 4 位）`、`face`/`emoji` → `[表情]`、
  `img`/`image` → `[图片]`、`quote` → `[引用]`，无法识别的 `<...>` 标签直接剥掉。
  归一后再压空白、截断。

### 媒体（`media`）

`content` 只是给人看的占位；能渲染的东西在 `media` 里（没有就是 `[]`，最多 8 条）：

```json
"media": [
  {"kind":"image","url":"https://gchat.qpic.cn/gchatpic_new/0/0-1234/0?term=2","mime":"image/jpeg"},
  {"kind":"image","url":"https://multimedia.nt.qq.com.cn/download?appid=1&fileid=x"},
  {"kind":"file","url":"medialuna/a.zip","name":"a.zip","mime":"application/zip","size":2048},
  {"kind":"file","ref":"FILE_ID_MISSING"}
]
```

- `kind`：`image` | `video` | `audio` | `file`。由元素类型与 MIME 共同决定：
  `img`/`image`/`mface`/`sticker` 与 `image/*` 是 `image`，`video/*` 是 `video`，
  `audio`/`voice`/`record` 与 `audio/*`（QQ 的 `voice`）是 `audio`，其余是 `file`。
- `url`：客户端可直接加载的地址。`http(s)://` 原样；QQ 附件常见的 `//host/path`
  补成 `https://`；`base64://`、`data:` 原样；工作区相对路径（`medialuna/x.png`）原样，
  客户端按既有约定走 `/api/workspace`。`url` 与 `ref` 至少给一个。
- `ref`：换不到可访问地址时原样给的原始值（`file:///...`、裸文件 id）。先试
  `bot.internal.getFile` → `bot.getFile` → `bot.internal.getFileUrl`（每个 1.2s 超时，
  结果含失败缓存 60s）；`file://` 落在工作区内时直接换成工作区相对路径，不用问平台。
- `name` / `mime` / `size`：有才给；`size` 是字节数。
- 来源依次是 `session.elements`、`session.event.message`（`elements`、QQ 原始
  `attachments` 数组的 `content_type`/`url`/`filename`/`size`、`content` 标记串）、
  最后是 `session.content` 标记串；同一个 URL/`ref` 只留一条。
- 单条消息换地址总预算 3s：超出的引用直接给 `ref`，不拖慢入站事件。
- 出站消息的 `media` 来自 `before-send` 的快照（`send` 的 session 没有 elements）；日志侧
  从回复正文里的 `<img src="medialuna/x.png"/>` 取下工作区相对路径，合并时若捕获副本有
  平台图片地址则用它（日志那份只有路径）。
- 用户发图的日志侧来源是 envelope 的 `file` 块（`mediaType` + `storage://…` 引用）：能给出
  `kind`/`mime`，地址拿不到时给 `ref`，客户端显示占位。
- `last` 摘要只有 `text`，不含 `media`。

### 出站（`dir: "out"`）

出站消息两条来源都会给：日志侧的 assistant 条目（重启后仍在）与适配器的 `send` 事件（带平台
消息 id 与图片地址）。同一句话合并成一条，正文/时间取日志、id/媒体取捕获。

适配器的 `send` 事件（`ctx.on('send')`）在消息真正落到平台之后才发，带真实消息 id（`id` 就是它），
但传进来的 session 是新造的 `bot.session()`，**没有** `elements`。正文只能在 `before-send`
（`MessageEncoder` 渲染前）那一刻拿到，所以：

- `ctx.on('before-send')` 只把「这个频道最近要发什么」（正文、会话键）存成快照，2s 过期；
- `ctx.on('send')` 才落一条 `dir: "out"` 的消息，正文取自快照，`id` 取平台消息 id
  （平台不给 id 时退回 `out-<selfId>:<时间>:<序号>`，客户端靠 `id` 去重）。
- 快照过期/缺失（例如有代码绕过 `MessageEncoder` 直接调 `bot.internal`）时**不写**消息：
  正文不可知，写空正文只会污染列表。
- 去重：同一条出站可能被多个 bot 实例/适配器各上报一次，一次回复也可能被拆成多段 flush；同一个
  `channelId` + 同样的正文在 500ms 内只记一条（去重键不含 `selfId`）。
- 出站消息的 `userId` 是 bot 自己（`selfId`）：`send` 的 session 不带 user。
- 会话键**优先沿用该频道最近一条入站消息的值**：`send` 的 session 没复制 `isDirect` 这类访问器，
  私聊会被算成「频道」路由（少了 `:user:`）。回复总是发回它来的那个频道，所以这样取才是同一个会话；
  该频道还没有入站记录（主动推送）时才退回 `before-send` / `send` 自己算出的键。
- 只记录，不回灌 `message` 事件，所以不会形成「自己发的消息被当成入站」的回环。
- 该路径依赖适配器走 Satori 的 `MessageEncoder`（QQ 适配器会发 `before-send` / `send`）。
  `@chatluna/adapter-web` 直接覆写 `sendMessage` 返回消息 id，既不发 `before-send` 也不发
  `send`，因此 web 平台的出站消息不会出现在本接口里；App 的会话只读，不受影响。

## 实时流（`GET /api/platform/stream`）

Server-Sent Events 出口，App 保持长连接即可实时拿到入站与出站消息：

```
curl -N -H "Authorization: Bearer <实例 token 或登录 session>" \
  http://127.0.0.1:5028/api/platform/stream
```

- 连接建立后先按时间顺序回放**每个会话最近 5 条**（旧 → 新），之后实时推。
- 帧格式：`event: platform`，`data` 是单条 JSON：

```json
{"key":"r-1a2b3c4d5e6f","message":{"id":"...","time":1795...,"dir":"in","userId":"...","content":"看图 [图片]","media":[{"kind":"image","url":"https://gchat.qpic.cn/..."}]}}
```

- 客户端按 `message.id` 去重（回放 + 重连会重复拿到同一批）。
- 每 15s 一行 `: ping` 注释保活；响应带 `x-accel-buffering: no`，代理不会缓冲首帧。
- 客户端断开或 `close` 时服务端移除订阅者；未带凭证 → 401（同上，`/api` 守卫）。
- 实现复用 `@chatluna/server`（实例 `node_modules` 里）的 `openStream`：头、flushHeaders、
  心跳、close 清理都由它负责，本插件只维护订阅者集合。

## 存储

- 每个会话一个独立环形缓冲，cap 300 条；时间戳回退时按升序插入，接口永远返回升序。
- 会话表 cap 200，超出时淘汰「最后一条消息时间最早」的会话（它的捕获增量仍在落盘文件里）。
- 日志投影的部分不落盘（重启从 DB 重读）；捕获增量与游标落盘在
  `data/chatluna/platform-capture.json`，详见上面「数据源」的持久化小节。
- DB 打不开（文件缺失/被独占）时只降级为捕获路径，每 30s 重试一次；恢复后自动补一次全量。

## 安装

1. 拷到实例：`/root/chatluna/external/workspace-files/index.mjs`
2. 在 `chatluna.yml` 的**非隔离**组（如 `platforms`）加一条：

```yaml
    - id: workspace-files
      name: file:///root/chatluna/external/workspace-files/index.mjs
```

不要放进 `extensions` 组：该组 `isolate: {server: chatluna}`，插件拿到的是另一个 server 实例，路由不会生效。

运行在 Node 24+（`node:sqlite` 是内置模块，不需要额外依赖）。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CHATLUNA_WORKSPACE` | `<cwd>/data/chatluna/agents-work` | 工作区根目录 |
| `CHATLUNA_DB` | `<cwd>/data/chatluna.db` | ChatLuna 会话日志（只读） |
| `CHATLUNA_PLATFORM_CAPTURE` | `<cwd>/data/chatluna/platform-capture.json` | 捕获增量与游标 |

## 后续

上传（客户端发图）、短时签名 URL、缩略图生成会加在同一个插件里，路由保持在 `/api/workspace*`。
