# 性能复测报告（2026-11-19，修复后）

> 口径：**只测不改**。本轮只写本文件，未改 `lib/`、未改测试。
> 对照基线：`docs/perf-report.md`（下称「基线」）；改动记录：`docs/perf-fixes.md`（下称「修复」）。
> 设备：vivo V2425A（PD2425，SM8650），Android 16 / API 36，`wm size` 覆盖 1080×2400，
> 刷新率 90–120 Hz 自适应（实测 82–89 fps 窗口，帧预算 11.1 ms）。
> 实例：`192.168.0.107:5028`（已登录实例，凭证保留，安装用 `adb install -r`，未 uninstall / 未 pm clear）。
> 设备标识：`adb -s "adb-10CF8403GA0049P-rYoZ2B (2)._adb-tls-connect._tcp"`。

## 0. 结论摘要

| # | 指标 | 基线 | 本轮复测 | 判定 |
|---|---|---|---|---|
| 1 | 冷启动 `am start -W` 中位 | 414 ms | **375 ms**（8 次；后 6 次 360–422） | **持平**（+9% 好，但首两次含安装预热 528/520 ms） |
| 2 | 热启动 `am start -W` 中位 | 72 ms | **75 ms** | 持平 |
| 3 | 列表滚动整帧跨度 p95 / p99 | 4.24–4.28 / 5.38–5.58 ms | **4.00–4.11 / 4.58–5.65 ms** | 持平（略好） |
| 4 | 列表滚动掉帧率 | 0.15%–0.29% | **0–0.19%** | 持平 |
| 5 | 详情「首屏 → 首次翻到顶」掉帧率 | **2.2%**（最差轮）/ 0.53%（主测轮） | **0.36%–0.80%（中位 0.50%）** | **改善**（相对 2.2% 改善约 4 倍） |
| 6 | 详情单帧 `Dart\|BUILD` 峰值 | 13.58 / 15.61 / 23.68 ms（均 > 11.1） | **3.39–8.41 ms**（每帧 build 合计最大 7.5–9.0 ms） | **改善**（全部回到预算内） |
| 7 | 详情整帧跨度 p95 / p99 | 4.52–4.93 / 6.14–6.60 ms | **6.18–6.32 / 7.24–9.24 ms** | **恶化**（仍在 11.1 内；原因见 §7.1） |
| 8 | PSS 列表 / 详情首屏 / 滚到顶 / 回列表 | 167.7 / 265.5 / 278.0 / 261.6 MB | **166.8 / 244.8 / 259.6 / 237.3 MB** | 详情三项改善（-18 ~ -24 MB），仍全部超 120 MB 目标 |
| 9 | 到 `:5028` 的连接数：列表 / 详情 | 2 / 3 | **1 常驻（偶发第 2 条）/ 2** | **改善**（详情修复生效） |
| 10 | 切后台收敛 / 回前台重建 | 锁屏 3 min：1→0，解锁 2/3 | HOME 8 s：**0**；回前台：列表 1、详情 2 | 达标（本轮未复跑 3 min 锁屏窗口，见 §8） |
| 11 | 头像加载稳定性（用户观察） | — | 反复加载 | **新增副作用**，见 §7.3 |

---

## 1. 测量口径（与基线的差异必须先说明）

### 1.1 构建与安装

```bash
cd E:/Codes/AI/projects/chatluna-mobile
MSYS_NO_PATHCONV=1 cmd.exe /c "flutter.bat build apk --profile --target-platform android-arm64"
adb -s "$D" install -r build/app/outputs/flutter-apk/app-profile.apk   # 42.5 MB, 18:12 构建, 18:13 安装
```

安装包时间戳（18:12）晚于修复落地的最后改动（`chat_page.dart` 18:06、`sessions_page.dart` 18:06），
因此**本轮 APK 包含全部修复**；上一轮基线包（17:31）不含。

### 1.2 帧数据来源（同基线替代口径，接入方式不同）

`dumpsys gfxinfo … framestats` 对本 App 仍然恒为 0 帧（Flutter 走 Impeller，不进 HWUI），
所以继续用 Dart VM Service 的 Timeline 流。基线用 `flutter run --profile` 打印 URL；
本轮改为**直接给 profile 进程加引擎参数**，避免重装与长连接：

```bash
adb -s "$D" shell am start -n $P/.MainActivity \
    --ez disable-service-auth-codes true --ez enable-dart-profiling true
# 进程 listening 端口（uid 10369，0100007F:xxxx）
adb -s "$D" shell cat /proc/net/tcp /proc/net/tcp6 | awk '$4=="0A" && $8=="10369" {print $2}'
adb -s "$D" forward tcp:<port> tcp:<port>
# ws://127.0.0.1:<port>/ws
#   streamListen{streamId:"Timeline"}
#   setVMTimelineFlags{recordedStreams:["Dart","Embedder","GC","API"]}
```

事件处理与基线一致：`Dart|BUILD` 的 B/E 配对、`Embedder|Rasterizer::DoDraw` 的 B/E 配对、
`Embedder|SceneDisplayLag` 的 `args.vsync_transitions_missed`。本轮对口径有两处**修正**（基线未写明，按此重算才可比）：

| 项 | 修正 | 影响 |
|---|---|---|
| 掉帧计数 | 每条 `SceneDisplayLag` 会以异步事件 `ph=b` 与 `ph=e` 各上报一次（同一 `id`），两份都带 `vsync_transitions_missed`。**按 `id` 去重（只取 `b`）** | 若基线未去重，其「9 帧 / 21 帧」应对折为 4.5 / 10.5 帧；本轮所有掉帧数均已去重 |
| 整帧跨度 | 一个 Flutter 帧里可能出现**多个** `Dart|BUILD`（首帧 buildScope 之外，`SliverList` 滚动时在 LAYOUT 内再次 `buildScope`）。本轮定义：**整帧跨度 = 该帧第一个 BUILD 的起点 → 该帧 `Rasterizer::DoDraw` 的结束**；同时给出「紧耦合子集」（`DoDraw.start − 最后一个 BUILD.end < 3 ms`），用于把「UI 工作量」与「排空间隙」分开 | 见 §4.3：紧耦合子集 p95 4.24–4.80 ms 与基线持平，差值全部落在排空间隙 |

### 1.3 手势与窗口

* 列表：20 × `input swipe 540 1900 540 500 70`，间隔 0.12 s（在设备端一发脚本执行，避免每条 adb 进程开销）。
* 详情：40 × `input swipe 540 500 540 2250 35`，间隔 0.26 s（快档，≈10.5 s）或 0.55 s（慢档，≈27 s，贴近基线 17.9 s 的分页节奏）。
* 每次采集前 `+400 ms` 预热，手势结束 `+600 ms` 收尾。

### 1.4 一次作废的采集（必须披露）

计划中的第 3 次详情采集在运行中途前台被别的 App 抢走（米家 / QQ 出现在前台），
`dumpsys window` 证实窗口已不是本 App，该轮数据作废（`tmp` 已删）。
之后采集脚本加了**前置前台校验**：`dumpsys window` 不含 `love.mikumiku.chatluna_mobile` 就退出、不发手势。
本节后续所有数值都来自通过前台校验的窗口；列表 3 轮在进程重启（带 VM service 参数）后紧接着执行。
详情 4 轮：`topA` 采集前后都校验；`topB` 采集后校验、`topS1` 采集前校验（导航步骤刚确认过）；
`top2` 无显式校验，但紧接着的截图仍在本 App 详情页内，帧率/分布与另两轮一致，按参考值列出。

---

## 2. 启动

```bash
adb -s "$D" shell am force-stop $P; adb -s "$D" logcat -c
adb -s "$D" shell am start -W -n $P/.MainActivity
adb -s "$D" logcat -d | grep "Displayed $P"
adb -s "$D" shell input keyevent KEYCODE_HOME; adb -s "$D" shell am start -W -n $P/.MainActivity
```

### 冷启动（8 次，均为 COLD）

| 次数 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| TotalTime | 528 | 520 | 422 | 377 | 365 | 372 | 369 | 360 |
| `Displayed` | +528 | +520 | +422 | +377 | — | — | — | — |

* 8 次中位 **375 ms**；剔除安装后前两次（528/520，dex/页面缓存未热）后 6 次区间 **360–422 ms，中位 370 ms**。
* 基线 414 ms（4 次：511 / 354 / 414 / 382，其中 511 也是安装后首次）。
* `Displayed` 与 `TotalTime` 仍逐次相同 → 首帧可见＝Activity 首帧，没有额外动画空窗。

### 热启动（3 次，均为 HOT）

| 次数 | 1 | 2 | 3 | 中位 |
|---|---|---|---|---|
| TotalTime | 67 | 83 | 75 | **75** |
| WaitTime | 70 | 85 | 77 | 77 |

**判定：持平。** 冷启动稳定态比基线略快（370 vs 414 ms），但安装后的第一、二次仍会到 520 ms 量级，
与基线首次 511 ms 属同一现象；热启动 75 vs 72 ms 在噪声内。

---

## 3. 列表快速滑动 20 次

```bash
# 采集脚本（tmp/rc/timeline.dart）在 VM service 连接后，向设备一发执行：
# input swipe 540 1900 540 500 70; sleep 0.12; ×20
```

| 运行 | 帧数 | 时长 | fps | build p95 / max | 光栅 p95 / p99 / max | **整帧跨度 p50 / p95 / p99 / max** | 掉帧 |
|---|---|---|---|---|---|---|---|
| A1 | 514 | 6.22 s | 82.7 | 0.30 / 2.39 | 3.33 / 3.94 / 5.62 | 3.20 / **4.11** / **5.65** / 6.66 | 1（**0.19%**） |
| A2 | 510 | 6.11 s | 83.4 | 0.28 / 0.61 | 3.36 / 4.32 / 4.99 | 3.19 / **4.10** / **5.09** / 5.81 | 0（0%） |
| A3 | 515 | 6.23 s | 82.7 | 0.28 / 2.38 | 3.22 / 3.62 / 3.96 | 3.16 / **4.00** / **4.58** / 5.38 | 0（0%） |
| 基线 B | 683 | 7.7 s | 88.6 | 0.60 / 2.52 | 4.21 / 4.40 / 4.79 | 3.27 / 4.28 / 5.38 / 6.06 | 1（0.15%） |
| 基线 C | 692 | 7.9 s | 87.7 | 0.55 / 2.32 | 3.36 / 4.40 / 8.61 | 3.24 / 4.24 / 5.58 / 9.83 | 2（0.29%） |

**判定：持平（略好）。** p95 4.00–4.11 ms（基线 4.24–4.28），p99 4.58–5.65（基线 5.38–5.58），掉帧 0–0.19%。

> 限制不变：会话列表当前只有 **7 条**，视口未满，20 次滑动大部分落在回弹动画上。
> 因此本轮**不能**验证修复里「列表改 `ListView.builder`」的收益（P3），见 §8。

---

## 4. 详情：首屏 → 滚到顶（300 条）

会话：【mc服】牛马梦想家会所（测试时 300–307 条，直播群，测量期间仍有新消息）。
每次采集前都从列表**重新进入**该会话（首屏只取 50 条，`_pageSize = 50`），因此每次都是「首次向上翻页」。

| 运行 | 帧数 | 时长 | fps | build 单段 p95 / max | build 每帧合计 p95 / max | 光栅 p95 / p99 / max | 整帧跨度 p50 / p95 / p99 / max | 紧耦合子集 p95 / p99 | 掉帧 |
|---|---|---|---|---|---|---|---|---|---|
| 快档 #1 | 1399 | 15.63 s | 88.9 | 1.01 / **6.22** | 1.39 / 8.88 | 3.28 / 4.01 / 6.06 | 3.27 / **6.31** / **7.53** / 20.05 | 4.24 / 5.13 | 7（**0.50%**） |
| 快档 #2 | 1373 | 15.63 s | 87.9 | 0.85 / **8.41** | 1.27 / 8.98 | 3.57 / 4.71 / 17.55 | 3.21 / **6.32** / **9.24** / 25.65 | 4.48 / 6.15 | 11（**0.80%**） |
| 快档 #3 | 1380 | 15.70 s | 87.9 | 1.03 / **3.39** | 1.34 / 7.47 | 3.25 / 3.97 / 5.16 | 3.21 / **6.18** / **7.24** / 19.40 | 4.24 / 5.13 | 5（**0.36%**） |
| 慢档 #1 | 2232 | 27.25 s | 81.9 | 0.87 / **4.27** | 1.18 / 8.22 | 3.81 / 4.96 / 7.87 | 3.10 / **6.24** / **8.17** / 19.27 | 4.80 / 6.16 | 15（**0.67%**） |
| 基线「滚到顶」 | 1699 | 17.86 s | 95.1 | 0.69 / **13.58** | — | 3.50 / 4.25 / 6.54 | 3.25 / 4.52 / 6.14 / 9.02 | — | 9（0.53%） |
| 基线「反向回最新」 | 1626 | 18.98 s | 93.1 | 0.96 / **15.61** | — | 3.22 / 4.32 / 6.28 | 3.05 / 4.93 / 6.60 / 8.60 | — | 11（0.68%） |
| 基线「首屏起步缓滑」（另一会话 317 条） | 943 | 13.3 s | 71 | 1.22 / **23.68** | — | 3.95 / 4.84 / 8.06 | 3.02 / 4.54 / 5.84 / 24.20 | — | 21（**2.2%**） |

### 4.1 「首次翻到顶」是否从 2.2% 降下来

**是。** 4 轮 0.36% / 0.50% / 0.67% / 0.80%，中位 **0.50%**；基线最差轮 2.2%，主测轮 0.53%。
掉帧全部是单帧事件，没有连续掉帧：4 轮 `vsync_transitions_missed` 合计 5 / 7 / 15 / 12，
对应掉帧帧数 5 / 7 / 15 / 11（只有快档 #2 有一帧丢了 2 个 vsync）。

### 4.2 单帧 build 峰值

单段 `Dart|BUILD` 最大 3.39–8.41 ms，每帧所有 BUILD 合计最大 7.47–8.98 ms，**全部 ≤ 11.1 ms**；
基线同一位置是 13.58 / 15.61 / 23.68 ms。**判定：改善，修复的 P1/P2 生效。**

### 4.3 整帧跨度（整条流水线）的尾部

* 整帧跨度 p95 6.18–6.32 ms、p99 7.24–9.24 ms、max 19–26 ms；基线 p95 4.52–4.93、p99 6.14–6.60、max 9.0。
  **判定：恶化**（绝对值仍全部在 11.1 ms 预算内，且同窗口掉帧率更低）。
* 把「UI 已完成、光栅还没开始」的帧排除后（紧耦合子集），p95 4.24–4.80 / p99 5.13–6.16 —
  **与基线一致**。说明差值不在 build，而在 `build 结束 → DoDraw 开始` 这一段：
  该间隙 p95 1.6–2.6 ms、p99 11.9–16.3 ms、max 33–34 ms，**2.5%–4.8% 的帧 > 3 ms**。
  这属于 UI→光栅线程的排队/调度，不是 Dart 侧工作量。

---

## 5. 内存（`dumpsys meminfo`）

```bash
adb -s "$D" shell dumpsys meminfo $P | grep -E "TOTAL PSS|TOTAL RSS|Graphics:"
```

| 场景 | 基线 PSS | 复测 PSS | Δ | 基线 Graphics | 复测 Graphics |
|---|---|---|---|---|---|
| 冷启动后列表（8–12 s） | 167.7 MB | **166.8 MB**（170.8 / 162.7，中位） | ≈0 | 65.5 | 64.0–64.2 |
| 详情首屏（【mc服】300 条，进入 7 s） | 265.5 MB | **244.8 MB** | **-20.7 MB（-7.8%）** | 70.1 | 87.7 |
| 另一会话首屏（艾欧尔；基线 317 条 / 复测 301 条） | 228.2 MB | 216.4 MB | -11.8 MB | 68.0 | 66.3 |
| 滚到顶（并入约 300 条 + 回弹，3 s 后） | 278.0 MB | **259.6 MB** | **-18.4 MB（-6.6%）** | 70.7 | 87.8 |
| 退回列表（详情出栈 3 s 后） | 261.6 MB | **237.3 MB** | **-24.3 MB（-9.3%）** | 69.1 | 87.9 |

**判定：改善但未达标。** 仍是 120 MB 目标的 1.4–2.2 倍；三项详情态各降 18–24 MB，
但**结构性问题没变**：

* 详情 → 列表只回落 **22.3 MB**（基线 21.4 MB）→「越用越涨」的形态还在。
* 详情态 `Graphics` 反而比基线高 17.6 MB（87.7 vs 70.1）。收紧解码尺寸后同样内容占用更小、
  `ImageCache` 能装下更多张，`Graphics` 上升、`Native/Java` 下降，总量仍是降的；
  也可能与测试时该会话里长图/表情比基线多有关（300→307 条，图片占比更高）。
* 分类 PSS 的完整表（Java/Native/Code…）未逐项抄录，只取 TOTAL 与 Graphics。

---

## 6. 到 `:5028` 的连接数

```bash
# 远程端口 5028 = 0x13A4，状态 01 = ESTABLISHED
adb -s "$D" shell cat /proc/net/tcp /proc/net/tcp6 | awk '$3 ~ /:13A4$/ && $4=="01" {print $2, $3}'
```

| 时刻 | 基线 | 复测 | 说明 |
|---|---|---|---|
| 冷启动后列表静置 8 s | 2 | **1** | 连续 4 次采样均为 1 条（本地端口 8A82 不变） |
| 列表静置（另一次会话，12 s 内 6 次采样） | 2 | **1 常驻 + 偶发第 2 条** | 第 2 条本地端口每 3–6 s 变一次（E990 常驻；C3CA→BFB6→…），6 次里 3 次可见；22 s 静置后仍是「1 + 偶发 1」 |
| 进入详情 5–7 s | 3 | **3–4（瞬时）** | 含 `/live`、`/events` 建立期与一次请求连接 |
| 详情静置 20 s | 3 | **2** | 本地端口 859A / 859C 稳定不变（详情平台流 + `/live`） |
| 详情页 HOME 后 8 s / 18 s | 锁屏 3 min：0 | **0 / 0** | 立即归零，不保活 |
| 列表页 HOME 后 8 s / 23 s | — | **0 / 0** | 同上 |
| 回前台（列表） | 2 | **2 → 8 s 后 1** | 重建流后 keep-alive 退出 |
| 回前台（详情） | 3 | **2（6 s）** | |
| 详情返回列表 | — | **3 → 4 s 后 1** | 详情流销毁 + 列表流重建 |

**判定：改善。** 修复里「列表页在路由被盖住时断流」生效了：详情页从 3 条降到 2 条（构成变为
详情平台流 + `/live`，`/events` 只在建立期短暂出现）。列表页从基线的「2 条」变成
**1 条常驻 SSE + 周期性短连接**——第 2 条不是第二条 SSE（端口每次新建），更像是 SSE 帧触发的
`/api/sessions` 补齐（5 s 节流）走了一条新 TCP，与修复文档 §5 的判断一致，但**没有达到**
文档里「静置 20 s 只剩 1 条」的期望值（见 §7.4）。

---

## 7. 未达预期项与原因

### 7.1 整帧跨度 p95/p99 比基线差（6.2/7.2–9.2 ms vs 4.5/6.1–6.6 ms）

* 不是 UI build：同窗口每帧 build 合计最大 7.5–9.0 ms，单段最大 8.4 ms，都在 11.1 ms 内。
* 差值集中在 `最后一个 BUILD 结束 → DoDraw 开始`：p99 11.9–16.3 ms，2.5%–4.8% 的帧 > 3 ms。
  紧耦合子集的跨度 p95 4.24–4.80 / p99 5.13–6.16，与基线一致。
* 造成这段排空间隙的原因本轮未定位（可能的光栅线程排队、present/GPU fence、系统调度）。
  测量期间设备并非空闲：一次采集因前台被米家抢走而作废，随后又在 QQ 前台时读到错误的窗口
  状态——后台负载会放大这类间隙，但这是推测，**未做对照实验**。
* 结论：**UI 线程侧的重复解析/全量重建确实被消掉了（build 峰值达标），剩下的抖动在排空间隙。**

### 7.2 掉帧率没有低于基线的 0.53%

0.36–0.80%（中位 0.50%）与基线主测轮持平，只把最差的 2.2% 拉平。
这说明掉帧的**剩余来源不是 build 尖峰**，与 §7.1 的排空间隙一致；进一步压掉帧要动渲染/调度侧，
不是本轮的解析缓存。

### 7.3 头像加载不稳定 / 反复加载（用户观察，未量化）

现象（用户报告）：详情页与会话列表的头像加载不稳定、反复加载。本节给出**代码侧可解释的成因**，
不做结论性归因（没有抓包/请求计数，无法区分「重复下载」与「重复解码」）：

1. **全局解码缓存的容量被收紧**：`main.dart` 把 `imageCache.maximumSize` 从 1000 降到 **120 条**、
   `maximumSizeBytes` 从 100 MB 降到 **64 MiB**。头像是「URL × 解码宽度」一条 entry，
   同一 URL 在不同尺寸位置（28/32/40 dp → 84/96/120 px）各占一条；被 LRU 淘汰后再进视口就重新解码，
   源站若不发强缓存则同时重新下载——表现为「老是重复加载」。
2. **切后台会清空整个 ImageCache**：`chat_page.dart:_pauseStreams()` 里
   `PaintingBinding.instance.imageCache.clear()`。切一次后台/被别的 App 盖住，回来所有头像与图片重新解码。
3. **头像没有过渡帧**：`Image.network(..., cacheWidth:)` 没有 `frameBuilder`、没有 `gaplessPlayback`，
   缓存未命中的那几帧是透明空窗 → 视觉上「闪一下再出来」。
4. 头像解码宽度随 `size` 变化（`assistant_avatar.dart:35`、`message_view.dart:308/381`），
   同一 URL 的缓存 key 分裂成最多 3 份，等于把第 1 条里 120 条容量的压力再放大数倍。

建议（下一轮，本轮不改代码）：把头像的解码宽度固定成一个档位、给头像单独的 `Image.network`
加 `gaplessPlayback: true` / `frameBuilder` 保上一帧；`maximumSize` 提到 300–500（字节上限保持 64 MiB）；
`_pauseStreams` 里若只想丢「无人监听」的图，可用 `imageCache.clearLiveImages()` 而不是 `clear()`。

### 7.4 列表页仍有周期性的第二条连接

常驻 1 条 SSE 已确认；第 2 条的本地端口每 3–6 s 变一次，且只在有流帧/补齐请求时出现，
与「SSE 帧触发的 `/api/sessions` 补齐（5 s 节流）+ 每次新 TCP」吻合。
未达到修复文档 §5 表格里「列表页静置 20 s → 1」的稳定值（采样时仍是 1–2 条）。
未进一步区分「keep-alive 复用失败」与「服务端 `Connection: close`」——需要 root 的 `ss -tnp` 或抓包。

### 7.5 冷启动首两次 520/528 ms

安装（18:13）后立即测的前两次都在 520 ms 量级，第 3 次落到 422，之后稳定在 360–377 ms。
与基线首次 511 ms 同类，属安装后的 dex/页面缓存预热。判定为**持平**，不是回归。

---

## 8. 未测到 / 未覆盖

| 项 | 原因 |
|---|---|
| `dumpsys gfxinfo` 口径 | 同基线：Flutter 用 Impeller 自绘，`framestats` 恒为 0 帧（本次未再复跑确认，属已知结论） |
| Dart heap / `imageCache.currentSizeBytes` | 本轮未带 `disable-service-auth-codes` 的进程（冷启动测量用普通 `am start`）返回 **403 missing or invalid authentication code**；带该参数的进程在采集结束后已随冷启动重启。profile/product 模式下 `evaluate` 是否可用也未验证 |
| 锁屏 3 分钟窗口（batterystats 0 唤醒 / 0 网络） | 本轮按任务只测「切后台 / 回前台」，未复跑 3 min 锁屏窗口 |
| 会话数 100+ 的列表虚拟化（修复 P3 / H8） | 设备上只有 7 个会话，未造数据 ⇒ `ListView.builder` 的收益**未验证** |
| `cacheExtent` 600 → 300 的 A/B（修复 P7） | 修复本轮未做该项，复测也无从对比 |
| 头像「重复下载」与「重复解码」的区分 | 未抓包、未计数请求；仅凭代码路径解释（§7.3） |

---

## 9. 复现命令（最小集）

```bash
D='adb-10CF8403GA0049P-rYoZ2B (2)._adb-tls-connect._tcp'
P=love.mikumiku.chatluna_mobile
cd E:/Codes/AI/projects/chatluna-mobile

# 0) 构建 + 安装（只 install -r，不 uninstall）
MSYS_NO_PATHCONV=1 cmd.exe /c "flutter.bat build apk --profile --target-platform android-arm64"
adb -s "$D" install -r build/app/outputs/flutter-apk/app-profile.apk

# 1) 启动（冷：先 force-stop；热：先 HOME）
adb -s "$D" shell am force-stop $P; adb -s "$D" logcat -c
adb -s "$D" shell am start -W -n $P/.MainActivity
adb -s "$D" logcat -d | grep "Displayed $P"
adb -s "$D" shell input keyevent KEYCODE_HOME
adb -s "$D" shell am start -W -n $P/.MainActivity

# 2) 帧：profile + 无鉴权 VM service
adb -s "$D" shell am force-stop $P
adb -s "$D" shell am start -n $P/.MainActivity --ez disable-service-auth-codes true --ez enable-dart-profiling true
PORT=$(adb -s "$D" shell cat /proc/net/tcp /proc/net/tcp6 \
       | awk '$4=="0A" && $8=="10369" {print $2}' | cut -d: -f2)
adb -s "$D" forward tcp:$((16#$PORT)) tcp:$((16#$PORT))
# 连 ws://127.0.0.1:<port>/ws：
#   streamListen{streamId:"Timeline"}; setVMTimelineFlags{recordedStreams:["Dart","Embedder","GC","API"]}
# 手势窗口内配对 Dart|BUILD 的 B/E、Embedder|Rasterizer::DoDraw 的 B/E；
# 整帧跨度 = 该帧首个 BUILD.start → DoDraw.end；
# 掉帧 = Embedder|SceneDisplayLag 的 args.vsync_transitions_missed（按事件 id 去重，只取 ph=b）。
# 手势（在设备端一发执行，避免每条 adb 进程开销）：
#   列表：input swipe 540 1900 540 500 70; sleep 0.12;  ×20
#   详情：input swipe 540 500 540 2250 35; sleep 0.26;  ×40
# 采集前先校验前台：
adb -s "$D" shell dumpsys window | grep mCurrentFocus | grep -q chatluna || echo "非本 App，放弃本轮"

# 3) 内存（四场景：列表 / 详情首屏 / 滚到顶 / 回列表）
adb -s "$D" shell dumpsys meminfo $P | grep -E "TOTAL PSS|TOTAL RSS|Graphics:"

# 4) 连接数（远程 5028 = 0x13A4）
adb -s "$D" shell cat /proc/net/tcp /proc/net/tcp6 | awk '$3 ~ /:13A4$/ && $4=="01" {print $2}'
# 后台/前台切换：
adb -s "$D" shell input keyevent KEYCODE_HOME; sleep 8   # 期望 0
adb -s "$D" shell am start -n $P/.MainActivity; sleep 6  # 期望重建
```

> 采集脚本与全部 raw 事件（约 150 MB）都在 `tmp/rc/`，按约定已删除；本报告正文保留了
> 每一项判断所需的全部数值与口径定义。
