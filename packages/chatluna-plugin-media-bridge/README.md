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
