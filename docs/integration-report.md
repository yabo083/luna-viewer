# ChatLuna Mobile 端到端集成报告（v0.1.0 / debug）

- 日期：2026-11-19 21:04–22:06（设备本地时间）
- 设备：vivo V2425A（PD2425），Android 16，1080×2400；adb 序列 `10CF8403GA0049P`（USB）
- App：`love.mikumiku.chatluna_mobile` 0.1.0+1，debug 包；未执行 uninstall / pm clear，Secure Storage 内凭证未改动
- 实例：`192.168.0.107:5028`，`chatluna 2.0.0-alpha.0`
- 驱动方式：ADB 截图 + `uiautomator dump` 语义树；实时轮次通过服务端 `POST /api/sessions/:id/steer` 触发
- 证据截图：`tmp/shots/`（未改 `lib/`）

结论概览：连接、列表、详情、实时骨架/中止、断网自愈与消息补齐、主要菜单均跑通；**2 条失败**（生成中状态灯延迟、阶段明细不可达），**1 条环境/契约观察**（`/live` 在会话被服务端卸载后 404），**2 条未覆盖**（运行中分组排序、从本地移除）。

## 1. 连接

| 步骤 | 期望 | 实际 | 证据 | 结论 |
|---|---|---|---|---|
| 正确凭证已预置 | 启动直接进列表，无需重新登录 | 重装探针前后两次冷启动都直接进入会话列表，页头为 `会话`，无连接页；`/api/sessions` 仍带原 token 返回 200 | `tmp/shots/49-restored-auto-login.png`、`tmp/shots/50-force-stop-restart.png` | 通过（未登出） |
| 错误 token | 可读错误、不显示 token 明文 | 地址 `192.168.0.107:5028` + `BADTOKEN-LEAK-123`：token 框仍为 17 个掩码点，下方红字 `token 不对（服务端返回 401）`；语义树全文检索无 `BADTOKEN` | `tmp/shots/48-probe-wrong-token.png` | 通过 |
| 错误 token 的 API 语义 | 401 / UNAUTHORIZED | `GET /api/auth/session` → `401 {"code":"UNAUTHORIZED","message":"Your access token or session is invalid."}`；`GET /api/sessions` → 401 | 服务端 curl（本报告采集） | 通过 |

说明：为不影响已保存凭证，错误 token 项使用临时入口（`tmp/connect_probe.dart`，只复用真实 `ConnectPage`，`onConnected` 不落盘）编译安装；测完把安装前从设备 pull 的原始 APK 重新 `install -r -t`，Secure Storage 未触碰，随后自动登录成功。

## 2. 会话列表

| 步骤 | 期望 | 实际 | 证据 | 结论 |
|---|---|---|---|---|
| 排序 | 按最后消息时间倒序；运行中优先 | 最终 9 行：`22:03 / 22:01 / 22:00 / 21:57 / 21:57 / 21:34 / 20:48 / 20:21 / 19:56`，严格倒序；页头 `全部会话 9`。本轮没有任何 running 会话，运行中分组未出现 | `tmp/shots/55-final-list.png`、`tmp/shots/01-list.png` | 倒序通过；“运行中优先”未覆盖 |
| 未读/计数胶囊 | 右侧有未读计数胶囊 | 每行右端计数胶囊：`300 / 300 / 237 / 1 / 300 / 165 / 87 / 1 / 4`；测试期间同一行观察到 `319/320/315/304` 等不同值，且 21:57 出现新会话行（列表 8→9） | `tmp/shots/01-list.png`、`tmp/shots/55-final-list.png` | 通过（胶囊显示的是会话消息总数，App 无独立未读状态） |
| 下拉刷新 | 出现刷新指示，完成后列表仍可用 | 慢拖过程中截到顶部圆形刷新指示；松手后列表重建，`22:03` 的会话回到首位，无错误 | `tmp/shots/02-refresh-mid.png`、`tmp/shots/54-refresh-after-restart.png` | 通过 |
| 搜索过滤（标题） | 只留匹配行 | 输入 `webui` → `全部会话 2`，仅两条 webui；输入 `ch-03` → 1 行 | `tmp/shots/03-search-webui.png`、`tmp/shots/51-search-ch03.png` | 通过 |
| 搜索过滤（模型） | 可按模型过滤 | 输入 `deepseek` → 仅 `ch-03 (2657455842)` 1 行（该行模型 r4:deepseek-v4.1-flash） | `tmp/shots/04-search-model.png` | 通过 |
| 搜索空态 | 给“清空搜索”出口 | `zzzz` → `没有匹配的会话 / 换个关键词，或清空搜索查看全部活跃会话` + `清空搜索` 按钮 | `tmp/shots/05-search-empty.png` | 通过 |
| 主题三态 + 重进不丢 | 深色/浅色/跟随系统可切，重启后保留 | 设置抽屉显示 `主题 深色`；弹窗三态齐全；选 `跟随系统` 后重开抽屉确认 `主题 跟随系统`；切 `浅色` 后 `am force-stop` 冷启动仍为浅色；再切 `深色` 并确认 `主题 深色`，另一次 `am force-stop` 冷启动仍为深色 | `tmp/shots/06-settings-sheet.png`、`07-theme-dialog.png`、`56-theme-system-selected.png`、`09-theme-light.png`、`10-theme-light-persist.png`、`57-theme-dark-selected.png`、`50-force-stop-restart.png` | 通过 |

## 3. 会话详情

| 步骤 | 期望 | 实际 | 证据 | 结论 |
|---|---|---|---|---|
| 首屏 | 直接落到最新消息，图片可读 | 打开【mc服】牛马梦想家会所：顶部 `angela / qq / 未加载`，首屏即最后两条 20:41、20:58 的图片消息，图片正常解码显示，无空白占位 | `tmp/shots/12-chat-first-screen.png` | 通过 |
| 向上分页到顶 | 连续向上取更早页，直到最早一条 | 从 20:58 一路滚到 16:32，自动跨 6 页（服务端同 key 分页：6×50=300 条，唯一 id 300）；顶部出现 `今天` 分隔条与 Noah 16:32，再滚 3 次无更早内容，全程无“加载更早的消息失败”提示 | `tmp/shots/16-chat-top.png`、`tmp/shots/15-paged-2.png` | 通过 |
| 图文混排顺序 | 文字→图→文字保持原序 | 服务端顺序为 19:03:14 文本 → 19:03:17 图 → 19:03:25/39 文本；界面对应 `每一个人` → 19:03 图片 → `那直接起飞了`、`火车再也不会卡顿`、`机器再多也卡不到别人`，未被打乱 | `tmp/shots/14-mixed-text-image-text3.png` | 通过 |
| 单条消息内图文混排 | 同一 markdown 消息内文字-图-文字 | 21:28/20:32 的 bot 消息：正文 → 多张图 → 后续正文，气泡内顺序正确 | `tmp/shots/17-ch03-first-screen.png` | 通过 |
| 图片加载 | 缩略图正常显示 | QQ 头像与消息图片均显示；19:03、20:41、20:58 等图片有实际内容，无裂图占位 | `tmp/shots/12-chat-first-screen.png`、`17-ch03-first-screen.png` | 通过 |
| 长文本不溢出 | 长消息换行、不横向溢出 | 168 字图文消息、1500 字与 3000 字长文均按气泡宽度换行（外发 0.82 宽），未出现横向滚动/截断 | `tmp/shots/17-ch03-first-screen.png`、`tmp/shots/37-after-airplane.png`、`tmp/shots/52-ch03-after-restart.png` | 通过 |
| 返回后列表状态保持 | 返回列表不丢搜索/位置 | 搜索 `webui` 后打开第一条，返回后搜索词仍为 `webui`、结果仍为 2 行；本轮列表共 9 行可一屏显示，无可观察的滚动偏移 | `tmp/shots/30-search-before-open.png`、`tmp/shots/32-search-after-back.png` | 通过（搜索态）；滚动位置不适用 |

## 4. 实时（steer 驱动）

| 步骤 | 期望 | 实际 | 证据 | 结论 |
|---|---|---|---|---|
| 可驱动会话 | `/api/sessions` 有会话 | 测试开始时 1 条已加载会话 `route:r-4a066453788c:user:…:rab6c602f`，`running:false`；`POST /steer` 三次均 `202 {"accepted":true}` | 服务端 curl | 通过 |
| 骨架气泡 | 回复触发后时间线末尾出现骨架 | 出现 bot 侧骨架（两条灰条、主色描边），骑缝标签实时走动 | `tmp/shots/21-live-start.png`、`18-live-seq-08.png` | 通过 |
| 阶段标签 | `总时长 · 当前阶段 耗时` | 实测 `3.2s · 思考 2.6s`、`5.0s · 思考 4.4s`、`7.7s · 思考 5.9s`，秒级递增 | `tmp/shots/21-live-start.png`、`22-phase-tap.png`、`18-live-seq-08.png` | 通过 |
| 状态灯 | 1–3s 内转“思考中” | **失败**：3.2s、5.0s、7.7s 三张截图右上角仍是 `状态：待机`，与骨架里的“思考”矛盾；约 14s 后才见 `状态：思考中`。`docs/verification.md` 要求 1–3s | `21-live-start.png`、`22-phase-tap.png`、`18-live-seq-08.png`；14s 语义 dump 见正文 | **失败（中）** |
| Stop 中止 | 立即回待机、保留骨架与重发入口 | 生成中点 AppBar 中止：1.5s 后出现 `已中止 15.7s` + `重发这条`，骨架保留；服务端随后 `running:false`。状态灯当时显示 `轮询中`（该会话 `/live` 已 404，见下） | `tmp/shots/25-stop-after.png` | 通过（中止动作）/ 状态灯受 `/live` 影响 |
| 框架块/异常回显 | 已加载会话能补框架块 | 出现 `[skills update]`、`[tool update]`、`[memory]`、`[turn failed] No reply was produced…` 卡片，位置在本轮真实对话之前 | `tmp/shots/43-after-unlock.png` | 通过 |

注：一次 Stop 尝试被顶部弹出的 QQ 通知抢占，点到 QQ 群聊界面（`tmp/shots/23-stop.png` 记录为噪声）；App 未崩溃，返回后重跑成功，不计入结果。

## 5. 断网 / 锁屏 / 强制停止

| 步骤 | 期望 | 实际 | 证据 | 结论 |
|---|---|---|---|---|
| 飞行模式开 | 状态退到轮询，不崩 | 开启后 3s、12s 截图均为 `状态：轮询中`，消息仍可读，页面无错误页 | `tmp/shots/39-airplane-on-3s.png`、`40-airplane-on-12s.png` | 通过 |
| 飞行模式关 | 自愈、补消息、不重复 | 关闭约 6s 后状态回 `待机`；断网期间生成的 `OK`（21:36）出现在时间线末尾，服务端同 key 仅 1 条 `OK` | `tmp/shots/37-after-airplane.png`、`41-airplane-off-1.png` | 通过 |
| 锁屏 ≥2 分钟 | 回前台自愈、消息补齐、不重复 | 21:54 锁屏（`mWakefulness=Asleep`），21:56:34 steer，21:57:00 服务端生成 `OFFLINE-2`/`LOCK-2`，21:59:02 人工解锁；解锁后 `OFFLINE-2`、`LOCK-2` 各出现 1 次，`[skills update]`/`[tool update]`/`[memory]`/`[turn failed]` 也补齐；消息均只有一份 | `tmp/shots/43-after-unlock.png` | 通过（锁屏约 5 分钟） |
| `am force-stop` 重启 | 冷启动可用、不重复 | 22:03 force-stop → 重新启动：直接进列表（9 行、深色主题保持），打开 ch-03 后 `OK`、`OFFLINE-2`、`LOCK-2` 在可见语义中各自 1 个，无重复 | `tmp/shots/50-force-stop-restart.png`、`52-ch03-after-restart.png` | 通过 |
| 服务端卸载后的降级（观察） | 不应继续假装已加载 | 测试中服务端把该会话从 agent 运行时卸载：`/api/sessions` 仍短暂列出它，但 `/live`、`/events`、`/messages` 全部 404 `session does not exist or is not loaded`。App 停在 `轮询中`，仍显示已加载信息栏与中止/菜单；重启后 `/api/sessions` 为空，行变为 `未加载`，显示恢复正常 | `tmp/shots/45-status-now.png`；服务端 curl | 环境/契约观察（低） |

## 6. 菜单

| 步骤 | 期望 | 实际 | 证据 | 结论 |
|---|---|---|---|---|
| 会话详情 | 标题点开详情 | 点标题出现 `会话详情`：完整名称 `qq 私聊 664BAF4D09142330988FECAE7EA6B166`、会话 ID、平台 `satori`、引擎 `character`、模型 `r4:deepseek-v4.1-flash`，每行有复制按钮 | `tmp/shots/28-session-details.png` | 通过 |
| 会话菜单 | 压缩/分叉/重载 | 三点菜单：`压缩上下文`、`分叉到新会话`、`重新载入` 三项齐全（未执行前三项以免改动会话） | `tmp/shots/26-chat-menu.png` | 通过 |
| 模型选择 | 能看到 r4 三个模型 | 模型弹层按 provider 分组；滚到 `r4 / 3 / 当前`，下列 `deepseek-v4.1-flash`、`glm-5.3`、`glm-5.3-flash`，与服务端 `/api/models` 的 r4 三项一致 | `tmp/shots/27-model-picker.png`；语义 dump 记录 `r4 / 3 / 当前` | 通过 |
| 阶段明细 | 可从骨架标签打开 | **失败**：点击骑缝标签 `3.2s · 思考 2.6s` / `5.0s · 思考 4.4s` 无任何弹层；`showTurnPhases` 在 `lib/` 内没有调用点（仅 `chat_chrome.dart` 定义与 `_TurnPhasesSheet`），实际不可达 | `tmp/shots/22-phase-tap.png`（点后无变化） | **失败（中）** |
| 从本地移除文案 | 能看到并执行“从本地移除” | **未覆盖**：当前 9 个会话全部来自平台（qq/satori），`writable = origin == 'web'` 无一命中；长按分别提示 `该会话尚未被 ChatLuna 加载，只能查看消息。` 与 `平台会话（satori）由聊天软件管理，这里只能查看。`。`POST /api/sessions` 创建 web 会话返回 `403 {"code":"FORBIDDEN","message":"this route is disabled"}`，无法造出可移除会话。文案在 `sessions_page.dart:768`（从本地移除）、`:803`（已从本地移除；平台历史未删除…） | `tmp/shots/33-longpress-platform.png`、`34-longpress-loaded.png` | 未覆盖（环境禁止创建 web 会话） |
| 关于 | About 信息可读 | 弹窗：`ChatLuna`、`0.1.0`、`连接到自托管的 ChatLuna v2 实例`、`View licenses` / `Close` | `tmp/shots/35-about.png` | 通过 |

## 失败与最小复现

### F1（中）生成开始后状态灯长时间停在“待机”
- 现象：骨架标签已显示 `思考 2.6s`，信息栏却仍 `状态：待机`；3.2s、5.0s、7.7s 三帧均如此，约 14s 后才变 `思考中`。`docs/verification.md` 的状态灯判据是 1–3s。
- 最小复现：打开已加载会话 → 服务端 `POST /api/sessions/:id/steer {"text":"请写一篇 3000 字中文长文"}` → 触发后每 0.3s 截图 → 观察右上角状态灯与骨架标签。
- 证据：`tmp/shots/21-live-start.png`、`22-phase-tap.png`、`18-live-seq-08.png`。
- 判断：状态灯走 `/live`，骨架/阶段走 `/events`+计时；`/live` 的 active snapshot 到达明显晚于 turn_start。需确认是服务端快照延迟还是 App 只在 snapshot 时刷状态。

### F2（中）“阶段明细”面板不可达
- 现象：骨架骑缝标签无点击响应；`showTurnPhases(context, view)` 在 `lib/` 内没有调用点，`_TurnPhasesSheet` 永远不会被打开。
- 最小复现：已加载会话触发一轮 → 等骨架与读秒出现 → 点击标签 → 无弹层。
- 证据：`tmp/shots/22-phase-tap.png`（点击前后同一画面，仅读秒变化）；代码 `lib/features/chat/chat_chrome.dart:433` 定义、全仓无调用。

### 观察（低，环境/契约）会话被服务端卸载后 App 仍保持“已加载”
- 现象：`/api/sessions` 仍列出会话的短时间内，`/live`、`/events`、`/messages` 都返回 404 `session does not exist or is not loaded`；App 显示 `轮询中` 且继续给出中止/菜单，直到重启后 `/api/sessions` 为空才降级为 `未加载`。
- 证据：`tmp/shots/45-status-now.png`、服务端 curl。
- 影响：消息仍由平台流可读；中止会走 404。属于服务端“已加载”语义不一致，App 的降级只在重启/刷新后发生。

## 未覆盖

| 项 | 原因 |
|---|---|
| 运行中分组排序（绿色竖条/运行灯） | 本轮所有列表观测时刻都没有 `running=true` 的会话；已加载会话只用于详情与 steer，未在运行中回到列表截图 |
| “从本地移除”实际执行 | 无 `origin=web` 会话；服务端创建 web 会话的 `POST /api/sessions` 路由被禁用（403） |
| 列表滚动位置保持 | 最终 9 行一屏可容纳；改用“搜索词+结果保持”验证返回态 |
| 未读 FAB 徽标（详情页） | 测试期间页面始终贴底自动跟随，新消息到达未产生“离底未读”场景 |

## 证据目录

- 列表/主题：`tmp/shots/01-list.png`、`tmp/shots/02-refresh-mid.png`、`tmp/shots/03-search-webui.png`、`tmp/shots/04-search-model.png`、`tmp/shots/05-search-empty.png`、`tmp/shots/06-settings-sheet.png`、`tmp/shots/07-theme-dialog.png`、`tmp/shots/56-theme-system-selected.png`、`tmp/shots/09-theme-light.png`、`tmp/shots/10-theme-light-persist.png`、`tmp/shots/57-theme-dark-selected.png`、`tmp/shots/50-force-stop-restart.png`、`tmp/shots/55-final-list.png`
- 详情/分页：`tmp/shots/12-chat-first-screen.png`、`tmp/shots/14-mixed-text-image-text3.png`、`tmp/shots/15-paged-2.png`、`tmp/shots/16-chat-top.png`、`tmp/shots/17-ch03-first-screen.png`
- 实时/中止：`tmp/shots/21-live-start.png`、`tmp/shots/22-phase-tap.png`、`tmp/shots/18-live-seq-08.png`、`tmp/shots/25-stop-after.png`
- 菜单：`tmp/shots/26-chat-menu.png`、`tmp/shots/27-model-picker.png`、`tmp/shots/28-session-details.png`、`tmp/shots/33-longpress-platform.png`、`tmp/shots/34-longpress-loaded.png`、`tmp/shots/35-about.png`
- 断网/锁屏/重启：`tmp/shots/37-after-airplane.png`、`tmp/shots/39-airplane-on-3s.png`、`tmp/shots/40-airplane-on-12s.png`、`tmp/shots/41-airplane-off-1.png`、`tmp/shots/43-after-unlock.png`、`tmp/shots/49-restored-auto-login.png`、`tmp/shots/52-ch03-after-restart.png`
- 错误 token：`tmp/shots/48-probe-wrong-token.png`（token 全程掩码；临时入口测试后已还原原 APK，未登出）

清理：临时驱动脚本、探针入口、从设备 pull 的备份 APK 已删除；`build/app/outputs/flutter-apk/app-debug.apk` 已用正式入口重新构建，避免残留探针包。未修改 `lib/`。

