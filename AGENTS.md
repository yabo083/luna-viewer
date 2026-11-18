# AGENTS.md — chatluna-mobile

本仓库的编码约束。与团队根约定冲突时，以更严格的一条为准。

## 这个项目是什么

ChatLuna v2 的移动端客户端（会话管理器 + 查看器）。它连接自托管实例，不改实例本身的代码。

- 协议契约：`docs/transport.md`、`docs/capability-map.md`
- 交互规格：`docs/ui-spec.md`
- 验收脚本：`docs/verification.md`

## 硬约束

1. **只有传输层知道协议**：`Authorization: Bearer`、`Idempotency-Key`、percent-encode、SSE 重连都在 `lib/core/transport/`；其它层只调 `(resource, verb, params)`。
2. **`/api/*` 只认 Bearer**，不认 cookie。禁止实现 cookie 登录。
3. **不用 WebView 套壳**。跨端一致性靠 Flutter widget。
4. **不发 stub**：没实现的功能从 UI 移除，而不是留空函数或假数据。
5. 新增依赖要能说出「不用它得自己写多少行」；默认只保留 `http`、`web_socket_channel`、`flutter_secure_storage`、`shared_preferences`、`markdown_widget` 级别的基础件。
6. 目录：`lib/` 是框架规定，替代 `src/`；`test/` 同理。其余遵循 `docs/`、`scripts/`、`tmp/`。

## 分层（依赖方向单向）

```
lib/features/<area>/   UI 与页面状态
lib/core/capability/   领域仓库（Session/Preset/Routing）
lib/core/transport/    REST / SSE / Action / WS 四条实现
lib/core/model/        领域模型（与服务端 JSON 解耦）
```

上层不得 import 传输层的具体实现，只 import 它的接口与错误类型。

## 验证

- 接触 UI 或网络：必须在真机跑通一次（`flutter run -d <device>` 或 `adb install`），不接受「只编过」。
- 单元测试只覆盖有分支的纯逻辑（错误码映射、SSE 帧解析、markup 解析、版本比较）。不为 wiring 写测试。
- 交付前 `flutter analyze` 零 warning。

## 提交

- 英文 conventional commits；一次提交一件事；提交前 `flutter analyze`。
- `tmp/` 下的调试脚本用完就删，不入库。
