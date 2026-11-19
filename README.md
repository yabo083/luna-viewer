# Luna Viewer

个人自用的 ChatLuna v2 会话查看器（v0.1.0）：会话列表、流式对话、会话级配置。

`docs/` 是协议与交互契约，`AGENTS.md` 是本仓库的编码约束。

## 环境

| 项 | 版本 / 位置 |
|---|---|
| Flutter | 3.50.0 stable |
| Dart | 3.14.0（随 Flutter） |
| Android SDK | `%LOCALAPPDATA%\Android\Sdk`（platform 36.1 / build-tools 36） |
| JDK | Zulu 21（`JAVA_HOME`） |
| 调试设备 | 任意 Android 12+ 真机（无线调试或 USB） |

## 跑起来

```powershell
flutter analyze
flutter run -d <device>          # 或 flutter build apk --debug && adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

首次连接需要实例地址（`<lan-ip>:5028` 或 `https://你的域名`）和实例 token（WebUI 登录链接里的 `?token=`，或实例 `data/auth.json`）。

## 结构

```
lib/core/model/        领域模型，隔离服务端 JSON
lib/core/transport/    唯一知道协议的地方：Bearer、幂等键、SSE、错误码
lib/core/capability/   领域动词（SessionsRepository …）
lib/core/store/        端点与凭证持久化（token 进系统保险箱）
lib/features/          页面：connect / sessions / chat
```

依赖方向单向：`features → capability → transport`。见 `docs/transport.md`、`docs/capability-map.md`。

## 宿主侧伴侣插件

消息里的图片指向实例的 agent 工作区（`data/chatluna/agents-work`），默认没有任何 HTTP 出口。
`packages/chatluna-plugin-media-bridge/` 是配套的单文件 Cordis 插件（准备发 npm），把它暴露为
`GET /api/workspace?path=<相对路径>`（Bearer 保护、路径必须落在工作区内）。
部署：拷到实例 `external/chatluna-plugin-media-bridge/`，在 **非隔离** 的插件组（如 `platforms`）里加一条 entry：

```yaml
    - id: media-bridge
      name: file:///root/chatluna/external/chatluna-plugin-media-bridge/index.mjs
```

放进 `extensions` 组不行——该组 `isolate: {server: chatluna}`，插件拿到的是另一个 server 实例。

## 状态

v0.1.0 定位为**会话管理器 + 查看器**（不在 App 内新建 web 会话，也不代平台用户发言）：

已实现：连接与鉴权（Bearer）、bot 头像（取 WebUI 同源 `adapters.bots`）、会话列表（运行中置顶，游标分页）、历史消息（Markdown + 图片）、`/live` 实时流、中止、压缩上下文、分叉到新会话、web 会话的重命名/删除、平台会话只读提示、实时流失败退回轮询。
未实现：局域网自动发现、验证码登录 UI、生物识别门禁、会话级四选择器、预设编辑、P2P、向平台会话发消息（需宿主侧桥接插件）。
