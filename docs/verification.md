# 验收脚本

每条都是「跑一次就能判定」的检查，不依赖肉眼判断。

## 1. 静态

```powershell
flutter analyze     # 必须 No issues found
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
| 中止 | 生成中点停止，服务端 `running` 变 false（列表页圆点消失） |
| 断线 | 切飞行模式→恢复：状态回到待机，恢复后由平台流补全消息且无重复 |
| 只读 | 打开未加载的会话（`/api/sessions` 没有它）：无信息栏、无中止/压缩/分叉/切模型，只能读消息 |
| 分页 | 长会话向上滚到最早一条：取回更早一页，首条时间不重复，滚到底仍有内容 |

## 5. 设备侧

```bash
adb devices -l                                  # 设备在线
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n love.mikumiku.chatluna_mobile/.MainActivity
adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png
```
