# AGENTS.md — chatluna-mobile

继承 `E:\Codes\AI\AGENTS.md` 与全局 `~/.agents/AGENTS.md`；本文件只加严，不放松。

## 这个项目是什么

ChatLuna v2 的移动端客户端（v0.1.0）：会话管理、对话（流式）、会话级配置、预设编辑。

- 规格真源在 `C:\Users\yabo\OneDrive\未来-终极愿景\编程\项目\2026\11\chatlunav2\`
  （`ChatLuna v2 架构认知提纲.md`、`ChatLuna v2 移动端 v0.1.0 开发计划.md`）。
- 本仓库 `docs/` 放**实现契约**（transport 接口、端点映射、UI 规格、验收脚本），不复制规格正文。

## 硬约束

1. **只有传输层知道协议**：`Authorization: Bearer`、`Idempotency-Key`、percent-encode、SSE 重连都在 `lib/core/transport/`；其它层只调 `(resource, verb, params)`。
2. **`/api/*` 只认 Bearer**，不认 cookie。禁止在任何地方实现 cookie 登录。
3. **不用 WebView 套壳**，不引入 RN。跨端一致性靠 Flutter widget，不靠内嵌页面。
4. **不发 stub**：没有实现的功能从 UI 上移除，而不是留空函数或假数据。
5. 新增依赖要能说出「不用它就得自己写多少行」；默认只保留 `http`、`web_socket_channel`、`flutter_secure_storage`、`shared_preferences` 级别的基础件。
6. 目录：`lib/` 是框架规定，替代根约定的 `src/`；`test/` 同理。其余按根约定：`docs/`、`scripts/`、`tmp/`。

## 分层（依赖方向单向）

```
lib/features/<area>/   UI 与页面状态
lib/core/capability/   领域仓库（Session/Preset/Routing）+ LiveBus
lib/core/transport/    REST / SSE / Action / WS 四条实现
lib/core/model/        领域模型（与服务端 JSON 解耦）
```

上层不得 import 传输层的具体实现，只 import 它的接口与错误类型。

## 验证

- 每次接触 UI 或网络：必须在真机上跑通一次（`flutter run -d <device>` 或 `adb install`），不接受「只编过」。
- 单元测试只覆盖有分支的纯逻辑（错误码映射、SSE 帧解析、游标拼接）。不为 wiring 写测试。
- 交付前 `flutter analyze` 必须零 warning。

## 提交

- 英文 conventional commits；一次提交一件事；提交前 `flutter analyze`。
- `tmp/` 下的调试脚本用完就删，不入库。
