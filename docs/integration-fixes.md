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

## 真机验证（2026-11-19 22:43–22:57）

设备 `10CF8403GA0049P`（V2425A，USB），服务端 `192.168.0.107:5028`。

| 项 | 方法 | 结果 | 证据 |
| --- | --- | --- | --- |
| 构建 | `flutter build apk --debug --target-platform android-arm64` | 成功；`app-debug.apk` 162,211,903 B，mtime 22:43:44 | `build/app/outputs/flutter-apk/app-debug.apk` |
| 静默安装 | `adb push … /data/local/tmp/clm.apk` + `pm install -r -t`，`verifier_verify_adb_installs=0` | `Success`（整条命令 31.6 s）；`lastUpdateTime=2026-11-19 22:53:22` 与构建时间对得上；未 uninstall / pm clear | `dumpsys package love.mikumiku.chatluna_mobile` |
| 凭证保留 | 冷启动（force-stop 后 `am start`） | 直接进「会话」列表，`全部会话 10`，无登录/连接页 | `tmp/verify-r3/01-launch.png`、`03-relaunch-list.png` |
| 打开会话（未加载态） | 列表点「webui」（platform `web`，key `r-90887e65ce6d`） | 详情页显示 `angela / web / · 未加载`，仅一条平台历史消息；无 Flutter 异常（logcat 过滤 `exception|error|fatal` 为空） | `tmp/verify-r3/02-conversation.png`、`04-conversation-final.png` |
| 状态灯「思考中」 | 需已加载会话 + `POST /api/sessions/:id/steer` | **未覆盖**：22:52:10 `GET /api/sessions` → `{"items":[]}`（200）、`GET /api/agents` → `[]`（200）；`POST /api/sessions` 创建 web 会话 → `403 {"code":"FORBIDDEN","message":"this route is disabled"}`（全局路由 `chat.engine.mode: silent`）；对 unloaded id 直接 `POST /api/sessions/r-90887e65ce6d/steer` → `404 session does not exist or is not loaded` | 服务端 curl（本条时间戳 22:52–22:56） |
| 骑缝标签点开阶段明细 | 同上，需一轮真实生成产生骨架 | **未覆盖**（同一原因） | — |
| 404 降级回归 | 需「先已加载、后被服务端卸载」的会话 | **未覆盖**（当前没有已加载会话） | — |

结论：构建、静默安装、凭证保留、未加载态渲染在真机上通过；状态灯与阶段明细两项修复**未取得真机证据**，原因是服务端当前没有任何已加载会话，且 web 会话创建被路由配置禁用（`403 this route is disabled`）。待下一次 QQ agent 认领会话（bot 实际参与一轮对话后 `GET /api/sessions` 出现 `items`）时，按 `integration-report.md` 第 5 节最小复现补测：steer 后 1–3 s 内截图看状态灯、点骨架骑缝读秒标签看明细弹层。

## 真机复核（2026-11-19 23:04–23:37）

补测上一节标记「未覆盖」的两项。设备 `10CF8403GA0049P`（USB），实例 `192.168.0.107:5028`，私聊会话 `route:r-4a066453788c:user:664BAF4D09142330988FECAE7EA6B166:rab6c602f`（列表 `ch-03 (2657455842)`）已加载且 `running=false`。

### 构建与安装

| 项 | 方法 | 结果 | 证据 |
| --- | --- | --- | --- |
| 构建（当前源码） | 删掉旧产物后 `flutter build apk --debug --target-platform android-arm64` | `✓ Built`；`app-debug.apk` 162,211,903 B，mtime 2026-11-19 23:04 | `build/app/outputs/flutter-apk/app-debug.apk`、`tmp/verify-light/build-install.txt` |
| 静默安装 | `adb push … /data/local/tmp/clm.apk`（2.3 s）+ `pm install -r -t`（3.7 s） | `Success`；`lastUpdateTime=2026-11-19 23:05:00`，`firstInstallTime` 仍为 2026-11-18 16:48:20（未 uninstall / pm clear）；`verifier_verify_adb_installs=0`；打开即会话列表，凭证保留 | `dumpsys package love.mikumiku.chatluna_mobile`、`tmp/verify-light/build-install.txt` |

### 1. 状态灯在 steer 后 1–3 s 内转「思考中」

- **期望**：`POST /api/sessions/:id/steer` 后 1–3 s 内，信息栏状态灯为「思考中」，不再长时间停在「待机」。
- **实际**（以 POST 发出为 t=0，逐帧截图；t 取 `adb screencap` 采集时刻）：
  - 基线：进入详情后灯「待机」、无计时胶囊 —— `tmp/verify-light/08-baseline.png`
  - steer `{"text":"请用一句话介绍你自己"}` → `202 {"accepted":true}`，响应耗时 88 ms。
  - +0.31 s：灯「思考中」，骨架骑缝 `0.6s · 思考 0.0s` —— `tmp/verify-light/steer2_1.png`
  - +0.74 s：灯「思考中」，`1.0s · 思考 0.4s` —— `tmp/verify-light/steer2_2.png`
  - +1.15 s：灯「思考中」，`1.4s · 思考 0.8s` —— `tmp/verify-light/steer2_3.png`
  - +2.41 s：灯「思考中」，`2.7s · 思考 2.1s` —— `tmp/verify-light/steer2_6.png`
  - +3.25 s：灯「思考中」，`3.5s · 思考 2.9s` —— `tmp/verify-light/steer2_8.png`
- **达标**：是。最早一帧 0.31 s 已亮「思考中」，1–3 s 窗口内各帧全部为「思考中」，与骨架里的「思考」阶段一致；修复前实测 3.2/5.0/7.7 s 仍「待机」、约 14 s 才变。

### 2. 骨架骑缝计时标签点开阶段明细

- **期望**：点骨架气泡骑缝上的计时标签 → 弹出本轮阶段明细。
- **实际**：
  - steer `{"text":"请用大约400字描写深夜城市的雨景，分三段。"}` → 202；+1.6 s 截到骨架与骑缝标签 `1.8s · 思考 1.2s`（信息栏同时有 `1.8s · 思考` 胶囊）—— `tmp/verify-light/10-skeleton.png`
  - 在标签位置 tap（1080×2400 下 x=413, y=2058，即 52 dp 命中区中心）：底部弹出明细「本轮 2.3s / 当前 思考 / 还没有完成的阶段 / 阶段可能并行：各自耗时之和可以超过整轮。」—— `tmp/verify-light/11-phases-tap.png`
- **达标**：是（弹层标题的时间与点按时刻的读秒一致，确认走的是这一轮的 `TurnClockView`）。

### 复现步骤

1. 启动 App → 打开列表顶部已加载的 `ch-03`，确认灯「待机」、信息栏无计时胶囊。
2. `curl -X POST -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d '{"text":"请用一句话介绍你自己"}' "http://192.168.0.107:5028/api/sessions/<urlencoded id>/steer"`
3. 0.3–3 s 内 `adb exec-out screencap -p`：状态灯应为「思考中」，列表末尾出现骨架，骑缝为 `总时长 · 阶段 耗时`。
4. 再 steer 一句更长的（400 字），骨架出现后 1–3 s 内点骑缝标签（1080×2400 约 x=413, y=2058）→ 底部弹出阶段明细。

### 备注：一次作废的尝试（不计入结论）

23:33 首测时该会话正被 QQ 侧遗留的长轮（含 `draw` 工具，服务端 `running=true`）占着；steer 注入已运行的轮次、App 收不到新的 turn_start，+4.3 s 仍为「待机」，约 +12.7 s 才因兜底探测转「轮询中」，信息栏读数还是上一轮冻结的 `36.9s · draw`。等 `running=false` 后重开详情再测，即得上表结果。该现象属于「中途插话」而非新轮次起点，不作为本次两项修复的判据。
