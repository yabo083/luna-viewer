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

纯指令消息（如 `chatluna-菜单`）在 Koishi 的指令层就被消费，既不落会话日志也不加载 agent，
客户端完全看不到。插件在 `ctx.on('message')`（指令匹配之前）抄一份入站消息到 500 条的
内存环形缓冲，供 App 的「消息记录」页查看：

```
GET /api/traffic?limit=50&platform=qq&channelId=C3A7...
Authorization: Bearer <实例 token 或登录 session>

{"items":[{"id","time","platform","selfId","userId","channelId","guildId","content"}]}
```

- 新 → 旧；`limit` 默认 50（1–200），`platform` / `channelId` 空串表示不过滤。
- `time` 是毫秒时间戳；`content` 由 `session.elements` 翻译成可读文本（文本原样、`at` → `@尾4位`、
  `img`/`image` → `[图片]`、`face`/`emoji` → `[表情]`、`quote` → `[引用]`、`file`/`audio`/`video` →
  `[文件]`/`[语音]`/`[视频]`，其它元素忽略），压成一行后截断 500 字。
- 只在内存里，重启实例清空；未带凭证 → 401（同上，`/api` 守卫）。

## 消息推送（`GET /api/traffic/stream`）

同一份环形缓冲的 Server-Sent Events 出口，App 会话页保持长连接即可实时看到入站消息
（包括纯指令消息）：

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
