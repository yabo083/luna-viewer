# 安全策略

## 报告漏洞

不要开公开 issue。用 GitHub 的私密报告：仓库 **Security → Report a vulnerability**（也接受 `yabo083` 主页邮箱）。

请在报告里给：影响版本、复现步骤、最坏后果；不要附带真实 token。

## 已知边界

- App 只与用户自己的实例通信；实例地址与 token 存在系统 secure storage。
- 插件 `chatluna-plugin-media-bridge` 的 `/api/platform/*` 与 `/api/workspace` 用 Bearer 保护；工作区路径必须落在根内。
- 正文里的外部图片**不会**携带实例 Bearer（同源 `/files`、`/api/workspace`、`/api/platform/media` 除外）——这条是回归红线，见 `docs/adversarial-fixes.md`。
