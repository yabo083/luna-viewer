# 对抗性审查：ChatLuna Mobile 客户端

审查对象：`lib/`（10033 行 Dart），按「用户可感知故障」为单位，覆盖网络 / 状态 / 数据 / 安全四类。
本文件只列**真实可触发**的问题；已核对不成立的假设单独列在末尾，避免后续重复排查。
审查期间未修改 `lib/`，未连接手机与实例；所有测试都是离线 Mock。

> 行号为审查时点（工作区 `lib/` 未改动）的源码行号。

## 结论摘要

| 级别 | 数量 | 主题 |
|---|---|---|
| P0 | 1 | 正文 markdown 图片把实例 Bearer 发给任意外部主机（远程可触发） |
| P1 | 4 | 半死 SSE 无自愈；401 后无限重试不收敛；单字段类型漂移打死列表；正文 `<...>` 被静默删除 |
| P2 | 13 | 帧 id 复用丢消息、时间/翻页/渲染容错、无界缓存、后台流、外链 scheme、钥匙串等 |

## 测试结果（如实）

命令：`flutter.bat test`（全量）
结果：**109 通过 / 16 失败**。16 条失败全部是本文的待修项，没有为让测试变绿而改 `lib/`。
其中 3 个文件为新增/改写（`docs` 外唯一改动）：

| 文件 | 通过/失败 | 覆盖 |
|---|---|---|
| `test/adversarial_transport_test.dart` | 20 / 10 | HTTP 码、SSE、坏字段、`/events` 帧、URL 编码与凭证 |
| `test/adversarial_state_test.dart` | 16 / 4 | 正文清洗、块容错、时间、时间线、归一键、长文本/媒体 |
| `test/adversarial_media_auth_test.dart` | 2 / 2 | markdown 外链 vs `/files` vs platform media 三路取图的请求头 |

失败用例名都带「待修」，逐条对应下文的 P0–P2。修复 `lib/` 后这些用例应转绿；对照组用例（`/files` 带 Bearer、platform media 外链不带）当前已通过。

---

## P0

### P0-1 正文 markdown 图片把实例 token 发给任意外部主机

- **现象**：消息正文里出现 `![](https://任意主机/…)` 时，App 立刻向该主机发起图片请求，并附带
  `Authorization: Bearer <实例 token>`。攻击者在自己服务器收到请求即拿到实例凭证。
  正文来自**平台消息**，所以群聊里任何人发一条这样的消息即可触发，不需要 bot 配合、不需要用户点击图片
  （`MessageView` 一构建就开始解析图片）。
- **触发条件**：打开一个含 markdown 图片语法的会话详情（或 bot 回复里带外链图片）。
- **位置**：
  - `lib/features/chat/message_view.dart:396-401`：`ImgConfig(builder: (url, _) => _ChatImage(..., headers: headers))`
    直接把**未过滤**的请求头交给图片组件；
  - `lib/features/chat/message_view.dart:733-735`、`:845-851`、`:924-933`：`_ChatImage` / `_RetryableImage`
    无条件使用 `widget.headers` 发起 `NetworkImage`；
  - 对照：同文件的平台媒体路径 `_authHeadersFor`（`:566-577`）与 `_MediaBlock`（`:1013-1063`）
    已经按 host/port/path 判断后才带 Bearer。
- **建议修法**：把「是否带 Bearer」收敛成唯一入口，所有取图都从 `_ImageSource.of / _authHeadersFor` 拿头：
  1. `_Markdown` 的 `ImgConfig` 改为 `headers: _authHeadersFor(base, url, headers)`（最小改动）；
  2. 防御性：`_ChatImage`/`_RetryableImage` 内部再按解析后的 URI 重算一次，禁止外部直接注入原始头；
  3. 顺带把 `_needsAuth` 的判断补上 scheme（见 P2-11）。
- **用例**：`test/adversarial_media_auth_test.dart` 前两条（红）；对照组两条（绿）。

---

## P1

### P1-1 半死 SSE：连接能建立但不再说话时，没有任何自愈

- **现象**：
  - 会话列表停止更新（新消息不再出现），下拉刷新才恢复；
  - 详情页状态灯永久停在「思考中 / 回复中」，计时读数无限增长，中止按钮看起来可点；
  - 若错误响应体卡住，连「重连」都不会发生。
- **触发条件**：手机切网 / 电梯 / 息屏后待机，TCP 连接「半死」——不 FIN、不 RST、也不再发帧；
  或反代把 502 错误页的 body 分块发出后不收尾。
- **位置**：
  - `lib/core/capability/platform_stream.dart:49-76`：只在 `onError/onDone` 时才退避；注释帧只把
    `_backoff` 复位，**没有**任何「多久没帧就判定断线」的定时器；
  - `lib/features/chat/chat_page.dart:993-999`：`/live` 的 8s 看门狗只管**首个 snapshot**，
    `_snapshotSeen` 一旦为 true 就再也不会重置（直到整条流重连）；
  - `lib/features/chat/chat_page.dart:803-855`：`/events` 同样无空闲判定；
  - `lib/core/transport/api_client.dart:134-136`：错误响应 `bytesToString()` 无超时，
    body 不收尾时 `sse()` 永久挂起（`PlatformStream` 因此连 `onError` 都收不到）。
- **契约依据**：`docs/transport.md` 第 5 条要求「SSE 首帧 20s、空闲靠 15s 心跳判定」。
- **建议修法**：
  1. `ApiClient.sse`：错误体读取加 `.timeout(const Duration(seconds: 5))`，超时按 `NETWORK` 抛；
  2. 三条流（platform / live / events）各加「最后收帧时间 + 15s 判死」的 Timer，
     每帧（含 `: ping`）重置；判死后主动 cancel 并走既有退避；
  3. `ChatPage` 的 `/live` 看门狗改为「每帧重置的空闲计时器」，不再只盯握手。
- **用例**：`adversarial_transport_test.dart` 的「错误响应的 body 永远读不完」（红，2s 内只等来超时）。

### P1-2 凭证失效（401）后不收敛：后台无限重试，且不引导重新登录

- **现象**：token 被轮换 / 设备被踢下线后，详情页永远显示「轮询中」；App 在后台仍每 2s 打一次
  `/events`、每 3s 打一次 `/api/sessions`、每 9s 重连 `/live`，直到用户手动下拉刷新列表才会回到登录页。
- **触发条件**：服务端轮换 token（`POST /api/auth/token`）或用另一台设备重新登录后继续使用旧会话。
- **位置**：
  - `lib/features/chat/chat_page.dart:774-800`：`/events` 的 `onError` 不区分错误码，
    固定 2s 后重来，无退避；
  - `lib/features/chat/chat_page.dart:1132-1160`：`_liveDown` → 9s 重连，循环；
  - `lib/features/chat/chat_page.dart:429-460`：轮询只 `catch (ApiFailure)` 后静默吞掉 401；
  - `lib/features/sessions/sessions_page.dart:266-281`、`:206-233`：列表页流的 `onError: (_) {}`、
    `_syncConversations` 同样吞掉 401，只有 `_refresh`（`:158-205`）处理 `isUnauthorized`。
- **建议修法**：在页面层引入一个「认证失效」出口（回调 / `ValueNotifier<ApiFailure?>`）：
  `onError` 先判 `ApiFailure.isUnauthorized` → 停表、停流、通知根节点清凭证回连接页；
  其余错误才走指数退避（`_restartEvents` 目前没有退避，应复用 1→2→4→8→30 的曲线）。
- **用例**：传输层「401 的 SSE 以 UNAUTHORIZED 结束」已保证错误码可达（绿），缺的是页面层的消费。

### P1-3 单个字段类型漂移打死整个列表 / 静默丢掉新会话

- **现象**：冷启动时只要任意一行会话的 `running` 是 `1`、`createdAt` 是 ISO 字符串、
  `items` 不是数组、或平台会话的 `count` 是字符串，整页变成「加载失败」；
  运行中该错误还会以未捕获的 `TypeError` 形式逃出轮询/同步函数，新会话静默不出现。
- **触发条件**：服务端/插件发版后字段类型变化（如 `running: 1`、`count: "12"`），或反代改写 JSON。
- **位置**：
  - `lib/core/model/models.dart:86-95`：`id as String`、`createdAt as num?`、`running as bool?`；
  - `lib/core/model/models.dart:156-172`：`count as num?`；
  - `lib/core/model/models.dart:456`、`:667`：块 `type as String?`；
  - `lib/core/capability/sessions_repository.dart:13-33`、`:35-48`；
  - `lib/core/capability/platform_repository.dart:30-43`、`:63`（`hasMore == true` 只认 bool）；
  - 扩散点：`lib/features/chat/chat_page.dart:451-456`（轮询只 catch ApiFailure）、
    `:712-716`（框架块只 catch ApiFailure）、`lib/features/sessions/sessions_page.dart:206-233`。
- **建议修法**：
  1. 在 `models.dart` 增加集中容错读值（`_asString/_asInt/_asBool/_asList`），解析层永不抛；
  2. 仓储层对「顶层形状错误」统一转 `ApiFailure('INTERNAL', …)`，单行坏数据跳过而不是整表失败；
  3. `hasMore` 接受 `true/1/"true"`，`_frameTime` 接受数字字符串；
  4. 页面层的 `catch (ApiFailure)` 扩成 `catch (Object)`，避免未捕获 Zone 错误。
- **用例**：传输层「仓储层」组 6 条红（`running`、`createdAt`、`items`、`count`、块 `type`、`hasMore`）。

### P1-4 普通消息里的 `<...>` 被当成标签静默删除

- **现象**：用户发的 `if (a<b && c>d) 用 vector<int> 试试` 显示成 `if (ad) 用 vector 试试`；
  `<div>`、`<T>` 之类内容消失。平台消息与会话日志都受影响。
- **触发条件**：任何包含尖括号文本的消息（编程、数学、HTML 片段），无需异常输入。
- **位置**：`lib/core/model/models.dart:486-503`，实际删除在 `:499`
  （`replaceAll(RegExp(r'<(?!br\s*/?>)(/?[a-zA-Z][^>]*)>'), '')`）。
  该清洗对 `ChatMessage` 全部来源生效，而 `PlatformMessage.view`（`:312-320`）也复用它。
- **建议修法**：把「剥标签」限定在**引擎/框架来源**的消息：
  1. 仅当原文含 `<message>` / `<status` / `<turn>` / `<mood>` 等已知包裹时才执行清洗；
  2. 平台消息（`dir=in/out`）一律按原文渲染，只把 `<img>` 转 markdown；
  3. 或改为白名单剥离 + 其余尖括号转义（`&lt;`），保证「显示 = 原文」。
- **用例**：`adversarial_state_test.dart` 前两条（红）。

---

## P2

### P2-1 `/events` 帧缺少 `id` 时沿用上一帧 id，后续消息被去重吞掉

- **现象**：连续两条框架消息，第二条服务端漏了 `id`（但带了 `n`）时，两条拿到同一个 id；
  UI 的 `_frameworkIds` 把第二条当重复丢弃，用户看不到它。
- **触发**：旧数据/半截帧；SSE 规范下 `id` 会沿用，客户端还优先用了它。
- **位置**：`lib/core/capability/sessions_repository.dart:133-141`（`sse.id ?? '$sessionId:$n'`），
  消费点 `lib/features/chat/chat_page.dart:839-846`。
- **建议**：优先用帧自身的 `n` 生成 `sessionId:n`，`sse.id` 只用于 `Last-Event-ID` 续传游标。
- **用例**：传输层「帧没有 id 且带 n…」（红）。

### P2-2 mark 的 `time` 是字符串毫秒时被丢弃，重放过滤失效

- **现象**：断线重连后，服务端重放上一轮的 `prompt/input-enqueued`，客户端无法按时间过滤，
  把旧 mark 当成本轮起点，计时从上一轮开始。
- **位置**：`lib/core/capability/sessions_repository.dart:174-175`；过滤器 `chat_page.dart:806-815`。
- **建议**：接受数字字符串（以及 ISO），解析失败时显式标记为「不可信帧」并跳过 mark。
- **用例**：传输层「mark 的 time 是字符串毫秒」（红）。

### P2-3 `truncated` 帧被忽略，违反「丢弃增量、重取全量」契约

- **现象**：上下文压缩/增量窗口失效后，框架块与计时继续基于过期增量，出现错位或旧打点重放。
- **位置**：`lib/features/chat/chat_page.dart:803-805`；契约 `docs/transport.md` 第 6 条。
- **建议**：`event.truncated` → 节流触发 `_loadFramework(force: true)`，同时清空 `_eventsSince`
  并用「本次重取时刻」作为新的重放过滤基准。
- **用例**：传输层「truncated 帧」（绿，证明事件可达；缺的是消费）。

### P2-4 文本块 `text` 非字符串时渲染直接抛异常

- **现象**：一条 `{"type":"text","text":42}` 块会让 `bodyMarkdown` 抛 `TypeError`，
  该消息的气泡构建失败（debug 红屏/错误块，release 显示错误占位）。
- **位置**：`lib/core/model/models.dart:407`（`data['text'] as String?`），使用于 `:618-634`。
- **建议**：`final v = data['text']; return v is String ? v : null;` 并对 `attrs.content` 同样处理。
- **用例**：`adversarial_state_test.dart`「text 块里的 text 不是字符串」（红）。

### P2-5 ISO 时间按 UTC 保留并直接本地展示，日期分隔与 `HH:mm` 偏一个时区

- **现象**：服务端给 `2026-11-19T23:30:00Z` 时，UTC+8 用户看到 `23:30`（应为次日 07:30），
  「今天/昨天」与日期分隔条按 UTC 日切分，跨零点消息归错天。
- **位置**：`lib/core/model/models.dart:382-400`（`DateTime.tryParse` 保留 UTC）；
  展示 `lib/features/sessions/sessions_page.dart:944-952`、`lib/features/chat/chat_page.dart:2091-2104`。
- **建议**：解析后 `.toLocal()`（或统一用 UTC 计算、展示时转换）。
- **用例**：`adversarial_state_test.dart`「带 Z 的时间保留 UTC」（红）。

### P2-6 翻页游标被「补发的旧消息」带偏，更早历史永远取不到

- **现象**：实时流插入一条时间早于当前最早页的消息后，`_loadEarlier` 用 `_messages.first.time`
  当游标重取一段已加载区间；`fresh` 为空 → `_hasMore = false`，向上滚不再加载。
- **位置**：`lib/features/chat/chat_page.dart:854-877`（游标 `:862`、停手判断 `:873-876`）。
- **建议**：维护「已确认连续的最早时间」而不是数组首元素时间；或直接使用服务端返回的
  next-cursor（当前接口只有 `before` 时间戳，需要协议侧补 cursor）。
- **用例**：纯逻辑无法覆盖（私有状态），按代码路径记录。

### P2-7 无上限增长：消息列表与 Widget 缓存永不淘汰

- **现象**：长开详情页（大群、运行数小时）内存持续上涨；每条消息缓存一整棵 markdown Widget，
  100KB 消息也被整棵保留。
- **位置**：`lib/features/chat/chat_page.dart:120-145`（`_messages/_ids/_noticeOpen/_itemCache`），
  写入点 `:1602`；框架块已有 400 上限（`:123`、`:844-849`），消息没有。
- **建议**：`_itemCache` 改 LRU（上限 ~200）；`_messages` 超过上限时从头部裁剪并保留翻页游标；
  离开页面时清空缓存。
- **用例**：长文本保留性已有绿用例；内存行为需真机 profile。

### P2-8 会话列表页在后台不暂停平台流

- **现象**：息屏后列表页仍在解析 `/api/platform/stream` 的每一帧，耗电/唤醒；详情页已经做了暂停。
- **位置**：`lib/features/sessions/sessions_page.dart:42-155`（无 `WidgetsBindingObserver`），
  `:266-273` `_startStream`；对照 `lib/features/chat/chat_page.dart:320-380`。
- **建议**：列表页同样实现生命周期暂停/恢复；或把流提到共享单例（两页共用一条连接）。
- **用例**：需集成测试，静态结论。

### P2-9 markdown 链接无 scheme 白名单，消息内容可触发任意系统 URL

- **现象**：点击消息里的 `[x](intent:…)` / `[x](file:///…)` 会交给 `url_launcher` 打开；
  畸形 URL 在点击回调里 `Uri.parse` 抛 `FormatException`。
- **位置**：`lib/features/chat/message_view.dart:417-424`（`LinkConfig` 只传 style，未传 `onTap`）；
  `markdown_widget` 的默认行为见其 `lib/widget/blocks/leaf/link.dart:35-40`（直接 `launchUrl(Uri.parse(url))`）。
- **建议**：传 `onTap`：`Uri.tryParse` + 只允许 `http/https`，其余复制链接并提示；失败不抛。
- **用例**：需 widget 测试与平台通道 mock，暂未落。

### P2-10 强制「重新载入」把 `/events` 游标清空，重连后旧 mark 重放

- **现象**：菜单「重新载入」后 `_eventsSince = null`，若紧接着断线重连，服务端从日志头部重放；
  重放过滤基准 `_eventsOpenedAt` 是页面打开时间，重放的历史帧都被当成本轮。
- **位置**：`lib/features/chat/chat_page.dart:646-662`（`_eventsSince = null`）、`:806-815`（过滤）。
- **建议**：force 重载时同步重置 `_eventsOpenedAt`；或保留游标、只重取日志。

### P2-11 `_needsAuth` 不校验 scheme，token 可能以明文发给同 host:port

- **现象**：base 为 `https://host:443` 时，消息给出 `http://host:443/x.png`，host/port 相同 →
  带 Bearer 的请求走明文 HTTP（token 暴露给链路中间人）。
- **位置**：`lib/features/chat/message_view.dart:566-571`。
- **建议**：`uri.scheme == base.scheme` 也加入判断；或直接用 `base.resolve` 后的 origin 比较。
- **说明**：需要攻击者同时控制消息内容与网络路径，概率低；修 P0 时一并处理。

### P2-12 iOS 钥匙串 `userPresence` 可能让每次启动都要求重输 token

- **现象**：设备未录入生物识别、或首次解锁前读取，`read` 抛错被当成「未连接」，
  用户每次打开都要重新粘贴 token；`save` 失败时的报错又落在地址字段上。
- **位置**：`lib/core/store/connection_store.dart:24-30`（`accessControlFlags: [userPresence]`）、
  `:32-45`（catch 后 `token = null`）、`:47-52`。
- **建议**：去掉 `userPresence`（或做一次迁移），`load` 区分「钥匙串不可用」与「无凭证」，
  给出「需要重新连接」的明确状态；`save` 失败挂到 token 字段。
- **说明**：iOS 条件相关，未在真机复现。

### P2-13 其他可靠性细节（合并记录）

| 现象 | 位置 | 建议 |
|---|---|---|
| 一页内重复 id 会画两条相同气泡 | `chat_page.dart:625-641`（页内不去重）、`_insertMessage` | 页内按 id 去重 |
| 错误正文（含整页 HTML）原样进 SnackBar / 错误页 | `api_client.dart:199-220`、`chat_page.dart:631-638` | 非 JSON/HTML 时给固定文案，原正文只进调试日志 |
| 超大单帧无上限（100MB 帧直接进内存 + JSON 解码） | `api_client.dart:139-175` | 限制单帧大小（如 4MB）并显式报错 |
| JSON 无 charset 时按 latin1 解码 → 中文乱码 | `api_client.dart:186-188` | 固定 `utf8.decode(res.bodyBytes)` |
| 轮询只查 `/api/sessions` 第一页（50 条），更早的会话读不到 `running` | `chat_page.dart:463-472` | 按 id 查单条或按游标补齐 |
| 主题切换会在轮询态下立刻重连 `/live`，绕过 9s 退避 | `chat_page.dart:298-307` | 重连入口加最小间隔 |
| `settled.reason` 非字符串时 `/live` 流抛异常中断，退化为轮询 | `models.dart:961-964` | `outcome['reason']` 用 `is String` 判断后降级为 null |
| `storage://` 引用过期（404）只显示通用「重试」占位，用户不知道附件已失效 | `message_view.dart:1030-1042`、`:900-940` | 404 时给「附件已过期」文案并禁用自动重试 |

---

## 已核对、未发现问题的点

- **token 不进日志 / 异常文案**：`lib/` 内无 `print/debugPrint/logger`；`ApiFailure.toString()` 只拼
  code+message；请求头只出现在 `ApiClient`/`StateSocket` 内部，测试断言 URL 与错误文本均不含 token。
- **URL 拼接与编码**：`route:` 会话 id 用 `Uri.encodeComponent` 逐段编码；平台 key 走
  `queryParameters`（`& # +` 安全）；`Last-Event-ID` 在头里。测试全绿。
- **媒体路径穿越（客户端侧）**：`storage://` 与 `/files/` 分支都用 `Uri.encodeComponent`，
  `..`/`/` 被编码；相对路径只会拼成 `/api/workspace?path=…`，路径本身在查询参数里，
  客户端不产生越界请求（服务端仍需自行校验，见插件侧职责）。
- **状态：连续 cancel / 双重订阅 / 快速前进后退**：`_cancelling` 互斥、`_liveStarted/_eventsStarted/_streamSub`
  闸门与 `dispose` 都成对；返回时旧订阅被 cancel，未发现重复订阅或泄漏（除 P2-8 的后台空转）。
- **主题切换**：只重建 MaterialApp，不会重建页面 state 或另开流；仅 P2-13 的重连节流问题。
- **数据：乱序消息 / 重复 id（跨来源）/ 空会话 / 0 消息 / 全图片 / 100KB 文本**：
  `_insertMessage` 按时间插入、`mergeTimeline` 升序合并、`_ids` 跨源去重、空页与纯媒体都有降级；
  100KB 文本不被截断（有绿用例）。剩余问题为 P2-1、P2-6、P2-7。
- **`/api/sessions/:id` 操作（cancel/compact/fork/setModel）**：路径编码、幂等键、错误提示齐全。

---

## 待修清单（按严重度 / 按文件）

| 严重度 | 条目 | 主要文件 | 大致范围 |
|---|---|---|---|
| P0 | 外链图片泄露 Bearer | `lib/features/chat/message_view.dart` | 396-401、733-735、845-851、924-933（统一到 566-577） |
| P1 | 半死 SSE 无自愈 | `api_client.dart`、`platform_stream.dart`、`chat_page.dart` | 134-136、49-76、774-855、993-999 |
| P1 | 401 后无限重试 | `chat_page.dart`、`sessions_page.dart` | 429-460、774-800、1132-1160、206-281 |
| P1 | 类型漂移打死列表 | `models.dart`、`sessions_repository.dart`、`platform_repository.dart` | 86-95、156-172、456、667、13-48、30-63 |
| P1 | 正文 `<...>` 被删 | `lib/core/model/models.dart` | 486-503 |
| P2-1 | 帧 id 复用丢消息 | `sessions_repository.dart` | 133-141 |
| P2-2 | mark time 字符串丢弃 | `sessions_repository.dart`、`chat_page.dart` | 174-175、806-815 |
| P2-3 | `truncated` 未消费 | `chat_page.dart` | 803-805 |
| P2-4 | `text` 非字符串抛异常 | `models.dart` | 407、618-634 |
| P2-5 | ISO 时间时区偏移 | `models.dart`、`sessions_page.dart`、`chat_page.dart` | 382-400、944-952、2091-2104 |
| P2-6 | 翻页游标被旧消息带偏 | `chat_page.dart` | 854-877 |
| P2-7 | 无界缓存/消息 | `chat_page.dart` | 120-145、1602 |
| P2-8 | 列表页后台不暂停流 | `sessions_page.dart` | 42-155、266-273 |
| P2-9 | 链接无 scheme 白名单 | `message_view.dart` | 417-424 |
| P2-10 | 重载清空事件游标 | `chat_page.dart` | 646-662、806-815 |
| P2-11 | auth 判断缺 scheme | `message_view.dart` | 566-571 |
| P2-12 | iOS 钥匙串 userPresence | `connection_store.dart` | 24-30、32-52 |
| P2-13 | 杂项（见上表） | 多文件 | — |

## 复现

```bash
flutter.bat test test/adversarial_transport_test.dart   # 20 绿 / 10 红（待修）
flutter.bat test test/adversarial_state_test.dart       # 16 绿 / 4 红（待修）
flutter.bat test test/adversarial_media_auth_test.dart  # 2 绿 / 2 红（P0）
```

红用例即待修项；修复 `lib/` 后无需改测试即可转绿。

---

## 已修状态（2026-11-19 追加，未改上文原文）

验证：`flutter analyze` 零问题；`flutter test` 125 条全绿（16 条「待修」全部转绿，对照组保持绿）。
详细修法见 `docs/adversarial-fixes.md`。

| 条目 | 状态 | 说明 |
|---|---|---|
| P0-1 Bearer 外泄 | 已修 | 取图头收敛到 `_needsAuth`/`_authHeadersFor`：仅同 scheme+host+port 的 `/files`、`/api/workspace`、`/api/platform/media` 带 Bearer；`_ChatImage` 内部按最终 URI 重算 |
| P1-1 半死 SSE | 已修 | `ApiClient.sse` 20s 行级空闲判死（含心跳，容纳首帧 20s 契约）+ 错误体 1.5s 超时；`/live` 8s 首帧 + 20s 每帧空闲；`/events` 20s 空闲 + 1→2→4→8→30 退避；单订阅闸门 |
| P1-2 401 无限重试 | 已修 | 401 fail-fast；平台流/两条页面流停止重试，弹「登录已失效 / 重新连接」；文案不含 token |
| P1-3 类型漂移 | 已修 | 解析异常收敛为 `ApiFailure`（非 TypeError）；展示/内容字段容错；`hasMore` 宽容；页面补 `catch (Object)` |
| P1-4 `<...>` 被删 | 已修 | 只剥白名单 HTML/平台标签；比较/泛型正文原样保留 |
| P2-1 帧 id 复用 | 已修 | 优先 `sessionId:n`，`sse.id` 仅兜底 |
| P2-2 mark 字符串时间 | 已修 | 数字字符串/ISO 均接受 |
| P2-3 `truncated` 未消费 | 已修 | 清游标、前移过滤基准、节流重取全量 |
| P2-4 `text` 非字符串 | 已修 | 降级为 null |
| P2-5 ISO 时区 | 已修 | 统一 `toLocal()` |
| P2-6 翻页游标 | 已修 | 使用已确认连续的最早时间 `_earliest` |
| P2-7 无界缓存 | 部分已修 | Widget 缓存 200 条 LRU + 离页清空；消息列表未裁剪 |
| P2-8 列表页后台流 | 已修 | `WidgetsBindingObserver` 暂停/恢复 |
| P2-9 链接 scheme | 已修 | 仅 http/https，其余复制；畸形 URL 不抛 |
| P2-10 重载清游标 | 已修 | force 重载重置 `_eventsOpenedAt` |
| P2-11 auth 缺 scheme | 已修 | `_needsAuth` 比较 scheme |
| P2-12 iOS 钥匙串 | 已修 | 去掉 `userPresence` |
| P2-13 杂项 | 大部分已修 | 页内去重、错误页文本收敛、4MB 帧上限、固定 UTF-8、重连节流、`reason` 容错、404「附件已过期」；轮询仅第一页未修 |
