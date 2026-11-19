# 性能修项记录（2026-11-19）

> 依据 `docs/perf-report.md`（下称「报告」）第 7/9 节。本轮只改 `lib/**` 与新增测试，
> 未改 UI 结构、文案与交互，未删除历史消息，未引入新依赖。
>
> 验证：`flutter analyze` → **No issues found**；`flutter test` → **129 passed**
> （原 125 + 新增 4 条 `MemoCache` 单测）。设备侧复测留到下一轮，命令见第 7 节。
>
> 行号为改动后的工作区行号。

## 0. 结论摘要

| # | 报告项 | 位置（改后） | 状态 |
|---|---|---|---|
| 1 | 时间线每帧全量合并（H1/H2/P1） | `chat_page.dart:120/135-142/1800-1842`、`timeline.dart:13-24` | 已修：按版本号记忆化 + `noticeKey` 缓存 |
| 2 | `timeline.dart` 正则 | `timeline.dart:13`、`models.dart:525-531/628-640` | 已修：全部提为 `static final`，并补 `noticeKey` 结果缓存 |
| 3 | 气泡每 build 解析（H3/H4/H5/H10） | `message_view.dart:75-85/121/408-436/1569-1623/1751-1759` | 已修：命令帮助 / 占位判定 / `Notice` / JSON 重排 / markdown 树全部记忆化 |
| 4 | 会话列表非虚拟化（H8/H9/P3） | `sessions_page.dart:940-975/1026-1101/1150-1176` | 已修：`ListView.builder` + 行/分组缓存 + 滚动补页 |
| 5 | 后台 tick/解析 | `chat_page.dart:388-423/447-452`、`sessions_page.dart:165-202` | 已修：断流基础上释放 Widget/解析缓存与解码位图，停掉后台排队的表 |
| 6 | PSS 280 MB | `main.dart:9-17`、`app_tokens.dart:188-198`、`message_view.dart:794/1321`、`assistant_avatar.dart:35` | 部分修：解码尺寸与全局缓存上限收紧（见第 2 节） |
| 7 | 列表 2 / 详情 3 条连接 | `sessions_page.dart:165-202/335-347` | 已定位并修掉详情页多出的那条（见第 4 节） |
| 8 | H6 图片正则 / H7 日期分隔条 | `message_view.dart:705-710`、`chat_page.dart:1849-1869/2396-2427` | 顺手修（P6/P8） |

未做：P7（`cacheExtent` 600 下调）。它需要在真机上做「首屏 PSS ↔ 上滑白屏」的 A/B，
不适合与本次结构改动一起混测；建议下一轮单独开关（见第 8 节）。

---

## 1. 时间线与框架块（报告 P1 / H1 / H2）

### 原问题

- `ChatPage.build` 每帧调用 `mergeTimeline(_messages, _framework)`：建正文索引 Map、
  给每条消息生成 `_Row`、排序、再遍历生成 `items`。300 条时每帧 O(n log n) + 3 个新列表。
- 报告第 3 节里 `build max` 13.58 / 15.61 / 23.68 ms 全部出现在「分页 `setState` 后重建」，
  正是这条路。
- `noticeKey(message.content)` 在索引与去重里各跑一次 `replaceAll(RegExp(r'\s+'), '')`；
  `Notice` 的 `split`/逐行正则也在每帧重跑。

### 改法

- `_messages` / `_framework` 收敛为两个唯一写入口 `_setMessages` / `_setFramework`，
  每次替换列表推进版本号（`_messagesRev` / `_frameworkRev`）。
- `_timeline()` 只在两个版本号变化时重算，否则直接返回上次的 `_items`。
  时间线项持有 `PlatformMessage` 引用，脚注时间戳（`turnStartedAt/turnEndedAt`）是原地写字段，
  不改变排序/分组，因此不需要让时间线失效——只让该气泡的 Widget 缓存失效（原有逻辑）。
- 流式正文走 `ValueNotifier` + `ValueListenableBuilder`，不触发 `ChatPage.build`，
  所以 90ms 一次的输出不会让时间线失效。
- `noticeKey` 增加进程级有界缓存（`MemoCache<String>`，容量 800，键就是正文本身，不复制字符串）；
  `timeline.dart` 的 `_spaces` 本来就是顶层 `final`，本轮补的是「结果」缓存。
- `ChatMessage._bodyMarkdown` 里三个正则与 `_hasMarkup` 的正则提为 `static final`
  （每条消息第一次读正文都要编译一次，300 条就是 900 次）。
- 日期分隔条的「今天/昨天/YYYY-MM-DD」在时间线项第一次构建时算好（`_dayLabel`），
  随 Widget 缓存复用；`_DayDivider` 不再读系统时钟（H7/P8）。

### 预期收益

- 分页/流帧后的重建不再每帧全量排序：300 条场景每帧少一次 `Map` 构建、一次排序
  （约 300 log 300 次比较）与 N 次正则替换。
- 单帧 build 尖峰应回落到 11.1 ms 预算内；滚动稳态的 build p95 基本不变（它本来就不是瓶颈）。
- `Notice` 解析与日期差从「每帧每条」降到「每条约一次」。

### 如何验证

1. 真机 profile 跑报告第 3 节的 timeline 采集（命令见第 7 节），对比：
   - 分页后 `Dart|BUILD` 的 max：应从 13.58–23.68 ms 降到 ≤11.1 ms；
   - 整帧跨度 p95/p99：不应变差（目标仍 ≈4.5/6.5 ms）。
2. 逻辑正确性已由 `test/timeline_test.dart`、`test/adversarial_state_test.dart` 覆盖
   （同刻顺序、锚点、跨天分组、翻页不漂）。

---

## 2. 气泡渲染（报告 P2 / H3 / H4 / H5 / H10 / H6）

### 原问题

- `MessageView.build` 每条消息都 `CommandHelp.parse(body)`（全段 `allMatches` + 多次 `replaceAll`）。
- `isPlaceholderOnly(body)` 每帧重跑两条正则。
- `_FrameworkNotice.build` 每次：`Notice.parse`（`split`、逐行 `_rule.hasMatch`、`sublist`）、
  `Notice.prettyJson`（`jsonDecode` + 重新缩进）、`Notice.isUrlList`（逐行匹配）。
- `_Markdown` 每次 build 新建 `MarkdownConfig`/`PConfig`/`ImgConfig`/`PreConfig`/`LinkConfig`；
  `MarkdownWidget.didUpdateWidget` 会无条件 `clearState()+updateState()`，即**重新解析整棵 AST**。
- `_ChatImageState._measure` 在 `build` 里发起解码测量；`_inlineBytes`/`_normalizeSource`
  每次调用都 `new RegExp`。

### 改法

- 新增 `MemoCache<T>`（`message_logic.dart:12`）：有界、命中后移到末尾、超限淘汰最旧，
  可缓存 `null`（解析失败也要记住）。
- `MessageView` 两个静态缓存：
  - `_helpMemo`：`body → CommandHelp?`；
  - `_placeholderMemo`：`body → bool`（只在带媒体时才用得到，但仍然按正文命中）。
  键是正文本身（比「id + 内容 hash」更严格：相同正文直接命中，且不复制字符串）。
- `_FrameworkNotice` 改为 StatefulWidget，`initState`/`didUpdateWidget` 里解析一次，
  build 只读派生结果（`_title/_meta/_preview/_paragraphs/_hidden/_memoryTag`）；
  `Notice.parse` 与「段落是否 JSON/URL 列表」各有一个静态缓存。
  `Notice.isUrlList` 再加 O(1) 前缀快筛（非 `http` 开头直接 false）。
- `_Markdown` 改为 StatefulWidget：整棵 `MarkdownWidget` 子树在 State 里缓存，
  父级重建时返回**同一个实例**，Flutter 对相同 widget 实例跳过子树更新，
  `MarkdownWidget` 就不会重新解析；只有正文/配色/`base`/`headers` 变化或主题依赖
  （`didChangeDependencies`）才丢弃。
- 图片正则提为 `_ChatImage._inlineMarker` / `_base64Marker` 两个 `static final`（H6）。
- 解码测量移出 `build`：`didChangeDependencies`（dpr 变化）与 `didUpdateWidget`（换图）里发起，
  命中缓存同步回调时直接写字段（不 `setState`），异步回调才 `setState`。
  `_remeasure`（重试）会重新测量后再刷新。
- `MessageView.clearCaches()` 供页面在切后台/退出时清空上述进程级缓存。

### 预期收益

- 气泡因主题切换、父级 `setState`、列表回收后重建时，不再重扫全文、不再重解 markdown AST。
- 报告所说的「新气泡进视口时的 13–15 ms 单帧」中，属于「同一气泡二次 build」的部分被消掉；
  首次构建的诊断成本仍在（那是必须付的），但已被 `_itemCache` 与 `cacheExtent` 限制在少数条。

### 如何验证

- 单测覆盖：`test/message_logic_test.dart` 新增 `MemoCache` 的 4 条用例
  （只算一次 / 可缓存 null / 超限淘汰最久未用 / clear 后重算）。
- 真机：快速上下滑动（不触发分页）时 `Dart|BUILD` max 应从 13–16 ms 降到 11 ms 内；
  主题切换（设置里切浅色/深色）后首帧允许一次重解析，之后滚动不再重复。
- 功能回归：markdown 图片仍只对同源 `/files`、`/api/workspace` 带 Bearer
  （`_authHeadersFor` 未改，`test/adversarial_media_auth_test.dart` 通过）。

---

## 3. 会话列表（报告 P3 / H8 / H9）

### 原问题

- `ListView(children: [...for (row in active) _tile(...)])` 一次性构造**全部**会话行；
  `_partition()` 每次 build 重新遍历 + 切两段；`_rows` 还要重新归一键、排序。
- `build` 里 `if (_cursor != null) addPostFrameCallback((_) => _loadMore())`：
  每次重建都注册一帧回调，加载中重复 build 会叠加多次 `_loadMore()`。

### 改法

- 列表改为 `ListView.builder`：先构造轻量的 entry 列表（分组头 / 行 / 归档入口 / 底部留白），
  `itemBuilder` 只为可见项构建 `_SessionTile`（头像解码、时间格式、`Material/InkWell` 都推迟到可见时）。
- `_rows` 与 `_partition` 结果缓存在 State 里，只在 `_conversations` / `_loaded` 真正变化时
  由 `_invalidateRows()` 失效（刷新、会话表补齐、已加载表对齐、流帧更新、补页）。
- 去掉 build 里的 postFrame：主列表用 `ScrollController` 在 `extentAfter < 480` 时补页；
  搜索态（需要覆盖全部会话）用 `_kickLoadMore()`，同一时刻只排一帧，`_loadingMore` 兜底。
- 分组头仍是列表项（原实现也没有吸顶），下拉刷新仍是 `RefreshIndicator` +
  `AlwaysScrollableScrollPhysics`，交互与视觉不变。

### 预期收益

- 会话数 50–100+ 时，首帧与每次刷新不再构建全部行；当前 6 条无变化。
- 不再因重建而排队 `_loadMore()`；补页由滚动真正触发。

### 如何验证

- 真机造 100+ 会话（或临时 mock）后进入列表，首帧时间与 `Dart|BUILD` max 对比；
  滚动过程中列表项按需出现（无一次性长卡顿）。
- 下拉刷新仍可触发；滚动到底会自动补一页（观察 `/api/sessions?cursor=` 请求）。
- `flutter test`（`session_logic_test.dart` 覆盖分组逻辑，未改语义）。

---

## 4. 后台行为（报告第 4 节 / 本轮要求 5）

### 原问题

- 详情页已有：`paused` 时断开 `/live`、`/events`、平台流，停轮询/探测，`TurnClock.suspend()`。
- 但**解析与缓存**没释放：`_itemCache`（最多 200 棵 markdown 子树）、静态解析缓存、
  `ImageCache` 里的解码位图都留在进程里；报告第 5 节「退回列表只回落 21 MB」与此一致。
- 列表页只断流，`_syncConversations` 排的 2s 补表定时器仍可能在后台触发一次请求。
- 列表页在详情页压栈后仍保持自己的 `PlatformStream`——这就是详情页多出的那条连接（见第 5 节）。

### 改法

- 详情页 `_pauseStreams`（`chat_page.dart:388-423`）在断流之后：
  - `_itemCache.clear()`；
  - `MessageView.clearCaches()`（命令帮助、占位、`Notice`、JSON/URL 判定）；
  - `clearNoticeKeys()`（时间线正文对齐键）；
  - `PaintingBinding.instance.imageCache.clear()`（丢掉此刻无人监听的在缓存位图；
    仍被屏幕上 Widget 监听的图像由监听者持有，真正释放发生在元素销毁后——这是
    Flutter `ImageCache` 的语义，不做越权 evict）；
  - 取消 `_runningCheck`（落库后 400ms 确认 `running` 的请求）。
- 详情页 `dispose` 同样清两份解析缓存（退出详情页不该把这一页的正文解析结果常驻进程）。
- 列表页：`paused` 时断流 + 取消 `_syncTimer`；回前台/回到栈顶才重建流。

### 预期收益

- 后台 3 分钟窗口内仍是 0 唤醒、0 网络（原有行为不变），额外把 Dart 堆/解码缓存压低，
  回来后按当前可视气泡重建。
- 退出详情页后 PSS 的「回落值」比 21 MB 更多（具体幅度取决于图片数量，需实测）。

### 如何验证

- 复跑报告第 4 节命令：锁屏 3 分钟后 `/proc/net/tcp` 中到 `:5028` 的 ESTABLISHED 应为 0，
  `dumpsys batterystats --checkin` 的唤醒闹钟仍为 0。
- 详情页压后台 30s 再回来：消息列表立即恢复（数据未删），可见气泡重新出现（允许一次重建）。

---

## 5. 重复连接核查（报告 P4）

### 观测

- 列表页稳定态 **2** 条到 `:5028`，详情页 **3** 条（预期 1 / 2）。

### 定位结果

**详情页多出的那条是真实重复订阅，不是 keep-alive。**

- `SessionsPage` 的 `PlatformStream` 在 `ChatPage` 被 `Navigator.push` 压栈后**仍在订阅**
  （它只在 App `paused` 时断开）。
- `ChatPage` 自己又建了一条 `PlatformStream`（`_streamSub`），再加 `/live`（`repo.live`）
  与 `/events`（`repo.events`，与 `/live` 同属页面共享的 `http.Client`，HTTP/1.1 各占一条 TCP）。
- 所以详情页的连接构成是「列表页残留 + 详情页自己的 + /live(+events)」；
  报告测到的 3 条与「列表残留 + 详情平台流 + 其中一条 SSE」吻合。
- 代码里的三条订阅都有单例闸门（`_streamSub != null`、`_liveStarted`、`_eventsStarted`），
  `_startStream`/`_startLive`/`_startEvents` 不会各自叠出第二条；`PlatformStream` 内部重连
  会先 `_sse?.cancel()` 再重新 `_open()`，也没有「旧连接未 cancel」的问题。

### 修法

- `SessionsPage` 订阅条件改为「前台 + 路由栈顶」（`didChangeDependencies` 里读
  `ModalRoute.of(context)?.isCurrent`，与详情页已有的可见性判断同一套机制）：
  - 进入详情页 → 列表断流（`_stream?.dispose()` + cancel，底层 `http.Client` 80ms 后关闭）；
  - 返回列表 → 重建流（`PlatformStream` 会重放每个会话最近 5 条，行状态补齐），
    `_open` 返回时仍照旧补一次 `/api/sessions` 元数据；
  - 切后台 → 断流 + 取消排队中的补表定时器。
- `_startStream` 内部再加一道 `_foreground && _routeVisible` 闸门，防止其它路径绕过。

### 列表页自己为什么是 2

报告里列表页的 2 条（预期 1）**不是**第二条 SSE：`SessionsPage` 只有一条 `PlatformStream`。
多出的那条与 `_api` 上最后一次 `/api/sessions`、`/api/platform/conversations` 的
`package:http` keep-alive 连接一致（`ApiClient` 每条请求共用同一个 `http.Client`，
`dart:io HttpClient.idleTimeout` 默认 15s）。这属于正常连接复用，不产生后台流量。

### 如何验证

```bash
D='adb-10CF8403GA0049P-rYoZ2B (2)._adb-tls-connect._tcp'
P=love.mikumiku.chatluna_mobile
# remote 端口 5028 = 0x13A4，状态 01 = ESTABLISHED
adb -s "$D" shell cat /proc/net/tcp /proc/net/tcp6 | awk '$3 ~ /:13A4$/ && $4=="01"'
```

| 时刻 | 期望 |
|---|---|
| 列表页静置 3s | 1–2（1 条 SSE + 可能的 15s 内 keep-alive） |
| 列表页静置 20s（不操作） | **1**（keep-alive 超时退出） |
| 进入详情页 5s | **2**（详情平台流 + `/live`；`/events` 建立时短暂 3） |
| 详情页静置 20s | 2–3（`/live` 与 `/events` 为长连接） |
| 返回列表 | 2（列表流重建后 1 条 SSE + `/live`/`/events` 随详情页 dispose） |

若「进入详情页」仍是 3 且第 3 条的本地端口与列表页流相同，说明列表页没有断流
（检查 `ModalRoute.of` 依赖是否生效）；若「列表页静置 20s」仍为 2，则可能是另一条
未被取消的 SSE——用 `ss -tnp`（root）或 `tcpdump` 看该连接是否有 `: ping` 心跳即可区分。

---

## 6. 内存（报告第 5 节）

### 6.1 分解

`dumpsys meminfo` 只把内存分成几类，**Dart 堆不单列**（它在 native 分配里），
因此下表是「可测部分 + 余量」，余量里同时包含 Dart 堆、`libapp.so`/`libflutter.so` 的
code、字体与引擎缓存：

| 组成 | 冷启动列表 167.7 | 详情首屏 265.5 | 滚到顶 278.0 | 退回列表 261.6 | 说明 |
|---|---|---|---|---|---|
| Graphics | 65.5 | 70.1 | 70.7 | 69.1 | GL/GPU 缓冲与 Impeller 基线，几乎不随页面内容变 |
| Java heap | 12–17 | 12–17 | 12–17 | 12–17 | 原生 UI 层，Flutter 视图只有很少的 Java 对象 |
| Native heap | 24–47 | 24–47 | 24–47 | 24–47 | 引擎分配、字体、`ui.Image` 位图等 |
| 余量（Code + Stack + PrivateOther + System **+ Dart 堆**） | ≈38–66 | ≈130–145 | ≈140–150 | ≈130–140 | 报告未单列，需 VM service 实测（见 6.4） |

- 从列表到详情增长 **+115 MB**，而 Graphics 只 +5 MB、Java 不变 → **不是图形缓冲**。
- 增长只可能来自：解码位图（ImageCache）、Dart 堆里的时间线/Widget 树/解析结果、
  以及引擎自己的缓存。报告第 5 节的「退回列表只回落 21 MB」说明至少有一部分
  **进程级缓存**没有释放（`ImageCache` 是唯一默认上限 100MB 的进程级缓存）。

### 6.2 代码侧可控上限

| 项 | 改动前 | 改动后 | 位置 |
|---|---|---|---|
| `imageCache.maximumSizeBytes` | 100 MiB（默认） | **64 MiB** | `main.dart:15-17` |
| `imageCache.maximumSize` | 1000 张 | **120 张** | 同上 |
| 气泡图片解码宽 | 260 dp × dpr（不限高） | 260 dp × dpr，上限 `dp × dpr × 1.5` | `message_view.dart:794` |
| 网格格子解码宽 | `side × dpr` | `imageDecodeWidthFor(context, side)` | `message_view.dart:1321` |
| 头像解码 | **原图**（512² ≈ 1 MB/张） | 28–40 dp × dpr（≈ 57–130 KB） | `assistant_avatar.dart:35`、`message_view.dart:308/381` |
| Widget 缓存 | 200 条 MessageView | 不变，另在后台/退页清空 | `chat_page.dart:176/420/450` |
| 解析缓存 | 无（每次重算） | 有界（≤200–800 条），后台/退页清空 | 见第 2 节 |

以 3.0 的设备像素比为例：气泡缩略图按 780 px 宽解码，260×320 的一张 ≈ 3.0 MB；
旧行为下 100MB 缓存能常驻 ~33 张这样的图，且头像按原图解码。新上限 64MB + 头像按显示尺寸解码
后，同样内容常驻的位图数量约减半，头像部分降到约 1/9。

### 6.3 主因判断（如实的边界）

- 从 meminfo 无法单独证明「图片缓存占了多少」，因为解码位图散在 native/graphics 里。
- 但**唯一默认 100MB 量级的进程级缓存就是 ImageCache**，且退回列表只回落 21MB
  与「缓存不随页面销毁」完全吻合；Dart 侧的时间线/消息模型按 300 条 × 平均 200 字正文
  粗估只有 0.3–0.6 MB 量级（Widget 树与解析缓存本轮之前根本没有，本轮也做成有界）。
- 因此本轮按「图片是主因」处理（收紧解码尺寸 + 全局上限），同时把 Dart 侧缓存做成有界、
  可清空。**若下一轮实测显示图片只占小头**，则主因在引擎/Impeller 基线（Graphics 65–71 MB
  是硬成本），能做的只剩 P7（降低 `cacheExtent`）。

### 6.4 如何验证

```bash
# 1) 分类 PSS（报告同款）
adb -s "$D" shell dumpsys meminfo $P | grep -E "TOTAL PSS|TOTAL RSS|Graphics:"

# 2) Dart 堆与 ImageCache 的精确读数（profile 构建，VM service）
#    连上 ws://127.0.0.1:<port>/<token>=/ws 后：
#      getIsolate → isolateId
#      getMemoryUsage{isolateId} → heapUsage / heapCapacity / externalUsage
#      getIsolate 里取 flutter/painting 的 libraryId，
#      evaluate{isolateId, targetId:<painting libraryId>,
#               expression:"PaintingBinding.instance.imageCache.currentSizeBytes"}
```

| 场景 | 期望 |
|---|---|
| 冷启动列表静置 | PSS 比 167.7 MB 低（图片/缓存上限生效），Dart heap ≤ 20 MB |
| 详情首屏（300 条） | PSS 明显低于 265.5 MB；`currentSizeBytes` ≤ 64 MiB |
| 滚到顶 | 不再随图片数量线性上涨；`currentSizeBytes` 稳定在 64 MiB 以内 |
| 退回列表 3s | PSS 回落幅度大于原来的 21 MB（至少回收当前会话的解码位图与 Widget 树） |
| 切后台 30s | `currentSizeBytes` 接近 0（`clear()` 生效） |

> 若图片确实是大头，下一轮再做「超长图按高度上限解码」：目前只约束宽度，
> 一张 780×8000 的长截屏仍可能解到 ~25 MB。做法是测量后按宽高比给 `cacheHeight`，
> 但 `ResizeImage` 同时给宽高会拉伸，需要在 `_ChatImage` 里自行选一边。

---

## 7. 下一轮复测命令

```bash
D='adb-10CF8403GA0049P-rYoZ2B (2)._adb-tls-connect._tcp'
P=love.mikumiku.chatluna_mobile

# 0) 静态检查
cd E:/Codes/AI/projects/chatluna-mobile
flutter.bat analyze
flutter.bat test

# 1) profile 包（本轮已改 lib，必须重装）
flutter.bat build apk --profile --target-platform android-arm64
adb -s "$D" install -r build/app/outputs/flutter-apk/app-profile.apk

# 2) 帧：gfxinfo 恒为空（HWUI 未参与），用 VM service timeline
MSYS_NO_PATHCONV=1 cmd.exe /c "flutter.bat run --profile -d \"$D\""
#   ws://127.0.0.1:<port>/<token>=/ws
#   streamListen{streamId:"Timeline"}
#   setVMTimelineFlags{recordedStreams:["Dart","Embedder","GC","API"]}
#   手势窗口内采集：Dart|BUILD 配对、Embedder|Rasterizer::DoDraw、
#   Embedder|SceneDisplayLag 的 vsync_transitions_missed
#
# 关键对比点（详情页 300 条，首屏 → 连续上滑到顶）：
#   Dart|BUILD max    旧 13.58 / 15.61 / 23.68 ms  → 目标 ≤ 11.1 ms
#   整帧跨度 p95/p99  旧 4.52–4.93 / 6.14–6.60 ms → 不得变差
#   掉帧率            旧 0.53%–0.68%（首屏起步 2.2%）

# 3) 内存
adb -s "$D" shell am force-stop $P
adb -s "$D" shell am start -W -n $P/.MainActivity
sleep 8
adb -s "$D" shell dumpsys meminfo $P | grep -E "TOTAL PSS|TOTAL RSS|Graphics:"
# 进入 300 条会话 → 首屏 → 滚到顶 → 退回列表，每步各取一次
# 再按 6.4 读 Dart heap 与 imageCache.currentSizeBytes

# 4) 后台
adb -s "$D" shell cat /proc/net/tcp /proc/net/tcp6 | awk '$3 ~ /:13A4$/ && $4=="01"'
adb -s "$D" shell dumpsys batterystats --reset
adb -s "$D" shell input keyevent KEYCODE_SLEEP
sleep 180
adb -s "$D" shell cat /proc/net/tcp /proc/net/tcp6 | awk '$3 ~ /:13A4$/ && $4=="01"'   # 期望 0
adb -s "$D" shell dumpsys batterystats $P | grep -E "u0a369|nothing executed"
adb -s "$D" shell dumpsys batterystats --checkin | grep ',10369,l,awl'                  # 期望 awl,0,0

# 5) 连接数（第 5 节的表）
adb -s "$D" shell cat /proc/net/tcp /proc/net/tcp6 | awk '$3 ~ /:13A4$/ && $4=="01"'
```

---

## 8. 下一轮建议（不含在本次改动内）

1. **P7 的 A/B**：`chat_page.dart` 的 `cacheExtent: 600` → 300，跑报告第 3 节的
   「首屏 50 条 → 翻到 300 条」与「首屏 PSS」两组数据；同时确认快速上滑无白屏。
2. **超长图解码**：见 6.4 末尾，按宽高比加高度上限。
3. **Dart 堆画像**：profile 下用 DevTools Memory 做一次快照，确认时间线项/Widget 树在
   300 条会话后的常驻大小；如果 `_itemCache`（200 条）偏大，可降到 120–150。
4. **列表页 keep-alive**：若要求「列表页静置也只剩 1 条连接」，可给 `ApiClient` 的
   `http.Client` 设更短的 `idleTimeout`（需换成 `IOClient(HttpClient()..idleTimeout=…)`），
   属于传输层改动，单独一轮做。

---

## 9. 与既有契约的一致性

`docs/adversarial-review.md` 里已修的契约未被触碰：

- **Bearer 只发给实例同源附件**：`_authHeadersFor` / `_needsAuth` 未改；
  本轮只改了解码宽度与请求时机，`_ChatImage` 仍在每次解析 URI 后重算请求头。
- **SSE 判死**：`PlatformStream`、`/live`、`/events` 的空闲计时逻辑未改；
  本轮新增的只有「列表页在路由被盖住时断开/重建」这一层生命周期。
- **401 停止重试**：`_handleAuthFailure` 未改；列表页的 `_ensureStream` 显式检查 `_authFailed`，
  不会在 401 后因为回到前台/栈顶而重新连流。
