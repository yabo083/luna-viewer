# 集成测试修复（2026-11-19）

依据 `docs/integration-report.md` 的三项失败/观察项。

## 1. 状态灯滞后（中）

**原问题**：生成开始后 3.2/5.0/7.7 s 仍显示「待机」，约 14 s 才「思考中」。原因：状态灯只由 `/live` 帧驱动，QQ 会话的 `/live` 常常一帧不发，只能等 6 s 探测 + 3 s 轮询。

**改法**：
- 新增 `statusLightFor(live, optimisticThinking, polling)`：`/live` 有阶段就按阶段；否则只要「本轮计时表已开表且 `/live` 尚未给出停止结论」或「入站后 6 s 无帧」就亮「思考中」；再退到「轮询中」「待机」。
- 计时表每个轮次首次开表时清 `_liveSettled`（tick 不反复点灯）；`_setLive(idle)`、settle、无 attempt 的快照都会把它收掉，避免投递等待期闪回。
- 中止按钮的可用性判定不变（仍只认计时表与 `_live`），乐观亮灯不会放开 Stop。

**验证**：`test/turn_clock_test.dart` 既有用例 + 新 widget 用例；真机 steer 后 1–3 s 内应为「思考中」。

## 2. 阶段明细不可达（中）

**原问题**：`showTurnPhases` 无调用点，点骨架标签无反应。

**改法**：
- 抽 `TurnClockLabel`（`chat_chrome.dart`）：视觉尺寸不变（11sp 等宽、贴边压描边），命中区 52 dp（Material 最小触控 44 dp 向内扩）；带 `Semantics(button, label: '阶段明细 …')`。
- 骨架气泡的骑缝标签换成该组件，点击打开 `showTurnPhases`；
- 信息栏新增一枚可点的耗时胶囊（`_TurnPill`），骨架撤场后仍能回看本轮/上一轮阶段明细；读数由计时表自己刷新，整页不随 tick 重建。

**验证**：`test/turn_label_test.dart`（点击触发、无读数不拦点击）；真机点标签应弹出明细。

## 3. 会话被服务端卸载后卡「轮询中」（低）

**原问题**：`/api/sessions` 仍短暂列出，但 `/live`、`/events`、`/messages` 全 404；App 停在「轮询中」并保留已加载 UI。

**改法**：`_handleSessionUnloaded()`——收到 `isNotFound` 时取消 `/live`、`/events`、探测与轮询，清流式缓冲，计时表 `stopped()` 收尾，`_session = null`（收起信息栏/中止/菜单），提示一次「会话已在服务端卸载」；不再自动重挂（`_sessionGone` 闸门），回列表重开会重新问一次加载态。

**验证**：真机上让服务端卸载会话后进详情，应降级为「未加载」且不再轮询；重启后行为一致。

## 回归

`flutter analyze` 零问题；`flutter test` 136 项全绿（含新增 `turn_label_test.dart`）。
