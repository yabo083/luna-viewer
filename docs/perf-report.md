# 性能基线报告（2026-11-19）

> 范围：**只测不改**。本次未修改 `lib/`；第 7 节只给位置与建议。
> 设备：vivo V2425A（PD2425，SM8650），Android 16 / API 36，`wm size` 覆盖 1080×2400，刷新率 90–120 Hz 自适应（实测多为 90 Hz，帧预算 11.1 ms）。
> 实例：`192.168.0.107:5028`（App 已登录实例，凭证保留在 secure storage，安装用 `adb install -r`）。

## 0. 口径与两条必须先说的限制

| 项 | 说明 |
|---|---|
| 构建 | `flutter build apk --profile --target-platform android-arm64` → `app-profile.apk` 42.4 MB（2026-11-19 17:23，含当时工作区 lib 改动），`adb install -r` |
| 设备标识 | `adb -s "adb-10CF8403GA0049P-rYoZ2B (2)._adb-tls-connect._tcp"` |
| **限制 1：`dumpsys gfxinfo` 对本 App 无数据** | Flutter 走自己的光栅线程（Impeller），不经 HWUI，因此 `gfxinfo framestats` 的帧缓冲区永远为空。实测三项均为 0：<br>`Total frames rendered: 0 / Janky frames: 0 / Number Missed Vsync: 0`，`framestats` 的 `---PROFILEDATA---` 段内 0 行。<br>→ **「gfxinfo 口径」判为未测到（原因：HWUI 未参与渲染）**，改用 Flutter 引擎自己的 timeline 事件，见下方「替代口径」。 |
| **限制 2：替代口径** | `flutter run --profile` 连上 VM service（`ws://127.0.0.1:<port>/<token>=/ws`），订阅 `Timeline` 流后逐帧拿引擎事件：<br>• `Dart\|BUILD`（B/E 配对＝UI 线程构建耗时）<br>• `Embedder\|Rasterizer::DoDraw`（B/E 配对＝光栅耗时）<br>• `Embedder\|SceneDisplayLag` 的 `vsync_transitions_missed`（**引擎自报掉帧数**，权威）<br>统计窗口与手势严格同窗口，窗口内 500 ms 预热后开始计数。 |
| 帧耗时定义 | `build/光栅/整帧跨度` = 对应事件对之差；**整帧跨度** = 该帧 BUILD 的起点 → 对应 `DoDraw` 的终点（含调度间隙），按时间顺序一一配对。 |
| 掉帧定义 | 引擎 `vsync_transitions_missed ≥ 1` 的帧；`missed_vsyncs_total` 为其和。 |
| 判据来源 | 阈值取 `docs/perf-audit.md` 的初值（冷启动 ≤ 900 ms、掉帧 ≤ 5%、PSS ≤ 120 MB），未给出的一律用本报告标注的经验值。 |

---

## 1. 启动

### 场景 → 命令 → 原始数值

冷启动（每次先 `am force-stop` 再拉起，`logcat -c` 后取 `Displayed`）：

```bash
adb -s "$D" shell am force-stop love.mikumiku.chatluna_mobile
adb -s "$D" logcat -c
adb -s "$D" shell am start -W -n love.mikumiku.chatluna_mobile/.MainActivity
adb -s "$D" logcat -d | grep -E "Displayed|Fully drawn"
```

| 次数 | LaunchState | TotalTime | WaitTime | `Displayed`（首帧可见） |
|---|---|---|---|---|
| 1 | COLD | **511 ms** | 519 ms | +511 ms |
| 2 | COLD | **354 ms** | 359 ms | +354 ms |
| 3 | COLD | **414 ms** | 419 ms | +414 ms |
| 4（复测） | COLD | 382 ms | 389 ms | +382 ms |
| **中位数** | — | **414 ms** | 419 ms | **414 ms** |

热启动（`KEYCODE_HOME` 后重新 `am start -W`，进程存活）：

| 次数 | LaunchState | TotalTime | WaitTime |
|---|---|---|---|
| 1 | HOT | **65 ms** | 68 ms |
| 2 | HOT | **72 ms** | 76 ms |
| 3 | HOT | **82 ms** | 84 ms |
| **中位数** | — | **72 ms** | 76 ms |

### 结论

- 冷启动中位 **414 ms**，热启动中位 **72 ms**；`LaunchState` 只会出现 COLD/HOT（无 WARM：主页直接回到已有 Activity）。
- `ActivityTaskManager` 的 `Displayed` 与 `TotalTime` 逐次完全相同 → 本 App 的「首帧可见」就是 Activity 首帧，没有额外动画空窗；首帧可见时间＝上表 TotalTime。
- 冷启动第 1 次明显偏高（511 ms，其余 354/382/414），是安装后首次 dex/页面缓存未热；**取中位数 414 ms，相对 900 ms 阈值达标（46%）**。

---

## 2. 列表滚动（会话列表，`input swipe` 20 次）

### 场景 → 命令 → 原始数值

```bash
# 20 次快速上滑，分 4 组采集（framestats 因限制 1 为空，同时用 VM timeline 计数）
for g in 1 2 3 4; do for s in 1 2 3 4 5; do
  adb -s "$D" shell input swipe 540 1900 540 500 70; sleep 0.12; done
  adb -s "$D" shell dumpsys gfxinfo love.mikumiku.chatluna_mobile framestats; done
```

`dumpsys gfxinfo … framestats` 原始输出：

```
Total frames rendered: 0
Janky frames: 0 (0.00%)
Number Missed Vsync: 0
---PROFILEDATA---   ← 段内 0 行数据
```

VM timeline（同手势窗口，3 次独立运行，每次 20 次滑动）：

| 运行 | 光栅帧数 | 时长 | 平均 fps | build p95 / p99 / max | 光栅 p95 / p99 / max | **整帧跨度 p50 / p95 / p99 / max** | 掉帧（missed vsync） |
|---|---|---|---|---|---|---|---|
| A | 716 | 8.1 s | 88.4 | 0.26 / 0.38 / 0.47 | 3.19 / 3.91 / 6.68 | 2.74 / 3.39 / 4.10 / 7.08 *(b+r)* | 0 |
| B | 683 | 7.7 s | 88.6 | 0.40 / 0.60 / 2.52 | 3.48 / 4.21 / 4.79 | 3.27 / **4.28** / **5.38** / 6.06 | **1（0.15%）** |
| C | 692 | 7.9 s | 87.7 | 0.34 / 0.55 / 2.32 | 3.36 / 4.40 / 8.61 | 3.24 / **4.24** / **5.58** / 9.83 | **2（0.29%）** |

（A 为早期脚本口径，只统计 `build+光栅`，无 span 与引擎掉帧计数；B/C 为最终口径。）

### 结论

- **gfxinfo 口径未测到**：本 App 不用 HWUI，`framestats` 恒为空（见限制 1）。
- 替代口径下列表滚动**非常干净**：整帧跨度 p95 ≈ 4.2–4.3 ms、p99 ≈ 5.4–5.6 ms，均远低于 11.1 ms 预算；掉帧 1–2 帧 / 约 690 帧（≤0.3%），**达标**（阈值 5%）。
- **本次数据的信息量有限**：会话列表只有 6 行（`全部会话 6`），内容高度小于视口，20 次 `swipe` 中大部分落在回弹动画上，并未真正做长列表滚动；会话数增长后（例如 100+）应以 `ListView.builder` 场景重测，见第 7 节 P3。

---

## 3. 详情：300+ 条会话向上滚到顶（触发分页）

### 场景 → 命令 → 原始数值

会话：【mc服】牛马梦想家会所（300 条）；首屏一次只取 50 条（`_pageSize = 50`，`chat_page.dart:97`），滚到顶会连续触发分页（离顶部 320 px 内即 `_loadEarlier()`，`chat_page.dart:1634`）。

```bash
adb -s "$D" shell dumpsys gfxinfo <pkg> reset        # 先 reset
# 40 次快速下滑（反向列表里是往更早的方向），间隔 260 ms，全程 17.9 s
adb -s "$D" shell input swipe 540 500 540 2250 35    # ×40
adb -s "$D" shell dumpsys gfxinfo <pkg> framestats   # 依然 0 帧
```

原始数值（VM timeline，同窗口）：

| 运行 | 光栅帧数 | 时长 | 平均 fps | build p50/p90/p95/p99/max | 光栅 p95/p99/max | **整帧跨度 p50/p90/p95/p99/max** | 掉帧 | 最大连续掉帧 |
|---|---|---|---|---|---|---|---|---|
| **滚到顶（50 条起，逐页补到约 300 条 ≈ 5 次分页）** | 1699 | 17.86 s | 95.1 | 0.09/0.42/**0.69**/1.25/**13.58** | 3.50/4.25/6.54 | 3.25/4.15/**4.52**/**6.14**/**9.02** | **9（0.53%）** | 1 |
| 反向：滚回最新 | 1626 | 18.98 s | 93.1 | 0.08/0.62/**0.96**/1.48/**15.61** | 3.22/4.32/6.28 | 3.05/4.00/**4.93**/**6.60**/**8.60** | **11（0.68%）** | 1 |
| 早期口径：首屏起步缓滑（另一会话，317 条） | 943 | 13.3 s | 71 | 0.10/—/1.22/1.63/**23.68** | 3.95/4.84/8.06 | 3.02/—/4.54/5.84/**24.20** | **21（2.2%）** | 1 |

`dumpsys gfxinfo` 复测仍为 `Total frames rendered: 0 / Janky frames: 0`。

### 结论

- **掉帧集中在两类时刻，且都是单帧、只掉 1 个 vsync**（`engine_missed_max = 1`，无连续卡顿）：分页返回后的 `setState` 重建（300 条一次性并入时间线）与气泡首次进入视口（markdown 解析）。
- 单帧超预算的**根因在 UI 线程 build 段**：`build max` = 13.58 / 15.61 / 23.68 ms，全部 > 11.1 ms；对应光栅段最大只有 6.5–8.1 ms，**光栅不是瓶颈**。这与第 7 节 P1/P2 的静态热点完全吻合。
- 稳态滚动（不触发分页时）p95 约 4.5–4.9 ms，**达标**；jank 率 0.53%–0.68%（阈值 5%）**达标**，但首屏起步那一轮 2.2% 明显更差——首次进入详情页（50 条 → 逐页翻到 317 条）是最差场景，值得作为回归基准。
- 另一观察：UI 线程 BUILD 事件数（2183）多于光栅帧数（1699），约 28% 的 UI 帧没有对应的光栅帧（管线内被丢弃/合并）。该计数受事件配对影响，**仅作线索，不作为掉帧依据**；掉帧一列以引擎 `vsync_transitions_missed` 为准。

---

## 4. 后台：锁屏 3 分钟

### 场景 → 命令 → 原始数值

```bash
# 锁屏前（会话列表页）
adb -s "$D" shell cat /proc/net/tcp /proc/net/tcp6      # 统计 remote=:13A4(5028) 且状态 01
awk '$3 ~ /:13A4$/ && $4=="01"'                         # → 1 条（本机 192.168.0.102:B876 → 192.168.0.107:5028, uid 10369）
adb -s "$D" shell dumpsys batterystats --reset           # "Battery stats reset."（17:39:09）
adb -s "$D" shell input keyevent KEYCODE_SLEEP           # mWakefulness=Asleep
sleep 180
adb -s "$D" shell cat /proc/net/tcp /proc/net/tcp6       # → 0 条
adb -s "$D" shell dumpsys batterystats <pkg>             # 窗口 3m31s
adb -s "$D" shell dumpsys batterystats --checkin | grep ',10369'
```

| 观测点 | 时刻 | SSE/到实例的连接数（ESTABLISHED） |
|---|---|---|
| 锁屏前（列表页） | 17:39:09 | **1** |
| 锁屏 3 分 31 秒后 | 17:42:41 | **0** |
| 解锁后 3 秒（列表页） | 17:45 | **2**（自动重连；含 package:http 的 keep-alive，见下注） |
| 进入详情页 | 17:46 | **3**（列表 2 + `/live` 1） |

`dumpsys batterystats`（reset 后的 3m31s 窗口）：

```
  UID u0a369: 0.0000190 bg: 0.0000190 (4m 46s 128ms)     ← 用户态 CPU 19 µs 量级
  u0a369:
    (nothing executed)                                   ← 无 wakelock、无 service/job 启动
  --checkin--
  9,10369,l,awl,0,0                                      ← 唤醒闹钟 0 次
  （锁屏窗口内没有任何 Network / Wi-Fi / Mobile network 条目，reset 前同命令有 "Wi-Fi network: 4.00MB received"）
```

### 结论

- **锁屏即断开**：3 分钟窗口内 SSE 连接数 1 → 0，解锁后自动恢复（列表 2、详情 3）。后台不保活，**符合「不让 App 与插件在后台空转」的预期**。
- batterystats 侧同样干净：`u0a369: (nothing executed)`、`awl,0,0`（0 次唤醒闹钟）、无任何网络条目 → **窗口内 0 字节、0 唤醒**。
- **待确认（不是结论）**：列表页稳定态是 **2** 条到实例的连接，而 `docs/perf-audit.md` 的预期是 1 条（platform/stream）。详情页 3 条（预期 2 条）。多出的 1 条最可能是 `package:http` 的 keep-alive 复用连接，也可能是一次未取消的重复 SSE；`/proc/net/tcp` 无法区分两者，需要抓包或 `ss -tnp`（root）才能定论。**建议单列一项核查**（第 9 节 P4）。

---

## 5. 内存（`dumpsys meminfo <pkg>`）

### 场景 → 命令 → 原始数值

```bash
adb -s "$D" shell dumpsys meminfo love.mikumiku.chatluna_mobile | grep -E "TOTAL PSS|TOTAL RSS|Graphics:"
```

| 状态 | TOTAL PSS | TOTAL RSS | Graphics | 相对冷启动 | 超 120 MB 阈值 |
|---|---|---|---|---|---|
| **冷启动后列表**（`am force-stop` → 冷启动 → 8 s 静置） | **167.7 MB** | 316.7 MB | 65.5 MB | — | +40% |
| **详情首屏**（【mc服】300 条，进入 7 s 后） | **265.5 MB** | 438.1 MB | 70.1 MB | +97.8 MB | +121% |
| 另一会话首屏（艾欧尔 317 条） | 228.2 MB | 395.6 MB | 68.0 MB | +60.5 MB | +90% |
| **滚到顶**（已并入约 300 条 + 回弹） | **278.0 MB** | 452.1 MB | 70.7 MB | +110.3 MB | +132% |
| 详情滚回最新（内容全量驻留） | 283.1 MB | 457.2 MB | 68.9 MB | +115.4 MB | +136% |
| **退回列表**（详情页已出栈 3 s 后） | **261.6 MB** | 434.6 MB | 69.1 MB | +93.9 MB | +118% |

### 结论

- **唯一明确超标项**：PSS 全面超过 `perf-audit` 的 120 MB 目标，冷启动列表已达 167.7 MB，详情态 265–283 MB。
- 结构上 `Graphics` 占 65–71 MB（原生图形缓冲，进出详情页几乎不变，属基线成本），Java heap 仅 12–17 MB，Native heap 24–47 MB —— **剩余 ~190 MB 是 Flutter 引擎/渲染管线/native 分配**，不是 Dart 堆。
- 详情页出栈后 PSS 只回落 **21.4 MB**（283.1 → 261.6），**没有回到列表基线**（167.7）：说明消息列表/时间线/Markdown 树/图片缓存至少有一部分被保留（图片缓存 + 分配器未归还为主）。这是「越用越涨」的形态，建议按 P0 归因。
- 本机 MemTotal 15,561,772 kB（约 14.8 GB 可用）+ 系统未杀进程时不会表现为卡顿，但属于目标（≤120 MB）外的确定性超标。

---

## 6. 汇总：阈值判断

| 指标 | 实测 | 阈值 | 判断 |
|---|---|---|---|
| 冷启动 TotalTime 中位 | 414 ms（354–511） | ≤ 900 ms | **达标** |
| 热启动 TotalTime 中位 | 72 ms（65–82） | ≤ 300 ms* | **达标** |
| 首帧可见（`Displayed`） | = TotalTime（354–511 ms） | — | 与 TotalTime 同步 |
| 列表滚动整帧跨度 p95 / p99 | 4.24–4.28 / 5.38–5.58 ms | ≤ 11.1 ms（90 Hz 预算） | **达标** |
| 列表掉帧率 | 0.15%–0.29% | ≤ 5% | **达标** |
| 详情（含分页）整帧跨度 p95 / p99 | 4.52–4.93 / 6.14–6.60 ms | ≤ 11.1 ms | **达标** |
| 详情掉帧率 | 0.53%–0.68%（首屏起步那轮 2.2%） | ≤ 5% | **达标**，但单帧 build 峰值 13.6–23.7 ms **超预算** |
| 锁屏 3 分钟 SSE 连接数 | 1 → 0（解锁后自动恢复） | 0 | **达标** |
| 锁屏 3 分钟唤醒/网络 | 0 次唤醒闹钟、0 网络条目 | 0 | **达标** |
| PSS 冷启动列表 / 详情 / 滚到顶 / 回列表 | 167.7 / 265.5 / 278.0 / 261.6 MB | ≤ 120 MB | **全部超标**（+40% ~ +136%） |

\* 热启动无既定阈值，取 300 ms 作经验值。

---

## 7. 静态热点（只给位置与建议，未改代码）

> 定位口径：`build()` 及其同步调用链上的解析、正则、`DateTime.now()`、`jsonDecode`，以及会随消息条数线性/超线性增长的分配。

| # | 位置 | 现状 | 为什么是热点 | 建议 |
|---|---|---|---|---|
| H1 | `lib/features/chat/chat_page.dart:1908`（`build`）→ `:1789` `_timeline()` → `lib/features/chat/timeline.dart:76` | 每次 `build()` 都全量 `mergeTimeline(_messages, _framework)`：建索引 Map、给每条消息算排序行、排序、再遍历生成 items | 300 条时是每帧 O(n log n) + 3 个新列表；SSE 流式输出期间每帧都会走一遍 | 时间线移出 `build()`：在 `setState` 里（`_messages`/`_framework` 变化时）算一次存 `_items`，`build` 只读；或用 `(messages.length, lastId, framework.length)` 做记忆化键 |
| H2 | `lib/features/chat/timeline.dart:85`（H1 内每消息一次） | `final key = noticeKey(message.content)` = `content.replaceAll(RegExp(r'\s+'), '')` | 每帧对每条消息正文做一次正则替换；`noticeKey` 的另一处 `:172` 对每条 notice 再算一次 | 与 H1 一起缓存；`noticeKey` 结果随消息不可变，可存在 `PlatformMessage` 上或旁挂 Map 缓存 |
| H3 | `lib/features/chat/message_view.dart:107` | `CommandHelp.parse(body)` 在 `MessageView.build` 里对**整段正文**跑 `RegExp(r'chatluna\s+[a-z][a-z0-9_-]*')` 的 `allMatches` + 多次 `replaceAll` | 每条气泡每次重建都重新扫全文；正文越长越贵，而结果只依赖 `body` | 结果只依赖 `message.bodyMarkdown`：提到 `State`（`initState`/`didUpdateWidget`）或在 `ChatPage` 侧按 message id 记忆化 |
| H4 | `lib/features/chat/message_view.dart:1497` | `Notice.parse(widget.text)` 在 `FrameworkNoticeCard.build` 里：`split('\n')`、逐行 `_rule.hasMatch`、`sublist`、`_bracketHead` 匹配 | 框架卡片每次重建都重新解析全文；`Notice` 是纯函数结果 | 解析搬进 `State`（`initState` + `didUpdateWidget` 比较 `text`） |
| H5 | `lib/features/chat/message_view.dart:1631-1632` | `Notice.prettyJson(text)` 每次 build 都 `jsonDecode` 整段 + `JsonEncoder.withIndent('  ').convert`；失败再退 `isUrlList(text)`（`:1784`，逐行 `_url.hasMatch`） | 纯 CPU：JSON 解析+重排两遍，且对每条消息都先试一次 `jsonDecode`（即使不是 JSON） | 同样移进 `State`/记忆化；`isUrlList` 的逐行正则可先 `text.startsWith('http')` 快筛 |
| H6 | `lib/features/chat/message_view.dart:649`、`:661` | `RegExp(r'^data:image/[^;,]+;base64,')` / `RegExp(r'^base64:(?://)?')` 写在 **static 方法体内**，每次调用都新建并编译 | 图片气泡每次 build 都走 `_inlineBytes`/`_normalizeSource`，每次都 new 一个 RegExp | 提成 `static final` 字段（与 `:1670-1673` 的写法一致） |
| H7 | `lib/features/chat/chat_page.dart:2344` | `_DayDivider.build` 里 `final now = DateTime.now()` 再拼「今天/昨天/YYYY-MM-DD」 | 每帧、每个分隔条各调一次系统时钟并做日期差；也导致该子树无法 const | 在 H1 的时间线构建时把 label 一次性算好传进 `_DayDivider`（`showHeader` 同一趟已有 day 信息） |
| H8 | `lib/features/sessions/sessions_page.dart:950`、`:987` | 会话列表用 `ListView(children: [...])`，`for (final row in active) _tile(row, now)` 一次性构造**全部**会话行；`_partition()`（`:883`）每次 build 重新切分两段 | 当前 6 条无感，会话数到 50–100 时首帧与每次刷新都会全量构建（含头像、时间格式、Stack/Material） | 换成 `ListView.builder` / `SliverList.builder`（`itemCount` 由分组头 + 行数算），`_partition()` 结果缓存到 State |
| H9 | `lib/features/sessions/sessions_page.dart:938` | `if (_cursor != null) WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore())` 写在 build 里 | 每次 build 都注册一帧回调，加载中重复 build 会叠加多次 `_loadMore()`（内部有 `_loadingMore` 兜底，但回调本身仍反复入队） | 移到滚动到底的显式触发点（`ScrollController` 监听）或 `initState` 的一次性逻辑 |
| H10 | `lib/features/chat/message_view.dart:396-431` | `MarkdownWidget` 的 `MarkdownConfig` + `PConfig/ImgConfig/PreConfig/LinkConfig` + 多个 `TextStyle`/`BoxDecoration` **每次 build 新建** | 配置实例每帧变，外层无法缓存；`markdown_widget` 的解析与节点树构建随之重做，是气泡进视口时 build 尖峰的主要候选 | 把不依赖 `foreground` 的部分提为 `static final`；依赖 `foreground/theme` 的部分用 `late final`（在 `State` 里按 `Theme`/`foreground` 变化时才重建） |
| H11 | `lib/features/chat/chat_page.dart:2010` | `cacheExtent: 600`（反向列表，约 3 屏预建） | 首屏会预先构建屏幕外气泡（含 H10 的 markdown 解析），抬高详情首屏时间与 PSS | 降到 250–300 后重测首屏（第 5/3 节数据可作对照），若首屏 PSS/时间改善且上滑无白屏则保留 |

已确认**不是**热点的：`lib/features/chat/chat_page.dart:1778 _debugMetrics()` 仅在 `kDebugMode` 下工作（profile/release 返回 `const []`）；`timeline.dart`、`models.dart` 的 `static final` 正则只编译一次（H6 是例外）。

---

## 8. 结论（与建议分开）

1. **启动快，且稳定**：冷 414 ms / 热 72 ms，首帧可见时间＝Activity 首帧，无额外空窗。
2. **帧质量在稳态下很好**：列表与详情滚动的整帧跨度 p95 都在 4.5 ms 左右（预算 11.1 ms），掉帧率 ≤0.68%。
3. **单帧尖峰是真实存在的**：详情页 build 段最大 13.58 / 15.61 / 23.68 ms，均超过 11.1 ms 预算，且全部发生在「分页 setState 后重建」与「新气泡进视口」两种时刻；光栅段同期最大只有 6.5–8.1 ms。**优化方向是 UI 线程的重复解析/全量重建，不是渲染。**
4. **最差场景是「首次进详情页并向上翻到顶」**：掉帧率 2.2%（其他场景 0.15–0.68%）。
5. **内存是唯一全面不达标的指标**：167.7 → 283.1 MB，且退回列表只回落 21 MB。
6. **后台行为正确**：锁屏 3 分钟连接归零、0 唤醒、0 网络；解锁自动重连。
7. **两处「测不到/不确定」**：`gfxinfo` 口径对本 App 永久为空（改用引擎 timeline）；列表页连接数 2、详情 3，比预期各多 1 条，需进一步区分 keep-alive 与重复 SSE。

---

## 9. 建议修项（按影响排序）

| 优先级 | 修项 | 位置 | 依据 | 预期收益 |
|---|---|---|---|---|
| **P0** | 归因并压低 PSS：图片缓存上限、离开详情页后释放时间线/消息体 | `_ChatImageState`（`lib/features/chat/message_view.dart:670`，尺寸上限 `:672`）的解码/缓存路径、`chat_page.dart:429` 的 `_itemCache.clear()` 与 dispose 释放范围 | 第 5 节：详情 278–283 MB、回列表仍 261.6 MB（只回落 21 MB），`Graphics` 稳定 65–71 MB | 唯一硬超标项；也是「越用越涨」的唯一来源 |
| **P1** | 时间线移出 `build()` 并缓存 `noticeKey` | `chat_page.dart:1908` / `:1789`、`timeline.dart:76` / `:85` / `:172`（H1、H2） | 第 3 节 build max 13.58–23.68 ms 全部出现在分页重建；每帧全量 O(n log n) | 直接消掉分页后的重建尖峰，300 条场景每帧少一次排序 + 300 次正则 |
| **P2** | 三种「每 build 解析」改为一次解析 | `message_view.dart:107`（H3）、`:1497`（H4）、`:1631`（H5） | 第 3 节：气泡进视口的单帧 build 尖峰；这三处结果都只依赖不可变输入 | 降低上滑过程中偶发 13–15 ms 单帧，改善 2.2% 的最差场景 |
| **P3** | 会话列表改虚拟化 + `_partition` 缓存 + 去掉 build 内 `postFrameCallback` | `sessions_page.dart:950` / `:987`（H8）、`:883`、`:938`（H9） | 第 2 节：当前 6 条测不出问题，是**结构性风险**（会话数增长后必然 jank） | 会话数 50+ 时避免首帧与每次刷新全量构建 |
| **P4** | 核查列表页为何有 2 条到实例的连接（预期 1） | 连接建立/重连路径（`chat_page.dart:892`、`:963`、`:1338` 一带的 `/live` 与 platform stream 生命周期） | 第 4 节：列表 2、详情 3；锁屏后归零、解锁后恢复 | 少一条常驻连接＝少一份后端与手机侧开销；若真是重复 SSE，还可能有重复消息处理 |
| **P5** | `MarkdownConfig` 提为可复用实例 | `message_view.dart:396-431`（H10） | 与 P2 同源，但成本更大（整棵 markdown 树） | 降低气泡首次入视口的解析成本，是 P2 之后的下一个 build 热点 |
| **P6** | 正则提为 `static final` | `message_view.dart:649`、`:661`（H6） | 每张图片每次 build 都 new RegExp | 低风险微优化，顺手做 |
| **P7** | `cacheExtent` 600 下调后 A/B | `chat_page.dart:2010`（H11） | 首屏预建 3 屏气泡，含 markdown 解析 | 详情首屏时间/PSS 可能下降；需实测确认不出现上滑白屏 |
| **P8** | `_DayDivider` 用预计算的 `now`/label | `chat_page.dart:2344`（H7） | 每帧每分隔条一次系统时钟 + 日期差 | 极小，但可与 P1 一起做（零额外成本） |

---

## 10. 复现命令（最小集）

```bash
D='adb-10CF8403GA0049P-rYoZ2B (2)._adb-tls-connect._tcp'
P=love.mikumiku.chatluna_mobile

# 启动（冷/热各 3 次）
adb -s "$D" shell am force-stop $P; adb -s "$D" logcat -c
adb -s "$D" shell am start -W -n $P/.MainActivity
adb -s "$D" logcat -d | grep -E "Displayed love"
adb -s "$D" shell input keyevent KEYCODE_HOME
adb -s "$D" shell am start -W -n $P/.MainActivity            # LaunchState: HOT

# 帧（gfxinfo 为空是预期，用引擎 timeline 代替）
MSYS_NO_PATHCONV=1 cmd.exe /c "flutter.bat run --profile -d \"$D\""   # 输出 "A Dart VM Service ... is available at: http://127.0.0.1:<port>/<token>=/"
# 连 ws://127.0.0.1:<port>/<token>=/ws ，依次调用：
#   streamListen{streamId:"Timeline"} ; setVMTimelineFlags{recordedStreams:["Dart","Embedder","GC","API"]}
# 期间用 adb shell input swipe 打手势；按 (tid,name) 配对 B/E：
#   Dart|BUILD → build 耗时；Embedder|Rasterizer::DoDraw → 光栅耗时；
#   整帧跨度 = BUILD.start → DoDraw.end；掉帧 = Embedder|SceneDisplayLag 的 args.vsync_transitions_missed
adb -s "$D" shell dumpsys gfxinfo $P framestats                 # 恒为 0 帧（HWUI 未参与）

# 内存
adb -s "$D" shell dumpsys meminfo $P | grep -E "TOTAL PSS|TOTAL RSS|Graphics:"

# 后台
adb -s "$D" shell cat /proc/net/tcp /proc/net/tcp6              # remote 列 :13A4 且状态 01
adb -s "$D" shell dumpsys batterystats --reset
adb -s "$D" shell input keyevent KEYCODE_SLEEP; sleep 180
adb -s "$D" shell cat /proc/net/tcp /proc/net/tcp6
adb -s "$D" shell dumpsys batterystats $P | grep -E "u0a369|nothing executed"
adb -s "$D" shell dumpsys batterystats --checkin | grep ',10369,l,awl'
```

> 数据文件（按 1/2/3/4 节顺序采集，均为原始输出）已在采集后清理，本报告正文保留了每一项的判断所需的原始数值；`tmp/` 下的采集脚本亦已删除。
