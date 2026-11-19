# Luna Viewer 0.1.0 — 发布记录

首个带真机验证的 release。

## 产物

| 项 | 值 |
| --- | --- |
| 版本 | `0.1.0`（`pubspec.yaml` 与 `update_checker.dart` 的 `appVersion` 一致） |
| versionCode | `2001`（`android/app/build.gradle.kts`） |
| 包名 | `love.mikumiku.chatluna_mobile` |
| 桌面名 | `Luna Viewer`（`android:label`） |
| Flutter | 3.50.0 stable（engine `bf601093ad`） |
| 构建命令 | `flutter build apk --release --split-per-abi` |

| APK | 大小 | SHA-256 |
| --- | --- | --- |
| `app-arm64-v8a-release.apk`（装机用） | 20,960,780 B | `85d6b563d138ccb7209b7615590e852f556d454da2965abe0deca1eba3321359` |
| `app-armeabi-v7a-release.apk` | — | `aff0b933a54e46d165a72d08a87bc2fec669e07bf3414618451b7870158b3ba2` |
| `app-x86_64-release.apk` | — | `e39eea89a29381d652b7fc6f7a6d42662cec3a2f0f8e628efae07640c7420132` |

## 签名

release 用本地 keystore（`android/key.properties`，不入库；`storeFile=C:/Users/yabo/.chatluna-mobile/release.jks`，alias `chatluna`）。

```
所有者: CN=ChatLuna Mobile, O=mikumiku, C=CN
SHA-1:   45:1D:07:BD:3A:9C:52:14:9D:6D:90:AE:35:7D:F2:1F:8C:B1:2A:44
SHA-256: BB:F0:F5:BA:42:D8:9F:3F:B9:ED:58:9B:55:E3:22:7F:7A:1C:90:A6:70:D2:B1:04:CE:DC:28:37:15:F9:38:07
```

`apksigner verify --print-certs app-arm64-v8a-release.apk` 输出的证书 DN 与 SHA-256 与上面一致——装机的确实是这把 key 签的包。

## 安装证据（真机 `10CF8403GA0049P`）

```
adb push build/app/outputs/flutter-apk/app-arm64-v8a-release.apk /data/local/tmp/luna.apk
adb shell pm install -r -t /data/local/tmp/luna.apk   → Success
adb shell dumpsys package love.mikumiku.chatluna_mobile
  versionName=0.1.0  versionCode=2001  lastUpdateTime=2026-11-19 23:51:46
```

装前设备上已有的同名 release 直接被 `-r` 覆盖升级（签名相同），没有 uninstall / `pm clear`，登录前旧凭证已不存在，因此从连接页重新登录。

## 登录与会话证据

连接页（`docs/evidence-0.1.0/connect.jpg`）：大标题已是 **Luna Viewer**，地址栏 `192.168.0.107:5028`、token 已填（掩码显示）。

点「连接」后（`docs/evidence-0.1.0/sessions-after-login.jpg`）：直接进入会话列表，底部 SnackBar 为「已连接 chatluna 2.0.0-alpha.0」，列表 10 个会话正常渲染（含未加载/已加载两种状态）。

打开已加载的 `ch-03 (2657455842)`（`docs/evidence-0.1.0/chat-opened.jpg`）：历史消息、图片气泡、模型胶囊（`deepseek-v4.1-flash`）与状态灯（待机）都正常；进程存活（`pidof` 有值），`logcat -b crash` 无该包记录。

## 本版修复

- **不再猜「工具转入后台」**：settle 时把「仍开着且没有 `tool-result` 的工具」当成转后台，对同步工具（draw 等）必然误报，中间块会凭空出现 `[draw 转入后台执行…]`。客户端这一启发式整段删除（连同 `_notifiedBackground`、`_resultToolCalls` 与本地合成块的 `_pushFrameworkNotice`）。后台任务真的完成时，由服务端自己发 `[background …]` 中间块。
- **改名收尾**：连接页大标题、关于对话框及其菜单项、复制出的诊断信息第一行都由 `ChatLuna` 改为 `Luna Viewer`；指向服务端产品的文案（`连接到自托管的 ChatLuna v2 实例`、`该会话尚未被 ChatLuna 加载`）保持原样，因为它们说的是后端而不是 App。

## 标签

`git tag -a v0.1.0 -m "Luna Viewer 0.1.0"`（本地，未推远端）。
