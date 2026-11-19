## 变更

<!-- 一句话说清改了什么，再说为什么。关联 issue 用 #号。 -->

## 验证

- [ ] `flutter analyze` 零问题
- [ ] `flutter test` 全绿（新增用例在下面列出）
- [ ] 真机验证（若涉及 UI/连接）：设备型号、步骤、截图
- [ ] 未跑的命令/未验证的假设已在描述里标注

新增/修改的测试：

## 影响面

- 触碰的层次：`lib/core/transport` / `lib/core/model` / `lib/features/*` / 插件 / CI
- 行为变化（用户可见）：
- 回滚方式：

## 安全

- [ ] 没有提交 token、cookie、keystore、`key.properties`
- [ ] 日志与错误文案不回显凭据
- [ ] 没有关闭既有测试来换取通过

## Agent 附加（由 agent 提交时填写）

- 提交者（harness / 模型）：
- 工作分支与提交范围：
- 是否改过测试断言（若是，说明理由）：
