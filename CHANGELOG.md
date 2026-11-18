# Changelog

## 0.1.0 — 未发布

首批功能，围绕「管理并查看自托管 ChatLuna v2 实例的活跃会话」：

**连接**
- Bearer 鉴权（实例 token 或登录 session），token 存系统保险箱；地址自动归一（局域网 → http:5028，公网域名 → https:443）
- 字段级错误、粘贴按钮、token 明文切换、记住上次地址

**会话**
- 活跃会话列表（运行中分组置顶、头像、相对时间、下拉分页）
- 标题紧凑化：`qq 私聊 <openid>` → `私聊 · 尾6位`，点击展开完整信息与复制
- 搜索：按标题 / 引擎 / 模型过滤

**详情**
- 倒序列表：打开即在最新一条，向上滚动自动加载更早分页
- Markdown（标题/列表/表格/代码块/链接）与富媒体：`<img>`、`img/file` 块、`data:`、工作区相对路径、`/files` 引用
- 框架消息（wake、memory update 等）居中折叠块：标题胶囊 + 左对齐分段正文 + JSON 等宽
- 实时状态四档：待机 / 思考中 / 回复中 / 轮询中；三点指示器只在思考中出现
- 实时增量：`/live` 流式 + `/events` 落库消息，`Last-Event-ID` 续传、id 去重、退避重连
- 消息操作：中止、压缩上下文、分叉会话、回到底部（带未读徽标）
- 旁路流量：详情页订阅 `/api/traffic/stream`，`conversationKey` 归一后与会话 id 对齐（旧插件退回标题 id）；`dir: out` 补成 bot 回复气泡，`dir: in` 只把指令（`chatluna xxx` / `/xxx`）补成 `[指令] …` 卡片，普通入站消息交给 `/events`；3 s 回显去重、贴底跟随/未读、退避重连、404 退化 3 s 轮询
- 每消息工具调用聚合为「工具调用 ×N」，展开可见参数与结果

**配置**
- 模型切换：按 provider 分组的搜索弹层，`POST /sessions/:id/model`
- 主题：浅色/深色/跟随系统；开发者信息开关
- 每日一次的 GitHub Releases 更新检查

**配套**
- `chatluna-plugin-media-bridge`：`/api/workspace`（工作区文件，Bearer、路径越界 400）、`/api/traffic`（入站 + 出站消息环形缓冲，`dir` 区分方向；含未进入会话的指令与 bot 借框架之口发出的回复）
