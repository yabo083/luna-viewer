# chatluna-plugin-media-bridge

ChatLuna v2（Cordis 4）单文件插件，提供两件事：

1. 把实例 agent 工作区里的文件通过**带鉴权**的 HTTP 路由暴露给客户端（移动端消息里的图片）；
2. 在事件层按会话记录**入站 + 出站平台消息**，作为 App 的唯一消息源。

移动端会话里图片的 src 是工作区相对路径（如 `medialuna/angela_cloak.png`），默认没有任何 HTTP 出口，
本插件补上这一层：

```
GET /api/workspace?path=medialuna/angela_cloak.png
Authorization: Bearer <实例 token 或登录 session>
```

- 只读；路径解析后必须落在 `data/chatluna/agents-work` 内，`../` 一律 400。
- 文件不存在 → 404；未带凭证 → 401（`/api` 前缀由 `@chatluna/server` 的守卫统一拦截）。
- 响应带 `cache-control: public, max-age=3600` 与常见图片/音视频 MIME。

## 平台消息（`GET /api/platform/conversations`）

纯指令消息（如 `chatluna-菜单`）在 Koishi 的指令层就被消费，既不落会话日志也不加载 agent；
bot 借框架之口发的回复（`session.send`，指令回复就是这条路）同样只发到平台、不进 agent 日志。
App 之前靠会话日志 + 旁路流量拼消息，会重复、重组、普通消息不及时。本插件在事件层直接落一份
**按会话分组**的消息，App 只消费下面三个接口。

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
  个人/泳道配置会带 `:user:` / `:lane:` 后缀），取不到时退回 `channelId`。与 ChatLuna App
  会话 id 同一套标识，不要用标题里的 `A1338876…`（那是 ChatLuna 会话 id，不是平台 `C…` 频道 id）。
- `kind`：`guildId` 非空且 `guildId === channelId` → `group`，否则 `private`
  （QQ 群消息的 `guildId` 与 `channelId` 相同，私聊没有 `guildId`）。
- `title`：群聊优先 `session.event.guild.name`（缺失再试 `channel.name` 与
  `bot.getGuild`），私聊优先对方昵称（`user.name` / `member.name`）；
  都拿不到才退回 `群聊/私聊 · ` + 频道 id 尾 6 位（频道 id 缺失用会话键尾 6 位）。
- `avatar`：群聊取群头像（`guild.avatar`），私聊取对方头像；拿不到为 `null`。
- `count` 是当前缓冲里该会话的条数（上限 300，不是历史总数）。
- `last` 是最新一条消息的摘要，字段与消息条目一致（`text` 即 `content`）。

## 消息分页（`GET /api/platform/messages`）

```
GET /api/platform/messages?key=r-1a2b3c4d5e6f&limit=50&before=1795...
Authorization: Bearer <实例 token 或登录 session>

{"items":[{"id","time","dir","userId","userName","avatar","content"}],"hasMore":true}
```

- **时间升序**（旧 → 新），直接追加到列表尾部即可。
- `limit` 默认 50（1–200），取该范围内**最新**的一页。
- `before=<毫秒时间戳>` 取比它更早的一页；把本页第一条的 `time` 传回来即可继续往前翻。
- `hasMore` 表示还有更早的消息；`before` 翻到头后为 `false`。
- `key` 缺失 → 400；会话不存在或已被淘汰 → 200 + 空 `items`（客户端按空态处理即可）。
- `dir`：`in` 是收到的消息（`ctx.on('message')`），`out` 是 bot 自己发出的回复。
- `userName`：群昵称优先（`member.name` / `member.nick`），其次全局昵称
  （`user.name` / `user.nick`），都没有才用 `userId` 尾 4 位；出站消息是 bot 名
  （`session.bot.user.name`，拿不到用 `selfId`）。`avatar` 同理，可为 `null`。
- 名称/头像按 `平台 + guildId` / `平台 + userId` 缓存：事件自带名字时直接写入缓存，
  缺失时才调 `bot.getGuild` / `bot.getUser`（1.2s 超时），之后复用。
- `content` 由 `session.elements` 翻译成可读文本（文本原样、`at` → `@尾4位`、
  `img`/`image` → `[图片]`、`face`/`emoji` → `[表情]`、`quote` → `[引用]`、
  `file`/`audio`/`video` → `[文件]`/`[语音]`/`[视频]`，其它元素忽略），压成一行后截断 500 字。
- 原始平台 content 里残留的标记也会归一：QQ 卡片/附件标记
  `<attachmentType="image/jpeg",...>` 按 MIME 映射为 `[图片]` / `[视频]` / `[语音]` / `[文件]`，
  其余附件类型 → `[附件]`；`at` → `@名字（或 id 尾 4 位）`、`face`/`emoji` → `[表情]`、
  `img`/`image` → `[图片]`、`quote` → `[引用]`，无法识别的 `<...>` 标签直接剥掉。
  归一后再压空白、截断。

### 出站（`dir: "out"`）

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
{"key":"r-1a2b3c4d5e6f","message":{"id":"...","time":1795...,"dir":"in","userId":"...","content":"..."}}
```

- 客户端按 `message.id` 去重（回放 + 重连会重复拿到同一批）。
- 每 15s 一行 `: ping` 注释保活；响应带 `x-accel-buffering: no`，代理不会缓冲首帧。
- 客户端断开或 `close` 时服务端移除订阅者；未带凭证 → 401（同上，`/api` 守卫）。
- 实现复用 `@chatluna/server`（实例 `node_modules` 里）的 `openStream`：头、flushHeaders、
  心跳、close 清理都由它负责，本插件只维护订阅者集合。

## 存储

- 每个会话一个独立环形缓冲，cap 300 条；同一 `time` 视为同一条消息（多 bot 实例/适配器重复
  上报、SSE 重放都不会翻倍）。时间戳回退时按升序插入，接口永远返回升序。
- 会话表 cap 200，超出时淘汰「最后一条消息时间最早」的会话。
- **全部只在内存里**：实例重启后清空，App 重连后从新消息重新积累。重启前的平台消息
  没有持久化副本（会话日志只保存进过 agent 的那部分，不能当平台真源的备份）。

## 安装

1. 拷到实例：`/root/chatluna/external/workspace-files/index.mjs`
2. 在 `chatluna.yml` 的**非隔离**组（如 `platforms`）加一条：

```yaml
    - id: workspace-files
      name: file:///root/chatluna/external/workspace-files/index.mjs
```

不要放进 `extensions` 组：该组 `isolate: {server: chatluna}`，插件拿到的是另一个 server 实例，路由不会生效。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CHATLUNA_WORKSPACE` | `<cwd>/data/chatluna/agents-work` | 工作区根目录 |

## 后续

上传（客户端发图）、短时签名 URL、缩略图生成会加在同一个插件里，路由保持在 `/api/workspace*`。
