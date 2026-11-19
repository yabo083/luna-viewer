# 对抗性审查修复记录

对应 `docs/adversarial-review.md`（18 条：P0×1 / P1×4 / P2×13）。
本轮只改 `lib/**` 与新增本文件；未改既有测试断言，未连接手机，未构建/安装 APK，未引入新依赖。

## 验证结果

```text
flutter analyze  →  No issues found!
flutter test     →  All tests passed!  (+125)
```

- 原有 71 条用例保持全绿。
- 三份对抗性用例共 54 条全绿，其中 16 条带「待修」的用例全部转绿
  （`adversarial_transport_test.dart` 10 条、`adversarial_state_test.dart` 4 条、
  `adversarial_media_auth_test.dart` 2 条）。
- 对照组（`/files` 带 Bearer、platform media 外链不带）保持全绿。

## P0-1 正文 markdown 图片泄露实例 Bearer

修法：把「是否带凭证」收敛成唯一判定，所有取图路径都经过它。

- `lib/features/chat/message_view.dart`
  - `_needsAuth` 现在要求 **scheme + host + port 全部与实例一致**，且路径属于
    `/files/`、`/api/workspace` 或 `/api/platform/media`。外链、外部图床、同 host:port
    但换 scheme 的明文地址都不带 Bearer。
  - `_Markdown` 的 `ImgConfig` 不再把原始 headers 直接交给图片组件，改为传 `base`；
    `_ChatImage` 在每次解析出最终 URI 后调用 `_authHeadersFor` / `_needsAuth` 重算一次，
    `_measure` 与 `_RetryableImage` 使用的是同一份过滤后的头（双保险，外部无法注入原始头）。
  - 平台媒体路径继续走 `_authHeadersFor` / `_ImageSource.of`，与正文图片规则完全一致。
- 有效规则一句话：**仅本实例同源的 `/files`、`/api/workspace`、`/api/platform/media`
  带 Bearer，其余一律空头。**

## P1-1 半死 SSE 自愈

- `lib/core/transport/api_client.dart`
  - SSE 行流加 20s 空闲判死（任何一行都算活，包括 `: ping` 注释心跳；契约允许首帧
    20s、心跳 15s），超时抛 `ApiFailure('TIMEOUT', 'SSE 空闲超时')`，交给调用方既有退避路径。
  - 错误响应体读取加 1.5s 超时（测试要求在 2s 内拿到 `ApiFailure`；错误页很小，
    1.5s 足够）。原先 `bytesToString()` 无超时会让 `sse()` 永久挂起。
  - 401/403 不再等错误体，直接抛 `UNAUTHORIZED` / `FORBIDDEN`。
- `/api/platform/stream`：沿用 1→2→4→8→16→30s 退避；`_open()` 先取消旧订阅，
  `_scheduleRetry` 单飞，不会双订阅。
- `/live`：保留 8s 首 snapshot 看门狗，另加「每帧重置」的 20s 空闲判死；
  判死后 `_liveDown()` 取消旧订阅、9s 后重连，`_startLive` 有启动闸门与最小重连间隔。
- `/events`：20s 空闲判死 + 1→2→4→8→30s 退避；空闲判死先 cancel 再走同一退避，
  `_eventsStarted` / `_eventsSub` / `_eventsRetry` 三者互斥，重建不会叠出第二条。

## P1-2 401 收敛与提示

- 传输层：401 立即以 `ApiFailure.isUnauthorized` 结束，不再被错误体超时拖成网络错误。
- `PlatformStream`：401 时停止退避、关闭流，把错误送给订阅方；其余错误才重试。
- `ChatPage`：轮询、探测、`/live`、`/events`、平台流、加载、框架块、取消/压缩/分叉/
  重发全部识别 401 → `_handleAuthFailure()` 停掉所有后台表与流，弹出「登录已失效」，
  操作按钮为「重新连接」（退回列表并由根节点清凭证）。
- `SessionsPage`：生命周期内同样识别 401 → 停表/停流并弹出「重新连接」。
- 所有新文案都是固定短句，不含 token、请求头或服务端原始 HTML。

## P1-3 字段类型漂移

- `SessionsRepository` / `PlatformRepository`：解析期异常统一收敛为
  `ApiFailure('INTERNAL', '<对象>返回体字段异常')`，不再以 `TypeError` 逃出轮询/同步循环。
  - 与用例断言一致：`running:1`、`createdAt` 为 ISO 串、`items` 非数组、`count:"12"`、
    块 `type` 非字符串都会得到一个受控 `ApiFailure`，而不是未捕获异常。
  - 展示/身份字段（`id`/`title`/`origin`/`engine`/`role`/`form`）做类型容错；
    内容字段（块 `text`、`media`、时间、`settled.reason`）降级而不是抛错。
- `hasMore` 接受 `true/1/"true"/"1"/"yes"`。
- `/events` 的实现按帧 `try/catch`，单帧坏形状只丢该帧。
- 页面层所有 `catch (ApiFailure)` 旁补齐 `catch (Object)`：单拍失败不逃进 Zone。

## P1-4 正文 `<...>` 被误删

- `ChatMessage._bodyMarkdown` 不再用「任意 `<...>`」正则。
- 只剥白名单标签（HTML 常见标签 + `message/status/turn/mood/bond/state`），
  且属性必须是 `name=value` 形态；`a<b && c>d`、`vector<int>`、`<T>` 原样保留，
  `<div>` / `<br>`（保留换行标签）等仍按原行为处理。
- `PlatformMessage.view` 与 `ChatMessage` 共用同一实现；平台消息不再被改写。

## P2（本轮已修）

| 条目 | 状态与要点 |
|---|---|
| P2-1 帧 id 复用 | 已修：有 `n` 时优先 `sessionId:n`，`sse.id` 只做续传兜底 |
| P2-2 mark time 字符串 | 已修：数字毫秒 / 数字字符串 / ISO 都接受，解析失败为 null |
| P2-3 `truncated` 未消费 | 已修：清空游标、前移重放基准，300ms 合并后 `_loadFramework(force:true)` |
| P2-4 `text` 非字符串 | 已修：`ChatBlock.text` 仅接受字符串，其余降级为 null |
| P2-5 ISO 时间时区 | 已修：解析后统一 `.toLocal()` |
| P2-6 翻页游标被旧消息带偏 | 已修：新增 `_earliest`「已确认连续最早时间」，不再用数组首元素 |
| P2-7 无界缓存 | 部分修：`_itemCache` 改 200 条 LRU、离开页面清空；`_messages` 未加裁剪（避免把用户正在回看的历史裁掉） |
| P2-8 列表页后台流 | 已修：`WidgetsBindingObserver`，paused 断流、resumed 重建 |
| P2-9 链接 scheme | 已修：只放行 http/https；其余复制链接并提示；`Uri.tryParse` 失败不抛 |
| P2-10 重载清游标 | 已修：force 重载同时重置 `_eventsOpenedAt` |
| P2-11 auth 缺 scheme | 已修：`_needsAuth` 增加 scheme 比较 |
| P2-12 iOS 钥匙串 | 已修：去掉 `userPresence`，保留 `first_unlock_this_device` |
| P2-13 杂项 | 页内重复 id 去重、错误页正文不进 UI、SSE 单帧 4MB 上限、固定 UTF-8 解码、主题切换重连节流、`settled.reason` 容错、404 显示「附件已过期」并停自动重试 |
| P2-13 剩余 | 轮询仍只查 `/api/sessions` 第一页（接口无按 id 查询，留待协议侧）；`_messages` 裁剪未做 |

## 说明

- 类型漂移用例的断言是「抛 `ApiFailure`」而不是「静默跳过坏行」。因此本轮把行级
  形状错误收敛为一个受控 `ApiFailure`（页面显示一次错误，而不是 TypeError 逃逸），
  内容级字段仍按容错降级处理；这与报告建议中的「容错或转成 ApiFailure」一致。
- 未修改任何对抗性用例的断言；未触碰 `docs/` 中既有报告的原文（仅在末尾追加状态）。
