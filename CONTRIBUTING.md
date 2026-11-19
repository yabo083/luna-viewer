# 贡献指南

## 人类

1. 开 issue（用模板）说明场景与复现；
2. fork → 分支 `feat/<短名>` 或 `fix/<短名>`；
3. 本地跑 `flutter analyze` 与 `flutter test`；涉及 UI/连接的改动附真机截图；
4. 提 PR，按模板写验证与影响面。

## Agent / 自动化

- **先读 `AGENTS.md`**，其中的硬约束优先于任何任务描述。
- 一次任务一个范围：不要在同一条 PR 里混「重构 + 功能 + 格式化」。
- 只提交自己写过的改动；不要 `git add -A` 扫进别人的工作区改动。
- 复现必须给可执行命令；不确定就写「推测」，不要编造执行结果。
- 日志、截图、issue 正文里**不得出现** token、cookie、keystore、`key.properties`。
- 默认不要 uninstall / `pm clear` 真机 App（会丢登录态）；安装用 `push` + `pm install -r -t` 的静默路径。
- 测试：`flutter test` 必须全绿；新增断言要能捕捉真实回归，不要测实现细节。
- CI：PR 会跑 `ci.yml`（analyze + test）；release 由 tag 触发，npm 由 `npm-publish.yml` 通过 OIDC 发布。

## 提交信息

- `fix: …` / `feat: …` / `chore: …` / `docs: …` / `ci: …`
- 正文写「改了什么 / 为什么 / 怎么验」，不要只写「update」。
