# 骨架气泡的两个 bug：复现、根因、改法、验证

设备：`10CF8403GA0049P`（V2425A，1080×2400，DPR 3）。
实例：`192.168.0.107:5028`，会话 `route:r-4a066453788c:…:rab6c602f`（私聊）与
`route:r-260382ae685a`（群聊）。所有截图/录像都来自这一台真机，没有任何模拟数据。

两个 bug 都在同一条链上：**骨架气泡是列表里的一格，它的出现/消失/尺寸变一点点，
整段消息都会跟着上下跳**。

---

## 1. 复现（修复前）

### 1.1 骨架在等首个 token 时整段消失

复现步骤（release 0.1.0 装机版，2026-11-20 00:10）：

1. 打开私聊会话，`POST /api/sessions/:id/steer`：
   `画一张赛博朋克城市夜景，画完再用两句话点评一下。`
2. 每 0.7s 截一帧：`tmp/repro/before1/f01..f22.png`（本机临时目录，`tmp/` 不进库）。

帧序列（对上一轮那条 bot 气泡做模板匹配，dy = 它在画面里的 y 偏移）：

| 帧 | 时间 | 骨架 | 上一条消息 dy |
|---|---|---|---|
| f01 | 0.0s | 有（`3.0s`） | 0 |
| f02 | 0.7s | 有（`3.0s`） | 0 |
| **f03** | **1.4s** | **没有**（计时表读数 `0.0s`，新的一轮刚开） | **+39** |
| f04 | 2.1s | 没有 | +39 |
| f05 | 2.8s | 没有 | +39 |
| f06 | 3.5s | 有（`5.6s · draw 5.6s`） | 0 |
| f07–f22 | 4.2s–14.9s | 有 | 0 |

也就是说：**这一轮在 3 秒左右被收表了**，骨架连同它占的那一格一起消失，等下一步
（draw 之后的新 step）开表才重新插回来——用户看到的就是「draw 完、等 reply 的那段
时间里骨架屏不见了」。同一现象在用户提供的截图上更直观（`25.4s` 那一轮 draw 14.5s）。

### 1.2 上一条消息被挤动

同一段录屏里，骨架在场时（f06–f22）上一条消息的 dy 恒为 0；但**每个 step 边界**
（`settled` → `_live` 回到待机 → 下一步再点亮）整段消息会跳 16dp：

| 帧 | 时间 | `_live` | 上一条消息 dy |
|---|---|---|---|
| f24–f25 | 0.0–0.5s | 思考中（有生成） | 0 |
| f26–f34 | 1.0–5.0s | 思考中 | **−48**（= 16dp × DPR 3，被一条空的流式格顶上去） |
| f35–f40 | 5.5–8.0s | 待机（step 之间） | 0 |

证据：`tmp/repro/after1/f26.png` 与 `f35.png`（同一轮，只差一个 16dp 的空格子）。
骨架本身的位置不动（标签行 `y=2029..2057` 全程不变），说明跳动来自列表里**另一格**。

---

## 2. 根因

### 2.1 `settle` 是「这一步说完了」，不是「这一轮结束了」

`/events` 实测（2026-11-20 00:40 一轮，turn 39）：

```
00:39:46.451 agent/input-enqueued  target=next-step
00:39:46.481 engine/activity      prepare   turn=39
00:39:46.497 engine/activity      generate  turn=39
00:39:57.388 (draw 执行中 …)
00:40:22.945 (draw 执行中 …)
00:40:35.940 chat/delivered       ×2
00:40:36.459 engine/activity      settle    turn=39
```

异步工具（draw）执行期间**一个 attempt 都没有**：模型这一步早就 `settle` 了，引擎只是
在等工具把结果交回来。旧代码把 `engine/activity settle` 当成 `running=false` 的最早证据，
`TurnClock` 再用「停了 + 3s 宽限」这条 `resolveTurnEnd` 分支收表：

- `_maybeFinish` → `finished = true` → `_onClockTick` → `_endSkeleton` → hold 0.5s → fade → 移除骨架。
- 下一步开跑时 `start()` 递增 round，`_onClockTick` 再把骨架插回来。

这就是 1.1 里那 2 秒空窗。用户等首个 token 的时间，恰好全在这个空窗里。

### 2.2 列表第二格（流式正文）空着也占 16dp

`_liveSlot` 原来是 `Padding(top:16) → Column(children:[if (_live.generating) …])`，
正文还没来的时候它是一条 16dp 的空白。每个 step 的 `settled` 都会把 `_live` 打回待机
（这一格被移出 `itemCount`），下一步再点亮（又插回来）——列表高度在 16dp 上来回变，
所有消息跟着跳。

### 2.3 骑缝计时标签的宽度跟着读数走

`TurnClockLabel` 只有 `minWidth: 96`，没有上限、没有省略：`9.9s` → `10.0s`、
`draw` → `draw 12.3s` 都会把盒子撑宽。它虽然在 `Positioned` 里（不参与 Stack 布局），
但任何一处跟着读数变宽的盒子都是隐患——一旦哪天被放进正常流里，整条骨架的行宽就变了。

---

## 3. 改法

只动 `lib/**` 与 `test/**`，插件/服务端零改动。

### 3.1 `lib/features/chat/turn_clock.dart`：终点判定不再靠「停了多久」

```dart
// 还在干活就不收表：attempt 在跑，或工具（draw 等）还没把结果交回模型。
if (_attemptActive || _openTools.isNotEmpty) return;
// 终点必须有真实外发：本轮一条 bot 气泡都还没落库时，任何「停了」都不算终点。
final end = resolveTurnEnd(stoppedAt: _stopAt, deliveredAt: _deliveredAt);
```

- `resolveTurnEnd` 去掉 `grace` 分支：`stoppedAt == null || deliveredAt == null` → 无终点。
  「停了 N 秒就当结束」正是把 draw 执行期判成结束的那条规则。
- 新增 `attemptStarted()` / `attemptEnded()`：`/live` 的 active 快照、delta、tool-input、
  reasoning 开；`assistant-settled`、空 attempt 快照关。attempt 在跑时 `_stopAt` 清零。
- `_toolPhases` 改成 `_openTools`：`phase(tool: true)` 进，`finishTool()`（= 下一个 step
  开始）出。工具开着时同样不收表。
- 收表时一并清掉 `_openTools` / `_attemptActive`。

### 3.2 `lib/features/chat/chat_page.dart`：把 attempt/工具的活信号接给计时表

`/live` 的 snapshot / delta / reasoning / tool / settled，`/events` 的 `prompt`、
`prepare|generate`、`agent/input-admitted`、`settle` 都按上面两条规则打点。
`settle` 只记「停了」，收不收表由计时表自己按「外发已落库 + 没有 attempt/工具在跑」判。

### 3.3 `lib/features/chat/chat_page.dart`：流式格没正文时 0 高

```dart
Widget _liveSlot(ThemeData theme) => ValueListenableBuilder<String>(
  valueListenable: _streamingText,
  builder: (context, text, _) => text.isEmpty
      ? const SizedBox.shrink()
      : Padding(padding: const EdgeInsets.only(top: 16), child: …),
);
```

`_live` 在思考中/待机之间怎么切都不再改列表高度；正文一到，这一格才有高度。

### 3.4 `lib/features/chat/chat_chrome.dart`：标签定宽 + 文字自适应

- 盒子固定 `TurnClockLabel.boxWidth = 132`（原来是 `minWidth: 96`，无上限）。
- 文字 `maxLines: 1, softWrap: false` 外面套 `FittedBox(fit: scaleDown)`：
  读数比盒子长时整体等比缩小，**不裁数字**、也不把布局推出去。

### 3.5 行为变化（有意的）

「这一轮一条外发都没有」时不再靠宽限自动收表：模型真的崩了/空回复，骨架会停在
「思考中 N s」，中止按钮仍然可点（`_turnActive` 由计时表驱动），用户中止后骨架转入
「已中止 N s + 重发这条」。宁可留着可操作的骨架，也不能在用户等待时把它撤掉。

---

## 4. 验证

### 4.1 静态与单测

```
flutter analyze   → No issues found!
flutter test      → All tests passed!（140 个，新增 4 个）
```

新增用例：

- `test/turn_clock_test.dart`
  - `attempt 还在跑时不收表：settle 与投递都到了也等它收尾`
  - `draw 执行期间（settle 已到、下一步还没开）不收表`
  - `本轮还没有外发时，停多久都不算终点`
  - `resolveTurnEnd` 的宽限分支删除后，原来的「等满 grace 再收表」用例改为断言「永远不收」。
- `test/turn_label_test.dart`
  - `读数变长变短都不改标签尺寸：盒子宽度恒定，文字缩在里面`（`1m04s · draw 21.6s` 与
    `9.9s · 思考 9.9s` 两种读数的控件尺寸完全相等）。

### 4.2 真机 A：steer 后 12 帧（0.5s/帧）

录制：`adb shell screenrecord --time-limit 50`，抽帧 2fps，
帧 `tmp/repro/frames2/001..100.png`。

骨架判定：骨架标签用主色 `#5B8DEF`，聊天区底部（y 1500–2250）没有第二处这个颜色，
所以「该区域主色像素 > 80」= 骨架在场（无骨架的帧实测为 0）。

对齐：帧 011 的标签读 `0.6s` ⇒ 计时表零点在视频 4.4s；
服务端 `agent/input-enqueued` = 00:39:46.451 ⇒ 视频 4.37s（steer 落地）。
视频 0 点 ≈ 00:39:42.1。

| 视频时间 | 帧 | 骨架 | 说明 |
|---|---|---|---|
| 0.0–4.0s | 001–009 | 无 | steer 还在队列里（状态灯 `轮询中`），服务端没开轮 |
| 4.5s | 009 | 无 | prepare 前 0.1s |
| **5.0s** | **010** | **有**（`0.6s · 思考 0.1s`） | 计时表开表，骨架插入 |
| 5.5–10.0s | 011–020 | 有 | 读数一路走 |
| 10.5–49.5s | 021–099 | 有 | 跨过 draw 的 settle、轮询读到 `running=false`、下一步开跑 |

**steer 后 12 帧（帧 009–020）里 11 帧有骨架**（唯一没有的那帧在 prepare 前 0.1s）。
插入 1 次、重新插入 0 次。帧 010 是一次性插入位移（−40px，新气泡该占的高度），
之后 011–099 的**逐帧 y 偏移全部为 0**（sad ≤ 0.4）。

### 4.3 真机 B：一整轮（draw → reply → 首条气泡落库）

另录一条 90s：`tmp/repro/frames3/001..184.png`（同样 0.5s/帧）。
服务端 marks：`input-enqueued/prepare` 00:44:26.9 → 首条 bot 气泡 00:45:11
（视频 76.5s）→ `chat/delivered` 00:45:34.9。

| 视频时间 | 帧 | 骨架 | 备注 |
|---|---|---|---|
| 0.0–32.0s | 001–064 | 无 | steer 在服务端排队（这一轮 admission 用了 ~30s，与 App 无关） |
| 32.5s | 065 | **有** | 插入 1 次 |
| 33.0–76.0s | 066–153 | **有**（89 帧连续） | 读数 `0.8s → 43.8s · reply 2.1s`，中途一次没掉 |
| 76.5s | 154 | 无 | 真实气泡（书店图 + 两行文字）上屏，骨架让位 |

- 骨架在场 44.0s，覆盖 `draw` 执行期（无 attempt）、下一步开跑、正文流式到达。
- 重新插入 0 次。
- 逐帧 y 偏移：插入（065，−39）与首条气泡落库（154，+40）各一次性位移，其余全 0。

### 4.4 真机：上一条消息不再被挤动

同一个 App、同一段对话，修复前后各一组数据（模板 = 上一条 bot 气泡的正文）：

| | 帧 | 上一条消息 dy |
|---|---|---|
| 修复前 | f24→f25 | 0 |
| 修复前 | f26–f34 | **−48**（空流式格 16dp × DPR 3） |
| 修复前 | f35–f40 | 0（step 之间格子被移出） |
| 修复后 | 011–099 / 066–153 | **全程 0** |

### 4.5 截图证据

`docs/evidence-skeleton/`：

- `before-skeleton-gone.jpg`：修复前 f03——draw 期间骨架消失、整段消息下沉。
- `before-skeleton-back.jpg`：修复前 f06——下一步开跑，骨架又插回来。
- `before-live-slot-shift.jpg`：修复前 f26——空流式格把消息顶高 16dp。
- `after-skeleton-steady.jpg`：修复后 45s 长生成，骨架一直在、读数在走。
- `after-43s-turn-skeleton-up.jpg`：修复后整轮第 43.8s（`43.8s · reply 2.1s`）骨架仍在。
- `after-first-bubble-lands.jpg`：同一条录屏的下一帧——真实气泡上屏，骨架同时让位。

---

## 5. 排查记录（为什么不是别的原因）

- **不是 `_stampTurnEnd` 的脚注**：脚注只在 `finished` 那一刻盖一次，且伴随骨架撤场；
  时间线里 f06–f22 上一条消息 dy 恒 0。
- **不是 `AnimatedSize` 的淡出**：淡出只在 `holding` 500ms + 180ms 内发生，且高度由
  骨架自己收，不会动别人。
- **不是计时标签把上一条消息挤动**：标签在 `Positioned` 里，不参与 Stack 尺寸；
  实测标签行 y 全程不变。但它的宽度确实跟着读数变，属于同一类隐患，一起改掉了。
- **不是 `/live` 掉线本身**：这一轮全程 `轮询中`（`/live` 没接上），骨架照样在，
  说明兜底轮询的 `running=false` 也被计时表正确挡住了。
