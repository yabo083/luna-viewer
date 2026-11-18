# chatluna-plugin-media-bridge

ChatLuna v2（Cordis 4）单文件插件：把实例 agent 工作区里的文件通过**带鉴权**的 HTTP 路由暴露给客户端。

移动端会话里图片的 src 是工作区相对路径（如 `medialuna/angela_cloak.png`），默认没有任何 HTTP 出口，
本插件补上这一层：

```
GET /api/workspace?path=medialuna/angela_cloak.png
Authorization: Bearer <实例 token 或登录 session>
```

- 只读；路径解析后必须落在 `data/chatluna/agents-work` 内，`../` 一律 400。
- 文件不存在 → 404；未带凭证 → 401（`/api` 前缀由 `@chatluna/server` 的守卫统一拦截）。
- 响应带 `cache-control: public, max-age=3600` 与常见图片/音视频 MIME。

## 消息记录（`GET /api/traffic`）

纯指令消息（如 `chatluna-菜单`）在 Koishi 的指令层就被消费，既不落会话日志也不加载 agent；
bot 借框架之口发的回复（`session.send`，指令回复就是这条路）同样只发到平台、不进 agent 日志。
客户端两边都看不到，所以插件在事件层抄一份到 500 条的内存环形缓冲，供 App 的「消息记录」页查看：

```
GET /api/traffic?limit=50&platform=qq&channelId=C3A7...
Authorization: Bearer <实例 token 或登录 session>

{"items":[{"id","dir","time","platform","selfId","userId","channelId","guildId","content","conversationKey","routeId"}]}
```

- 新 → 旧；`limit` 默认 50（1–200），`platform` / `channelId` 空串表示不过滤。
- `dir`：`in` 是收到的消息（`ctx.on('message')`），`out` 是 bot 自己发出的回复。
- `conversationKey` 是 ChatLuna 的 `session.conversation.key`（群聊形如 `r-1a2b3c4d5e6f`，
  个人/泳道配置会带 `:user:` / `:lane:` 后缀），`routeId` 是同一路由的 id；会话标题里那种
  `A1338876…` 与 `channelId`/`guildId` 的 `C…` 不是同一命名空间，**客户端匹配会话要用
  `conversationKey`（或 `routeId`），不要用标题 id 对 `channelId`**。
- 降级：`session.conversation` 由 chat 插件惰性挂在 Session 原型上且依赖 `routing` 服务，
  取不到时 `conversationKey` 退回 `channelId`（两者都没有才是 `null`）；运行环境没有
  `@chatluna/satori` 时条目里不出现 `routeId` 键。此时客户端只能退回标题 id 匹配。
- `time` 是毫秒时间戳；`content` 由 `session.elements` 翻译成可读文本（文本原样、`at` → `@尾4位`、
  `img`/`image` → `[图片]`、`face`/`emoji` → `[表情]`、`quote` → `[引用]`、`file`/`audio`/`video` →
  `[文件]`/`[语音]`/`[视频]`，其它元素忽略），压成一行后截断 500 字。
- 只在内存里，重启实例清空；未带凭证 → 401（同上，`/api` 守卫）。

### 出站（`dir: "out"`）

适配器的 `send` 事件（`ctx.on('send')`）在消息真正落到平台之后才发，带真实消息 id（`id` 就是它），
但它传进来的 session 是新造的 `bot.session()`，**没有** `elements`（`@satorijs/adapter-qq` 的
flush 里 `decodeMessage` 那一行还是注释掉的）。正文只能在 `before-send`（`MessageEncoder` 渲染前）
那一刻拿到，所以：

- `ctx.on('before-send')` 只把「这个频道最近要发什么」（正文、`conversationKey`）存成快照，2s 过期；
- `ctx.on('send')` 才落一条 `dir: "out"` 的条目，正文取自快照，`id` 取平台消息 id
  （平台不给 id 时退回 `out-<selfId>:<时间>:<序号>`，客户端靠 `id` 去重）。
- 快照过期/缺失（例如有代码绕过 `MessageEncoder` 直接调 `bot.internal`）时**不写**条目：正文不可知，
  写空正文只会污染「消息记录」。
- 去重：同一条出站可能被多个 bot 实例/适配器各上报一次，一次回复也可能被拆成多段 flush；同一个
  `channelId` + 同样的正文在 500ms 内只记一条（去重键不含 `selfId`）。
- 出站条目的 `userId` 是 bot 自己（`selfId`）：`send` 的 session 不带 user。
- `conversationKey` / `routeId` **沿用该频道最近一条入站消息的值**：`send` 的 session 是
  `bot.session()` 新造的，`isDirect` 这类挂在 Session 原型上的访问器没被复制过去，私聊会被算成
  「频道」路由（少了 `:user:`），和 App 看到的会话 id 对不上。回复总是发回它来的那个频道，所以
  这样取才是同一个会话；该频道还没有入站记录（主动推送）时才退回 `before-send` 时算出的键。
- 只记录，不回灌 `message` 事件，所以不会形成「自己发的消息被当成入站」的回环。

## 消息推送（`GET /api/traffic/stream`）

同一份环形缓冲的 Server-Sent Events 出口，App 会话页保持长连接即可实时看到入站与出站消息
（包括纯指令消息与 bot 的回复）：

```
curl -N -H "Authorization: Bearer <实例 token 或登录 session>" \
  http://127.0.0.1:5028/api/traffic/stream
```

- 连接建立后先补最近 20 条（旧 → 新，客户端按序追加），字段与 `/api/traffic` 的 `items` 完全一致。
- 之后每条新入站消息推一帧：`event: traffic`，`data` 是单条 JSON（无 `items` 包装）。
- 每 15s 一行 `: ping` 注释保活；响应带 `x-accel-buffering: no`，代理不会缓冲首帧。
- 客户端断开或 `close` 时服务端移除订阅者；未带凭证 → 401（同上，`/api` 守卫）。
- 实现复用 `@chatluna/server`（实例 `node_modules` 里）的 `openStream`：头、flushHeaders、
  心跳、close 清理都由它负责，本插件只维护订阅者集合。

## 安装

1. 拷到实例：`/root/chatluna/external/chatluna-plugin-media-bridge/index.mjs`
2. 在 `chatluna.yml` 的**非隔离**组（如 `platforms`）加一条：

```yaml
    - id: media-bridge
      name: file:///root/chatluna/external/chatluna-plugin-media-bridge/index.mjs
```

不要放进 `extensions` 组：该组 `isolate: {server: chatluna}`，插件拿到的是另一个 server 实例，路由不会生效。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CHATLUNA_WORKSPACE` | `<cwd>/data/chatluna/agents-work` | 工作区根目录 |

## 后续

上传（客户端发图）、短时签名 URL、缩略图生成会加在同一个插件里，路由保持在 `/api/workspace*`。
