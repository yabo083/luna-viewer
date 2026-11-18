# 验收脚本

每条都是「跑一次就能判定」的检查，不依赖肉眼判断。

## 1. 静态

```powershell
flutter analyze     # 必须 No issues found
flutter test        # 必须 All tests passed（含 test/timeline_test.dart 的时间线合并）
```

## 2. 构建（Windows）

```powershell
flutter build apk --debug
```

被打断的构建会在 `build/<plugin>/kotlin/...` 留下无法关闭的增量缓存（报 `Could not close incremental caches … class-fq-name-to-source.tab`）。
处理：`gradlew --stop` → 删 `build/`、`android/.gradle/` → 重跑（`android/gradle.properties` 已设 `kotlin.incremental=false`）。

## 3. 服务端契约（在实例主机上，或任意能访问 5028 的机器）

```bash
T=<实例 token>
curl -s http://127.0.0.1:5028/api/health                      # {"ok":true,...}
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $T" http://127.0.0.1:5028/api/sessions   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5028/api/sessions                                # 401
curl -s -o /dev/null -w '%{http_code}\n' -H "Cookie: chatluna_session=x" http://127.0.0.1:5028/api/sessions  # 401（cookie 不授权 /api）
curl -s -H "Authorization: Bearer $T" http://127.0.0.1:5028/api/platform/conversations                          # {"items":[…]}，按最后消息倒序
curl -s -H "Authorization: Bearer $T" 'http://127.0.0.1:5028/api/platform/messages?key=<key>&limit=5'           # {"items":[时间升序],"hasMore":bool}
```

## 4. 会话闭环（App 内）

| 步骤 | 通过判据 |
|---|---|
| 连接 | 输入地址+token 后进入会话列表，标题栏无错误 |
| 新建 | 新建的 web 会话出现在列表（插件里没有它时用 App 侧的紧凑标题） |
| 发消息 | 气泡逐字增长（`/live` 临时气泡），结束后由 `/api/platform/stream` 换成正式消息，列表页计数 +1 |
| 状态灯 | 在 QQ 里发一句后回到页面：状态灯在 1–3s 内从「待机」变「思考中」（`/live` 的 reasoning/tool 帧或 `running` 兜底），有正文 delta 时变「回复中」，`settled` 或 bot 气泡落地后回「待机」 |
| 本轮计时 | 回复触发后消息末尾出现骨架气泡，计时标签骑在描边上并逐秒走动（`4.5s · 思考 2.8s`，整轮在前、当前阶段在后）；真实气泡到达后骨架撤场，外发气泡右下脚注保留 `00:49 · 9.4s` 总时长 |
| 中止 | 生成中停止按钮可点：成功立即回「待机」（不等服务端 settled）并清掉流式气泡；失败弹 SnackBar 显示 `code：message`；服务端 `running` 变 false（列表页圆点消失） |
| 断线 | 切飞行模式→恢复：状态转「轮询中」，回前台自动重连 `/live` 并拿新快照；恢复后由平台流补全消息且无重复 |
| 只读 | 打开未加载的会话（`/api/sessions` 没有它）：无信息栏、无中止/压缩/分叉/切模型，只能读消息 |
| 左右分栏 | bot 的回复（`dir=out`）在右、主色气泡；其他人（`dir=in`）在左、中性气泡；两侧 markdown 与图片都能渲染，图片点开全屏 |
| 框架块 | 已加载会话里出现 wake / memory 卡片（居中单卡）；`chatluna help` 之类指令只出现一次（气泡，不是卡片）；未加载会话没有框架块 |
| 框架块位置 | 同一轮里 `[skills update]` / `[tool update]` / `[memory]` 卡片排在这一轮真实对话**之前**，与会话日志的顺序一致（不沉到列表底部）；同一时刻的平台消息在卡片之前 |
| 框架块翻页 | 向上翻两页后同一条框架卡与相邻两条消息的相对顺序不变（锚点不漂） |
| 归档 | 最后一条消息超过 72 小时的会话从主列表消失、出现在底部「归档 · N」里；在归档里打开照常可读；收到新消息后自动回到主列表 |
| 分页 | 长会话向上滚到最早一条：取回更早一页，首条时间不重复，滚到底仍有内容 |

## 5. 设备侧

```bash
adb devices -l                                  # 设备在线
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n love.mikumiku.chatluna_mobile/.MainActivity
adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png
```
