# chatluna-mobile

ChatLuna v2 的移动端客户端（v0.1.0）：会话列表、流式对话、会话级配置、预设编辑。

规格真源在 `C:\Users\yabo\OneDrive\未来-终极愿景\编程\项目\2026\11\chatlunav2\`；
本仓库 `docs/` 是实现契约，`AGENTS.md` 是本地约束。

## 环境

| 项 | 版本 / 位置 |
|---|---|
| Flutter | 3.50.0 stable（`E:\BaseEnv\flutter`，已加进用户 PATH） |
| Dart | 3.14.0（随 Flutter） |
| Android SDK | `%LOCALAPPDATA%\Android\Sdk`（platform 36.1 / build-tools 36） |
| JDK | Zulu 21（`JAVA_HOME`） |
| 调试设备 | vivo V2425A，Android 16，`adb connect` 无线调试 |

## 跑起来

```powershell
flutter analyze
flutter run -d <device>          # 或 flutter build apk --debug && adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

首次连接需要实例地址（`192.168.0.x:5028`）和实例 token（WebUI 的 `?token=`，或实例 `data/auth.json`）。

## 结构

```
lib/core/model/        领域模型，隔离服务端 JSON
lib/core/transport/    唯一知道协议的地方：Bearer、幂等键、SSE、错误码
lib/core/capability/   领域动词（SessionsRepository …）
lib/core/store/        端点与凭证持久化（token 进系统保险箱）
lib/features/          页面：connect / sessions / chat
```

依赖方向单向：`features → capability → transport`。见 `docs/transport.md`、`docs/capability-map.md`。

## 状态

已实现：连接与鉴权、会话列表（游标分页）、新建/改名/删除、历史消息、发消息、`/live` 流式、中止、压缩、只读会话识别、实时流失败退回轮询。
未实现：局域网自动发现、验证码登录 UI、生物识别门禁、会话级四选择器、预设编辑、P2P。
