# Transport 契约

本文件是 `lib/core/transport/` 的实现规范。改动协议行为先改这里。

## 概念

```dart
enum EndpointKind { lan, publicEndpoint, p2p }

class Endpoint {
  final EndpointKind kind;
  final Uri base;        // 形如 http://192.168.0.107:5028 或 https://bot.example.com
  final String? label;   // 用户可读名，仅 UI 用
}

/// 反序列化的错误：协议层唯一允许抛出的异常类型。
class ApiFailure implements Exception {
  final String code;      // UNAUTHORIZED / INVALID_ARGUMENT / CONFLICT / NOT_FOUND / INTERNAL / NETWORK / TIMEOUT
  final String message;
  final Map<String, Object?>? details;
  final int? status;      // HTTP 状态码；纯网络错误为 null
}
```

## 四条实现，一个入口

| 实现 | 方法 | 说明 |
|---|---|---|
| `RestTransport` | `getJson`, `postJson`, `deleteJson` | 统一加 `Authorization: Bearer`；POST 可带幂等键 |
| `SseTransport` | `open(path, {headers})` → `Stream<SseEvent>` | 解析 `event:` / `id:` / `data:`；忽略 `: ping` 注释；暴露 `lastEventId` |
| `ActionTransport` | `call(name, input)` → `Object?` | `POST /api/action/<name>`；`204` 返回 null；`Idempotency-Key` 必带 |
| `StateSocket` | `connect(credential)` / `subscribe(key, {params, hash})` | `ws(s)://<base>/api/webui/socket`；帧协议见下 |

**规则**

1. 所有请求路径都以 `/api` 为基础拼接；`/files/:name` 是唯一例外（无鉴权、无 `/api` 前缀）。
2. `Idempotency-Key`：由调用方提供的 intent id 派生（同一 intent 重试必须复用）；未提供时由 transport 生成 UUIDv7。
3. 去重：`GET` 不自动重试；`POST` 仅在网络错误（无响应）时重试一次，且必须复用同一个键。
4. 401 只做一件事：抛 `ApiFailure(code:'UNAUTHORIZED')`，由上层决定擦除凭证与重新认证；**不得**在 transport 内自动登录。
5. 超时：REST 15 s；SSE 首帧 20 s、空闲靠 15 s 心跳判定；断线重连指数退避 1→2→4→8 s，上限 30 s。
6. SSE 续传：保存最后收到的 `id`，重连时带 `Last-Event-ID` 头；服务端回 `truncated` 时**丢弃本地增量、重取全量**。

## WS 帧协议

```
上行  {type:'auth', credential}                 // credential = login 得到的 session 或实例 token
      {type:'sub', id, key, params?, hash?}     // id 由客户端生成，字符串
      {type:'unsub', id}
      {type:'ping'}
下行  {type:'entry:init', body:{version, entries, full}}
      {type:'state', id, value, hash, error?}
      {type:'same', id}                          // sub 带 hash 且命中
      {type:'append', id, items}
      {type:'pong'}
      {type:'unauthorized'}
```

- 未 `auth` 前只收 `entry:init`；收到 `unauthorized` 即清空所有订阅并进入认证流程。
- `state.value == null` 表示源不存在或 getter 抛错，UI 渲染空态而不是错误页。
- 应用层心跳 25 s 一次 `ping`；连续 2 次无 `pong` 视为断线。

## 端点清单（唯一权威副本）

见 `capability-map.md`。任何新增路径先加进那张表，再写代码。
