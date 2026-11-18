# Changelog

## 0.1.0 — 未发布

首批功能，围绕「管理并查看自托管 ChatLuna v2 实例的活跃会话」：

**连接**
- Bearer 鉴权（实例 token 或登录 session），token 存系统保险箱；地址自动归一（局域网 → http:5028，公网域名 → https:443）
- 字段级错误、粘贴按钮、token 明文切换、记住上次地址

**会话**
- 会话列表以插件 `/api/platform/conversations` 为真源：插件给的会话名、最后一条消息作副标题、消息条数与最后时间
- 与 `/api/sessions` 合并：已加载会话补运行中标记与置顶排序，插件里有但未加载的会话照旧成行（只读）
- 实时：订阅 `/api/platform/stream`，已有会话就地更新计数/最后一条，新会话补一次会话表后插入；下拉刷新是全量对齐
- 标题紧凑化：`qq 私聊 <openid>` → `私聊 · 尾6位`，点击展开完整信息与复制
- 搜索：按会话名 / 平台 / 引擎 / 模型过滤

**详情**
- 消息只来自插件：`/api/platform/messages` 分页（首屏 50 条，向上滚动用最早一条的时间作游标取更早），实时走 `/api/platform/stream`，按消息 id 去重
- 渲染统一：`dir=out` 助手气泡（头像 + markdown）/ `dir=in` 用户气泡（纯文本），不再有指令卡与框架块
- 倒序列表：打开即在最新一条，向上滚动自动加载更早一页
- Markdown（标题/列表/表格/代码块/链接）与富媒体：`<img>`、`img/file` 块、`data:`、工作区相对路径、`/files` 引用
- 状态胶囊：待机 / 思考中 / 回复中（由 `/live` 驱动，三点指示器只在思考中出现）；仅已加载会话显示
- 流式：`/live` 的 text delta 先出临时气泡，落库后由平台流换成正式消息
- 会话操作：中止、压缩上下文、分叉会话、回到底部（带未读徽标）；未加载的会话只读

**配置**
- 模型切换：按 provider 分组的搜索弹层，`POST /sessions/:id/model`
- 主题：浅色/深色/跟随系统；开发者信息开关
- 每日一次的 GitHub Releases 更新检查

**配套**
- `chatluna-plugin-media-bridge`：`/api/workspace`（工作区文件，Bearer、路径越界 400）、`/api/platform/*`（会话列表、消息分页、SSE 实时流 —— App 的会话与消息真源）
