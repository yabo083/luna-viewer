# 验收脚本

每条都是「跑一次就能判定」的检查，不依赖肉眼判断。

## 1. 静态

```powershell
flutter analyze     # 必须 No issues found
```

## 2. 服务端契约（在实例主机上，或任意能访问 5028 的机器）

```bash
T=<实例 token>
curl -s http://127.0.0.1:5028/api/health                      # {"ok":true,...}
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $T" http://127.0.0.1:5028/api/sessions   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5028/api/sessions                                # 401
curl -s -o /dev/null -w '%{http_code}\n' -H "Cookie: chatluna_session=x" http://127.0.0.1:5028/api/sessions  # 401（cookie 不授权 /api）
```

## 3. 会话闭环（App 内）

| 步骤 | 通过判据 |
|---|---|
| 连接 | 输入地址+token 后进入会话列表，标题栏无错误 |
| 新建 | 新会话出现在列表顶部，origin 为 `web` |
| 发消息 | 气泡逐字增长（`/live`），结束后内容与刷新后的历史一致 |
| 中止 | 生成中点停止，服务端 `running` 变 false（列表页圆点消失） |
| 断线 | 切飞行模式→恢复：出现「实时流不可用，改用轮询」并最终补全内容 |
| 只读 | 打开 `origin: satori` 的会话，输入框禁用并给出提示 |

## 4. 设备侧

```bash
adb devices -l                                  # 设备在线
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n love.mikumiku.chatluna_mobile/.MainActivity
adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png
```
