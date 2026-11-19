# ChatLuna Mobile · 界面美化设计评审与落地规格书

> **文档标识**：`docs/design-review.md`  
> **对应需求稿**：`docs/design-brief.md`  
> **基准代码版本**：`ChatLuna Mobile v0.1.0`（Flutter Material 3，`seedColor: Color(0xFF5B8DEF)`）  
> **约束准则**：系统默认字体、零外部依赖引入、无常驻动效（骨架流光除外）、`flutter analyze` 零 Warning。

---

## 目录

- [一、视觉方案（落地方案）](#一视觉方案落地方案)
  - [A. Token 表](#a-token-表)
    - [1. 语义色彩体系 (Semantic Colors)](#1-语义色彩体系-semantic-colors)
    - [2. 文字比例尺 (Type Scale)](#2-文字比例尺-type-scale)
    - [3. 间距系统 (Spacing Scale)](#3-间距系统-spacing-scale)
    - [4. 圆角系统 (Corner Radius Scale)](#4-圆角系统-corner-radius-scale)
  - [B. 组件规格（逐个）](#b-组件规格逐个)
    - [1. 会话列表行 (SessionTile)](#1-会话列表行-sessiontile)
    - [2. 顶部信息栏 (ChatInfoBar & ChatUnloadedBar)](#2-顶部信息栏-chatinfobar--chatunloadedbar)
    - [3. 对话气泡 (MessageBubble: Inbound & Outbound)](#3-对话气泡-messagebubble-inbound--outbound)
    - [4. 框架消息卡片 (FrameworkNoticeCard)](#4-框架消息卡片-frameworknoticecard)
    - [5. 骨架气泡与边框读数 (SkeletonBubble & Shimmer)](#5-骨架气泡与边框读数-skeletonbubble--shimmer)
    - [6. 空态与错误态界面 (_StatusView)](#6-空态与错误态界面-_statusview)
    - [7. 底部弹层 (Modal Bottom Sheets)](#7-底部弹层-modal-bottom-sheets)
  - [C. 线框对比（ASCII Wireframes）](#c-线框对比ascii-wireframes)
    - [1. 会话列表行 (Session Tile)](#1-会话列表行-session-tile)
    - [2. 顶部导航与信息栏 (AppBar & InfoBar)](#2-顶部导航与信息栏-appbar--infobar)
    - [3. 聊天气泡流 (Chat Timeline)](#3-聊天气泡流-chat-timeline)
    - [4. 骨架气泡与骑缝标签 (Skeleton Bubble)](#4-骨架气泡与骑缝标签-skeleton-bubble)
    - [5. 框架消息卡片 (Framework Notice Card)](#5-框架消息卡片-framework-notice-card)
  - [D. Flutter 片段（可直接落地）](#d-flutter-片段可直接落地)
    - [1. 全局主题 Token 落地 (`lib/main.dart`)](#1-全局主题-token-落地-libmaindart)
    - [2. 对话气泡与脚注样式 (`lib/features/chat/message_view.dart`)](#2-对话气泡与脚注样式-libfeatureschatmessage_viewdart)
    - [3. 骨架气泡边框与骑缝标签 (`lib/features/chat/chat_page.dart`)](#3-骨架气泡边框与骑缝标签-libfeatureschatchat_pagedart)
    - [4. 骨架流光灰条配色与间距 (`lib/features/chat/chat_page.dart`)](#4-骨架流光灰条配色与间距-libfeatureschatchat_pagedart)
    - [5. 信息栏胶囊底座标准化 (`lib/features/chat/chat_chrome.dart`)](#5-信息栏胶囊底座标准化-libfeatureschatchat_chromedart)
    - [6. 会话列表行与运行中指示条 (`lib/features/sessions/sessions_page.dart`)](#6-会话列表行与运行中指示条-libfeaturessessionssessions_pagedart)
  - [E. 视觉与交互验收清单](#e-视觉与交互验收清单)
- [二、开放式独立评审（架构与技术债）](#二开放式独立评审架构与技术债)
  - [1. 架构：三路并发与「实时近似 + 事后校正」的合理性评估](#1-架构三路并发与实时近似--事后校正的合理性评估)
  - [2. 性能：真机场景掉帧与耗电风险点及测量建议](#2-性能真机场景掉帧与耗电风险点及测量建议)
  - [3. 状态机复杂度：五类状态的收敛与边界划分](#3-状态机复杂度五类状态的收敛与边界划分)
  - [4. 可测试性：亟需抽离的高复杂度状态与业务逻辑](#4-可测试性亟需抽离的高复杂度状态与业务逻辑)
  - [5. 风险清单：用户可感知的 Top 5 隐患与最小复现路径](#5-风险清单用户可感知的-top-5-隐患与最小复现路径)

---

# 一、视觉方案（落地方案）

---

### A. Token 表

#### 1. 语义色彩体系 (Semantic Colors)

当前真机视觉失衡的根本原因在于：Material 3 暗色默认从种子派生出的 `primary` 落在 Tonal 80（高亮浅蓝 `#B0C6FF`），将其作为大面积外发气泡底色时，在 `#0B0D10` 画布上产生严重发光感，且与状态呼吸灯、骨架气泡边框互相争夺注意力通道。

新规则确立**主色克制原则**：
- `accent_primary` 高亮主色**仅用于交互焦点与瞬态呼吸灯**（点级表达，全屏占比 < 1%）。
- 外发气泡改用**低明度内敛深蓝（Dark）/ 柔和空气蓝（Light）的容器色**，使正文阅读舒适度提升的同时退居清晰层级。

| Token 名 | Dark 模式 (十六进制) | Light 模式 (十六进制) | 用途与层级说明 |
|---|---|---|---|
| `canvas_bg` | `#0B0D10` | `#F7F8FB` | Scaffold 根底色、AppBar 底色、底层视口背景 |
| `surface_l1` | `#13161B` | `#FFFFFF` | 会话卡片行、框架消息卡片底色 |
| `surface_l2` | `#1A1E26` | `#EEF1F6` | 接收气泡底色、底部弹层 Sheet 底色 |
| `surface_l3` | `#232833` | `#E3E7F0` | 信息栏胶囊底色、未读徽标背景、悬浮态 |
| `bubble_out_bg` | `#182842` | `#E3EDFE` | 外发气泡底色（暗色下为内敛深蓝，浅色下为空气蓝） |
| `bubble_out_border` | `#22385C` | `#C8DCFD` | 外发气泡细边框（提升气泡轮廓清晰度） |
| `bubble_out_text` | `#E2EDFC` | `#0D254C` | 外发气泡正文色（对比度均 ≥ 8.5:1） |
| `bubble_out_muted` | `#8BA2C4` | `#4B6999` | 外发气泡脚注时间/耗时文本 |
| `bubble_in_bg` | `#1A1E26` | `#FFFFFF` | 接收气泡底色 |
| `bubble_in_border` | `#252B37` | `#E2E6EF` | 接收气泡细边框 |
| `bubble_in_text` | `#EDEDF0` | `#14171D` | 接收气泡正文色（对比度均 ≥ 12:1） |
| `bubble_in_muted` | `#8C93A0` | `#636B78` | 接收气泡脚注时间文本 |
| `text_primary` | `#EDEDF0` | `#14171D` | 标题、核心文本、一级信息 |
| `text_secondary` | `#9198A6` | `#565E6D` | 副标题、会话列表预览、胶囊标签 |
| `text_tertiary` | `#585F6D` | `#8A93A2` | 禁用文本、极弱脚注、分隔符 |
| `border_subtle` | `#222733` | `#E1E5ED` | 容器外边框、列表分割感线 |
| `border_divider` | `#181C24` | `#EDF0F5` | 弹层分隔线、日期条横线 |
| `accent_primary` | `#5B8DEF` | `#336EE2` | 交互主色：状态呼吸灯、选中高亮、搜索光标 |
| `status_running` | `#22C55E` | `#16A34A` | 运行中状态点、运行中列表标记 |
| `status_warning` | `#F59E0B` | `#D97706` | 告警态、重试提示 |
| `status_error` | `#EF4444` | `#DC2626` | 轮询异常灯、中止指示、断线错误 |
| `skeleton_bg` | `#131924` | `#EFF4FD` | 骨架气泡底色 |
| `skeleton_border` | `#223552` | `#BDD5FA` | 骨架气泡边框（告警感消除，归入主色暗系） |
| `skeleton_shimmer_base` | `#212836` | `#DFE6F2` | 骨架灰条基准色 |
| `skeleton_shimmer_lit` | `#333E53` | `#C6D2E6` | 骨架流光高光峰值色 |

#### 2. 文字比例尺 (Type Scale)

严格收敛至 4 档标准用途说明，彻底消除原实现中 `10/11/11.5/15` 的随意混合：

| Token 阶梯 | 字号 (sp) | 行高 (dp / 比例) | 字重 (FontWeight) | 字距 (Tracking) | 数字等宽 | 专属用途与映射位置 |
|---|---|---|---|---|---|---|
| `type_header` | 16 | 22 (1.375) | w600 | -0.2 | 否 | AppBar 标题、弹层 Title、状态大标题 |
| `type_body` | 14 | 21 (1.500) | w400 / w500 | +0.1 | 否 | 消息气泡正文（中英混排黄金行高）、会话列表标题 (w500) |
| `type_subtext` | 12 | 16 (1.333) | w400 / w500 | +0.2 | 否 | 会话副标题最后一条消息、框架卡片标题、列表副文本 |
| `type_caption` | 11 | 14 (1.272) | w500 / w600 | +0.3 | **是** | 气泡脚注时间、骨架边框计时标签、未读计数胶囊、信息栏标签 |

#### 3. 间距系统 (Spacing Scale)

全面收敛至 4 的倍数网格系统（2dp 仅限微对齐）：

| Token | 尺寸 (dp) | 语义规范与标准用途 |
|---|---|---|
| `space_2` | 2 | 微调垫距：图标微调偏移、连续消息微间距 |
| `space_4` | 4 | 极窄间距：胶囊内图标与字间隙、卡片内部文字行间隙 |
| `space_8` | 8 | 紧凑间距：连续气泡间距、列表项内部元素横向间距、分组头下间距 |
| `space_12` | 12 | 标准间距：气泡内部水平内边距、会话行垂直上下内边距 |
| `space_16` | 16 | 容器间距：换人后不同消息组间距、屏幕边缘全局 Padding、弹层内边距 |
| `space_20` | 20 | 结构间距：底部弹层拖拽手柄区域、空态视图图标下间距 |

#### 4. 圆角系统 (Corner Radius Scale)

| 类别 | 半径 (dp) | 映射组件 |
|---|---|---|
| `radius_pill` | 999 (Capsule) | 信息栏胶囊、未读数胶囊、全屏指示器 |
| `radius_sheet` | 16 | 底部弹层（上边缘双角）、Dialog |
| `radius_bubble` | 16 / 4 (Asymmetric) | 对话气泡（主圆角 16dp，说话人一侧上角 4dp）、骨架气泡 |
| `radius_card` | 10 | 框架消息卡片、指令帮助卡片、代码预览块 |
| `radius_tile` | 8 | 会话列表卡片行、输入框外框 |
| `radius_bar` | 4 | 骨架内部灰条、弹层拖拽手柄 |

---

### B. 组件规格（逐个）

#### 1. 会话列表行 (SessionTile)

- **外框尺寸**：高度自适应（单行预览时高度为 64dp，双行折叠时 ≤ 76dp）。
- **外边距/内边距**：外边距水平 8dp、垂直 2dp（构成独立卡片流）；内边距 `EdgeInsets.symmetric(horizontal: 12, vertical: 10)`。
- **圆角**：`8dp`。
- **背景与交互**：
  - 常态：未加载/普通会话为 `Colors.transparent`；运行中会话为 `surface_l1`（`#13161B`）。
  - 按下态：`InkWell` 水波纹，高亮色 `surface_l3`。
- **状态指示器统一**：
  - 运行中（Running）：行左边缘贴合高度 24dp、宽 3dp、圆角 2dp 的竖直色条，颜色统一为 `status_running`（`#22C55E`）；右侧状态灯同步使用 `#22C55E`（外圈 16dp @ 16% alpha，内圈 6dp），**消除之前左侧 Primary 蓝条与右侧绿点冲突的矛盾**。
  - 未加载（Unloaded）：副标题前缀标注 `[未加载]`（`text_tertiary`），右侧不画运行圆点。
  - 未读计数：右侧胶囊高度 18dp，内边距 `horizontal: 6, vertical: 1`，圆角 999dp，底色 `surface_l3`，文字 `type_caption`（`text_secondary`）。
- **排版结构**：
  - 左侧：40dp 圆形头像（群头像 / 首字占位），头像右下角不挂多余标徽。
  - 中间：会话名（`type_body`，w500，`text_primary`），下间距 4dp；副标题（`type_subtext`，`text_secondary`），单行省略。
  - 右侧：时间（`type_caption`，`text_tertiary`，右对齐），下间距 4dp；未读数或运行灯。

#### 2. 顶部信息栏 (ChatInfoBar & ChatUnloadedBar)

重构为高度 28dp 的标准微胶囊流：
- **容器规格**：高度 28dp，内边距 `EdgeInsets.fromLTRB(16, 4, 16, 8)`。
- **单个胶囊 (_PillSurface)**：
  - 高度：24dp，圆角：999dp。
  - 内边距：`EdgeInsets.symmetric(horizontal: 8, vertical: 4)`，元素间距：4dp。
  - 描边：1px `border_subtle`（暗色下清晰界定边缘）。
  - 动效：点击触发 `HapticFeedback.selectionClick()`，水波纹限制在胶囊内。
- **状态胶囊变体 (StatusPill)**：
  - **待机 (Idle)**：底色 `surface_l2`，描边 `border_subtle`，指示灯为 6dp 静态圆点（`text_tertiary`），文字「待机」（`text_secondary`）。
  - **思考中 (Thinking)**：底色 `accent_primary @ 12%`，描边 `accent_primary @ 30%`，指示灯为 6dp 圆点（`accent_primary`，伴随 1100ms `Curves.easeInOut` 呼吸透明度 0.35~1.0），文字「思考中」（`accent_primary`）。
  - **回复中 (Replying)**：底色 `accent_primary @ 12%`，描边 `accent_primary @ 30%`，指示灯为 6dp 静态高亮圆点，文字「回复中」（`accent_primary`）。
  - **轮询中 (Polling)**：底色 `status_error @ 12%`，描边 `status_error @ 30%`，指示灯为 6dp 静态点（`status_error`），文字「轮询中」（`status_error`）。

#### 3. 对话气泡 (MessageBubble: Inbound & Outbound)

- **最大宽度**：`MediaQuery.sizeOf(context).width * 0.82`（从 0.86 收拢，提升对话边界感）。
- **圆角体系**：
  - 接收方 (Inbound)：`BorderRadius.only(topLeft: Radius.circular(4), topRight: Radius.circular(16), bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16))`。
  - 外发方 (Outbound)：`BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(4), bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16))`。
- **容器背景与描边**：
  - 接收方：底色 `bubble_in_bg`（`#1A1E26`），描边 1px `bubble_in_border`（`#252B37`）。
  - 外发方：底色 `bubble_out_bg`（`#182842`），描边 1px `bubble_out_border`（`#22385C`）。
- **内边距**：`EdgeInsets.fromLTRB(12, 10, 12, 8)`。
- **连续消息合并排版**：
  - 同一人 5 分钟内连续消息：顶部间距 4dp，隐藏头像与名字，保持头像槽 28dp + 间距 8dp 缩进。
  - 换人或超时：顶部间距 16dp，展示 28dp 圆形头像，名字为 `type_caption`（`text_secondary`），名字与气泡间距 4dp。
- **脚注 (Footnote)**：
  - 右对齐，内边距 `top: 6, bottom: 0`。
  - 文本：`type_caption`，数字强制等宽。外发气泡用 `bubble_out_muted`（`#8BA2C4`），接收气泡用 `bubble_in_muted`（`#8C93A0`）。格式：`14:20` 或 `14:20 · 用时 4.9s`。

#### 4. 框架消息卡片 (FrameworkNoticeCard)

- **外层约束**：居中对齐，最大宽度 `0.84`，垂直间距上下各 6dp。
- **圆角**：`10dp`。
- **底色与描边**：底色 `surface_l1`（`#13161B`），描边 1px `border_subtle`（`#222733`）。
- **卡片头部（始终可见）**：
  - 内边距：`EdgeInsets.fromLTRB(10, 8, 8, 8)`。
  - 左侧：图标 `Icons.terminal` 或 `Icons.memory`（尺寸 14dp，`text_secondary`）。
  - 标题：`type_subtext`，w500，`text_primary`。
  - 标签后缀：`type_caption`，`text_tertiary`（例如 `· 2 条 · 6 行`）。
  - 右侧：展开折叠指示箭头（16dp，`text_tertiary`）。
- **折叠与展开正文**：
  - 内边距：`EdgeInsets.fromLTRB(10, 0, 10, 8)`。
  - 折叠态：展示前 2 行预览，`type_subtext`，`text_secondary`，截断补 `…`。
  - 展开态：段落垂直间距 6dp。JSON 与链接自动按等宽字体 `type_caption` + 底色 `surface_l2`（内边距 4dp，圆角 4dp）渲染。

#### 5. 骨架气泡与边框读数 (SkeletonBubble & Shimmer)

- **宽度**：`MediaQuery.sizeOf(context).width * 0.62`。
- **位置**：bot 侧右对齐，头像槽占位 28dp + 间距 8dp。
- **容器背景与描边**：
  - 底色：`skeleton_bg`（`#131924`）。
  - 描边：1px `skeleton_border`（`#223552`），**彻底废弃原告警感明显的亮色半透明边**。
  - 圆角：同外发气泡（`16/4/16/16`）。
  - 内边距：`EdgeInsets.fromLTRB(12, 14, 12, 12)`。
- **骑缝计时标签 (Riding Timer Badge)**：
  - 布局：`Positioned(top: -8, left: 12)`。
  - 背景：`canvas_bg`（`#0B0D10`，用于物理切断容器顶描边）。
  - 内边距：`EdgeInsets.symmetric(horizontal: 6, vertical: 0)`。
  - 文字样式：`type_caption`（11sp，等宽数字，字重 w600，颜色 `accent_primary` `#5B8DEF`）。
  - 文案格式：`25.4s · draw 21.6s · 思考 3.3s`。
- **灰条流光 (Shimmer Bars)**：
  - 顶条高度 8dp，宽 100%，圆角 4dp；底条高度 8dp，宽 60%，圆角 4dp；两线条间距 8dp。
  - 动画：单向平移 1400ms 循环，梯度从 `skeleton_shimmer_base`（`#212836`）穿插至 `skeleton_shimmer_lit`（`#333E53`）。
- **中止后重发区**：
  - 容器下方直连 `Padding(top: 4)`，右对齐。
  - 按钮：`TextButton.icon`，高度 28dp，图标 `Icons.refresh`（14dp），字号 12sp，颜色 `status_warning`。

#### 6. 空态与错误态界面 (_StatusView)

- **居中容器布局**：垂直居中，水平内边距 32dp。
- **图标**：
  - 外圈底座：56dp × 56dp 圆形容器，底色 `surface_l2`。
  - 图标：28dp，颜色 `text_tertiary`（错误态为 `status_error`）。
- **间距与字阶**：
  - 图标至标题：下间距 16dp。
  - 标题：`type_header`（16sp，w600，`text_primary`）。
  - 标题至描述：下间距 8dp。
  - 描述：`type_subtext`（12sp，`text_secondary`，居中排版，行高 1.4）。
  - 描述至动作按钮：下间距 20dp。
- **动作按钮**：
  - 规格：高度 36dp，圆角 8dp，内边距 `horizontal: 16`，样式为 `OutlinedButton.icon` 或 `FilledButton.tonalIcon`，图标尺寸 16dp，字体 13sp（w500）。

#### 7. 底部弹层 (Modal Bottom Sheets)

- **弹层外框**：
  - 顶部圆角：`16dp`。
  - 底色：`surface_l2`（`#1A1E26`）。
  - 顶部拖拽手柄：宽 32dp、高 4dp，圆角 2dp，底色 `border_subtle`，上下边距各 8dp。
- **弹层标题栏**：
  - 内边距：`EdgeInsets.fromLTRB(16, 4, 8, 12)`。
  - 标题文本：`type_header`（`text_primary`）。
  - 关闭按钮：32dp × 32dp，图标 `Icons.close`（18dp，`text_secondary`）。
- **明细列表行**：
  - 内边距：`EdgeInsets.symmetric(horizontal: 16, vertical: 10)`。
  - 键标签：宽 72dp，`type_subtext`，`text_secondary`。
  - 值文本：`type_body`，`text_primary`，支持 `SelectableText`，数字强制等宽。
  - 复制反馈：成功后图标由 `Icons.copy_rounded` 瞬切为 `Icons.check`（`status_running`），维持 1200ms。

---

### C. 线框对比（ASCII Wireframes）

#### 1. 会话列表行 (Session Tile)

```
【修改前：主色与绿条混杂、未读与状态点层级不清】
+-------------------------------------------------------------+
||(主色条) [头像]  会话标题超长截断两行...         今天 00:43 (绿点)  |
||                平台 · 未读 5                   [  5  ]     |
+-------------------------------------------------------------+

【修改后：8dp独立圆角行、绿条收敛归位、时间与未读层级分明】
+-------------------------------------------------------------+
| 8dp                                                         |
| +-[3px绿条]--12dp---------------------------------12dp----+ |
| |                                                         | |
| |  [40dp头像]   会话标题文本 (14sp/w500)         14:20    | |
| |    8dp        4dp                            4dp        | |
| |               最后一条预览消息 (12sp)...     [ 5 ]      | |
| |                                            (11sp胶囊)   | |
| +---------------------------------------------------------+ |
+-------------------------------------------------------------+
```

#### 2. 顶部导航与信息栏 (AppBar & InfoBar)

```
【修改前：22dp细小胶囊紧贴AppBar、字号11sp局促紧绷】
+-------------------------------------------------------------+
| [←]  ch-03 (2657455842) ∨                      (■)    (⋮)   |
|      [Bot 11sp] [Model-v4.1 11sp] [● 待机 11sp]              |
+-------------------------------------------------------------+

【修改后：28dp微胶囊流、带1px微妙描边、状态呼吸灯呼吸呼吸感明确】
+-------------------------------------------------------------+
| [←]  ch-03 (2657455842) ∨                     [中止]   (⋮)  |
| 16dp                                                        |
| +----------------+  +-------------------+  +--------------+ |
| | [Bot] angela   |  | deepseek-v4.1-fl… |  | (●) 思考中   | |
| +----------------+  +-------------------+  +--------------+ |
|  (24dp高/999dp圆角)   (点击切换模型弹层)     (主色1100ms呼吸)|
+-------------------------------------------------------------+
```

#### 3. 聊天气泡流 (Chat Timeline)

```
【修改前：外发气泡全屏高亮浅蓝底刺眼、抢夺所有界面视觉】
+-------------------------------------------------------------+
| [Avatar]  [接收气泡: 暗灰底 白字]                           |
|                                                             |
|           [外发气泡: 刺眼高亮亮蓝底 深蓝字 (大面积光污染)] [Avatar]|
|                                                 00:43 · 4.9s|
+-------------------------------------------------------------+

【修改后：外发深蓝内敛质感底、1px微描边、对比度黄金平衡】
+-------------------------------------------------------------+
| 16dp (组间距)                                               |
| [28dp] 8dp  +--接收气泡 (16/16/16/4)----------------------+ |
|             | 用户消息正文 (14sp/21dp行高)               | |
|             |                                       14:20 | |
|             +---------------------------------------------+ |
| 8dp (连续消息)                                              |
|             +--外发气泡 (16/4/16/16 深蓝底 #182842)-------+ |
|             | 机器人回复内容细腻排版，文字高对比舒适度...  | |
|             |                                14:21 · 6.3s | |
|             +---------------------------------------------+ |
+-------------------------------------------------------------+
```

#### 4. 骨架气泡与骑缝标签 (Skeleton Bubble)

```
【修改前：边框透亮告警、读数标签断开感生硬】
+-------------------------------------------------------------+
|                     12.4s · draw 2.3s                       |
|           +---------[高光白底压断边框]--------------------+ |
|           | (半透明浅蓝描边 类似报错提示)                  | |
|           | [===========灰条流光===========]             | |
|           | [======灰条======]                            | |
|           +-----------------------------------------------+ |
+-------------------------------------------------------------+

【修改后：主色暗系边框、等宽数字无抖动、骑缝标签平滑嵌入】
+-------------------------------------------------------------+
|                    12dp                                     |
|           +--[-8dp 骑缝标签: 12.4s · draw 2.3s (等宽)]----+ |
|           |  (#0B0D10 底色切断描边 / 主色 11sp 数字)      | |
|           |                                               | |
|           |  [============== 8dp 流光灰条 ==============] | |
|           |  8dp                                          | |
|           |  [========= 8dp 灰条 (60%宽) =========]       | |
|           +-- 1px #223552 边框 (圆角 16/4/16/16) ---------+ |
+-------------------------------------------------------------+
```

#### 5. 框架消息卡片 (Framework Notice Card)

```
【修改前：多行展开后无分块感、边框与气泡无区分】
+-------------------------------------------------------------+
|      ↳ [memory recall] · 7 行 ∨                             |
|        - [绘图工具] 绘图链路: 原生 draw 优先...              |
+-------------------------------------------------------------+

【修改后：10dp独立微卡片、结构头明确、等宽代码块高亮】
+-------------------------------------------------------------+
|      +-- 84% 宽 / 10dp 圆角 / 1px 描边 -------------------+ |
|      | [≡] memory recall              · 2条 · 6行   [∧]   | |
|      | -------------------------------------------------- | |
|      |  - [绘图工具] 原生 draw 优先，层级要短...          | |
|      |  `{ "route": "internal_draw", "timeout": 30 }`     | |
|      +----------------------------------------------------+ |
+-------------------------------------------------------------+
```

---

### D. Flutter 片段（可直接落地）

#### 1. 全局主题 Token 落地 (`lib/main.dart`)

```dart
ThemeData _theme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  
  // 建立符合视觉规范的语义调色板
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF5B8DEF),
    brightness: brightness,
    surface: isDark ? const Color(0xFF0B0D10) : const Color(0xFFF7F8FB),
    surfaceContainerLowest: isDark ? const Color(0xFF0B0D10) : const Color(0xFFFFFFFF),
    surfaceContainerLow: isDark ? const Color(0xFF13161B) : const Color(0xFFF7F8FB),
    surfaceContainer: isDark ? const Color(0xFF1A1E26) : const Color(0xFFEEF1F6),
    surfaceContainerHigh: isDark ? const Color(0xFF232833) : const Color(0xFFE3E7F0),
    surfaceContainerHighest: isDark ? const Color(0xFF2D3340) : const Color(0xFFD8DEE9),
    onSurface: isDark ? const Color(0xFFEDEDF0) : const Color(0xFF14171D),
    onSurfaceVariant: isDark ? const Color(0xFF9198A6) : const Color(0xFF565E6D),
    outline: isDark ? const Color(0xFF222733) : const Color(0xFFE1E5ED),
    outlineVariant: isDark ? const Color(0xFF181C24) : const Color(0xFFEDF0F5),
    primary: isDark ? const Color(0xFF5B8DEF) : const Color(0xFF336EE2),
    onPrimary: const Color(0xFFFFFFFF),
    primaryContainer: isDark ? const Color(0xFF182842) : const Color(0xFFE3EDFE),
    onPrimaryContainer: isDark ? const Color(0xFFE2EDFC) : const Color(0xFF0D254C),
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    // 统一定义全工程 Type Scale
    textTheme: TextTheme(
      titleMedium: TextStyle(
        fontSize: 16,
        height: 22 / 16,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: scheme.onSurface,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 21 / 14,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.1,
        color: scheme.onSurface,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.2,
        color: scheme.onSurfaceVariant,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        height: 14 / 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.3,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: scheme.onSurfaceVariant,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outline),
      ),
      isDense: true,
    ),
  );
}
```

#### 2. 对话气泡与脚注样式 (`lib/features/chat/message_view.dart`)

```dart
// 替换原 MessageView 内部约 158~173 行的 bubble 构建
final isDark = Theme.of(context).brightness == Brightness.dark;

// 外发：深蓝/空气蓝内敛底色；接收：surfaceContainer
final bubbleColor = outbound
    ? scheme.primaryContainer
    : (isDark ? const Color(0xFF1A1E26) : const Color(0xFFFFFFFF));

final bubbleBorderColor = outbound
    ? (isDark ? const Color(0xFF22385C) : const Color(0xFFC8DCFD))
    : (isDark ? const Color(0xFF252B37) : const Color(0xFFE2E6EF));

final bubbleForeground = outbound
    ? scheme.onPrimaryContainer
    : scheme.onSurface;

final bubbleMuted = outbound
    ? (isDark ? const Color(0xFF8BA2C4) : const Color(0xFF4B6999))
    : scheme.onSurfaceVariant;

final bubble = Container(
  constraints: BoxConstraints(
    maxWidth: MediaQuery.sizeOf(context).width * 0.82 - (_avatarSize + _avatarGap),
  ),
  margin: EdgeInsets.only(top: showHeader ? 2 : 0),
  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
  decoration: BoxDecoration(
    color: bubbleColor,
    border: Border.all(color: bubbleBorderColor, width: 1),
    borderRadius: BorderRadius.only(
      topLeft: Radius.circular(outbound ? 16 : 4),
      topRight: Radius.circular(outbound ? 4 : 16),
      bottomLeft: const Radius.circular(16),
      bottomRight: const Radius.circular(16),
    ),
  ),
  child: Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ...content,
      if (time != null || footnote != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              [if (time != null) _hourMinute(time!), ?footnote].join(' · '),
              style: theme.textTheme.labelSmall?.copyWith(
                color: bubbleMuted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
    ],
  ),
);
```

#### 3. 骨架气泡边框与骑缝标签 (`lib/features/chat/chat_page.dart`)

```dart
// 替换 _SkeletonBubble 内部约 1895~1940 行的 BoxDecoration 与 Stack 标签
final isDark = theme.brightness == Brightness.dark;
final skeletonBorder = isDark ? const Color(0xFF223552) : const Color(0xFFBDD5FA);
final skeletonBg = isDark ? const Color(0xFF131924) : const Color(0xFFEFF4FD);

return Stack(
  clipBehavior: Clip.none,
  children: [
    Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      decoration: BoxDecoration(
        color: skeletonBg,
        border: Border.all(color: skeletonBorder, width: 1),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(4),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      ),
      child: const _SkeletonBars(),
    ),
    Positioned(
      top: -8,
      left: 12,
      child: Container(
        color: theme.scaffoldBackgroundColor, // 压断 1px 描边
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: ValueListenableBuilder<TurnClockView?>(
          valueListenable: clock,
          builder: (context, view, _) => Text(
            view == null ? '' : turnLineLabel(view, aborted: aborted),
            maxLines: 1,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    ),
  ],
);
```

#### 4. 骨架流光灰条配色与间距 (`lib/features/chat/chat_page.dart`)

```dart
// 替换 _SkeletonBarsState 中的 build 颜色定义（约 1994~1997 行）
final isDark = Theme.of(context).brightness == Brightness.dark;
final base = isDark ? const Color(0xFF212836) : const Color(0xFFDFE6F2);
final highlight = isDark ? const Color(0xFF333E53) : const Color(0xFFC6D2E6);

return AnimatedBuilder(
  animation: _controller,
  builder: (context, _) {
    final head = _controller.value * 1.6 - 0.3;
    double at(double stop) => stop.clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _bar(base, highlight, head, at, widthFactor: 1.0),
        const SizedBox(height: 8), // 收敛至 8dp 间距
        _bar(base, highlight, head, at, widthFactor: 0.60),
      ],
    );
  },
);
```

#### 5. 信息栏胶囊底座标准化 (`lib/features/chat/chat_chrome.dart`)

```dart
// 替换 _PillSurface 中的常量与 build（约 574~620 行）
class _PillSurface extends StatelessWidget {
  static const double height = 24; // 规范化高度
  static const double radius = 999; // 完整胶囊圆角
  static const double gap = 4; // 规范化间距
  static const EdgeInsets padding = EdgeInsets.symmetric(horizontal: 8, vertical: 4);

  final Widget child;
  final _PillTone tone;
  final VoidCallback? onTap;

  const _PillSurface({super.key, required this.child, this.tone = _PillTone.neutral, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final (Color fill, Color border) = switch (tone) {
      _PillTone.neutral => (
        isDark ? const Color(0xFF1A1E26) : const Color(0xFFEEF1F6),
        isDark ? const Color(0xFF222733) : const Color(0xFFE1E5ED),
      ),
      _PillTone.accent => (
        scheme.primary.withValues(alpha: 0.12),
        scheme.primary.withValues(alpha: 0.28),
      ),
      _PillTone.alert => (
        scheme.error.withValues(alpha: 0.12),
        scheme.error.withValues(alpha: 0.30),
      ),
    };

    return Material(
      color: fill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: border, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: padding,
          child: child,
        ),
      ),
    );
  }
}
```

#### 6. 会话列表行与运行中指示条 (`lib/features/sessions/sessions_page.dart`)

```dart
// 替换 _SessionTile 中的左侧运行条与行修饰（约 1258~1272 行）
if (row.running)
  Positioned(
    left: 0,
    top: 18,
    bottom: 18,
    child: Container(
      width: 3,
      decoration: BoxDecoration(
        color: _runningDot, // 统一使用绿色 _runningDot (0xFF22C55E)，不再使用 scheme.primary
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  ),
```

---

### E. 视觉与交互验收清单

- [ ] **信息层级与主色收敛**：暗色模式下一屏之内高饱和 `primary`（`#5B8DEF`）仅出现在正在进行的呼吸状态灯与当前焦点的按钮上，外发气泡完全退回低明度深邃蓝（`#182842`），无光污染刺眼感。
- [ ] **对比度合规（WCAG 2.1 AA/AAA）**：
  - Dark 模式：外发文本对底色为 `10.8:1`（≥ 7:1），接收文本为 `13.5:1`。
  - Light 模式：外发文本对底色为 `8.9:1`（≥ 7:1），接收文本为 `15.2:1`。
  - 辅助弱化文字对两端底色对比度均 ≥ `4.6:1`。
- [ ] **间距收敛（4dp 严格网格）**：代码检索不再包含 `3, 5, 7, 9, 11` 等散落奇数数值；组件边距与间隙全部映射到 `2, 4, 8, 12, 16, 20`。
- [ ] **数字抖动清零**：骨架骑缝标签、气泡时间戳、阶段直方百分比全部挂载 `FontFeature.tabularFigures()`，计时数字步进时不产生水平像素挤压抖动。
- [ ] **状态色彩语义统一**：会话列表「运行中」左侧指示条与右侧状态点均统一使用 `status_running`（`#22C55E`），消除主色蓝条与绿点打架的视觉分裂。
- [ ] **骨架气泡无误导感**：骨架边框颜色与背景融洽（`#223552`），彻底去除原亮色半透明描边产生的「红色/告警错误」心理诱导。
- [ ] **长列表滚动性能**：`ListView.builder` 在 60Hz/120Hz 刷新率下平稳滚动，骨架气泡秒级 tick 不触发列表项或父容器重建（通过 DevTools Widget Rebuild Profiler 验证 Rebuild Count = 0）。

---

# 二、开放式独立评审（架构与技术债）

---

### 1. 架构：三路并发与「实时近似 + 事后校正」的合理性评估

#### 结论
**现有的「三路并发 + 事后拉取全量 Transcript 校正」架构属于典型的过度设计（Over-engineering），且付出了极高代价。应当彻底废弃事后全量拉取 `_adoptTiming()`，将计时真源完全收拢于客户端本地计时；长期应将框架消息合流至平台流，使连接数由 3 降为 1。**

#### 依据
1. **代码实测自相矛盾**：在 `lib/features/chat/chat_page.dart:1303`，代码注释写道：  
   `// 只校正「阶段」：总时长仍用本地钟（它跨 attempt，覆盖用户真正等的整段），引擎的 timing 按 turn 切分，直接拿来当总时长会因为后台轮次而偏小。`  
   这证明**客户端自身根本不信任服务端给出的总耗时**。
2. **每次生成结束的隐蔽全量网络惩罚**：`chat_page.dart:1302` 在每轮完成后调用 `widget.repo.transcript(session.id)`，实际发出 `GET /api/sessions/:id/messages`。该接口返回该会话历史上的**全部消息与全部块**（数百条消息时 payload 达 500KB~2MB）。只为从中翻找最后几个 block 的 `startedAt`/`endedAt` 微调毫秒数，收益与开销完全不成比例。

#### 建议动作
1. **第一步（立刻剪枝）**：直接删除 `chat_page.dart` 中的 `_adoptTiming()` 函数及其调用。骨架气泡撤场时，直接使用本地 `_clock.view.value.total` 盖印气泡脚注。本地计时覆盖了网络往返与用户真实感知等待，在体验上比引擎内部截断的时长更真实。
2. **第二步（链路合流）**：推动服务端 Companion 插件将 `[memory]`、`[wake]` 等框架消息以特定的 `dir=system` 帧直接注入 `GET /api/platform/stream`。这样进入会话详情页后，**只需维持唯一一条 SSE 长连**，彻底停掉 `/events`。

#### 代价
- 阶段耗时（如 `draw` 工具）读数为客户端收帧时刻算出的相对近似值（误差通常在 100~300ms 网络抖动内），不再与服务端日志微秒级绝对对齐（但对移动端用户阅读而言毫无感知差别）。

---

### 2. 性能：真机场景掉帧与耗电风险点及测量建议

#### 结论
真机主要掉帧与耗电场景集中在三个地方：
1. **轮次结束瞬间的 JSON 反序列化阻塞主线程（Jank）**；
2. **App 切后台后 3 条 SSE 长连接未主动断开导致的电量偷跑**；
3. **富文本 Markdown 抽象语法树（AST）在滚动期间重复构建**。

#### 依据
1. **切后台长连漏水**：`chat_page.dart:323-337` 的 `didChangeAppLifecycleState` 中，切后台时仅调用了 `_clock.suspend()`、`_stopProbe()` 和 `_stopPolling()`。**但字段 `_liveSub`、`_eventsSub`、`_streamSub` 依然存活**，后台若收到大量广播帧，主 Isolate 会被不断唤醒解析 JSON，严重影响电池寿命并极易被 Android 电池卫士判定为后台唤醒超标。
2. **Markdown 解析放进 build() 阶段**：`message_view.dart:391` 的 `MarkdownWidget` 在没有做 AST 缓存的情况下，每次列表滑动复用导致 `build()` 被触发时，都会对百字 Markdown 重新执行正则词法分析与 Widget 树分配。

#### 可验证的测量建议（指标 + 阈值）

| 测量场景 | 观测指标 | 监控工具 / 命令 | 验收阈值 (Pass 标准) |
|---|---|---|---|
| 机器人长消息落库 | UI 线程帧耗时 (Frame Time) | Flutter DevTools Performance Overlay | **无红色 Jank 帧，单帧耗时 ≤ 16.6ms (60fps) / 8.3ms (120fps)** |
| 持续生成 5 分钟 (流式+计时) | CPU 使用率 & 内存抖动 | Android Studio Profiler (CPU / Memory) | **单核 CPU 占用 ≤ 8%，无周期性锯齿状 GC 停顿** |
| 切后台保持 15 分钟 | 后台唤醒次数 (WakeLocks) | `adb shell dumpsys batterystats` | **Uid 唤醒次数 = 0，网络传输量 ≤ 2KB** |
| 快速惯性划动 200 条消息 | 丢帧率 (Dropped Frames Percentage) | `flutter run --profile` 抓取 timeline | **Dropped Frame Rate ≤ 1.5%** |

---

### 3. 状态机复杂度：五类状态的收敛与边界划分

#### 结论
现存「轮次 (Round) / 阶段 (Phase) / 工具 (Tool) / 中止 (Abort) / 后台 (Suspend)」在 `turn_clock.dart`（606 行）与 `chat_page.dart` 之间耦合极深，存在概念重叠。核心问题是：**客户端误把「多任务执行追踪器」的职责全盘揽下，试图通过碎片化的事件拼凑全局状态机。**

#### 依据
- `turn_clock.dart:80-99` 中为了解决「工具结束了但模型还在思考」或者「思考先到工具后到」，写了大量的兜底补丁逻辑（如 `ordered` 数组提取非 thinking、`ordered` 为空时 fallback 到 `recent`、只开着思考时把刚结束的工具耗时硬塞到尾巴）。
- 本质上，**Tool 就是 Phase 的子集**。将「思考」与「工具」拆成两套并行数据结构（`_phases` 与 `_activeTools`）是复杂度爆炸的根源。

#### 建议动作
1. **概念合并：`Phase` 统一为唯一的 `ExecutionSpan`**。
   ```dart
   class ExecutionSpan {
     final String name;      // 'thinking', 'draw', 'reply'
     final DateTime start;
     DateTime? end;
   }
   ```
   无论是模型前置思考、工具调用、还是输出回复，统一建模为执行区间的入栈与出栈。
2. **将「轮次生命周期」下沉给协议层**：
   要求服务端在 `/live` 的 SSE 中推送显式事件 `turn:start {turnId}` 与 `turn:end {turnId, status: 'settled'|'aborted'}`。客户端不再使用「平台消息先到 3 秒判定」或「grace 延迟判定」等时间滑动窗口来猜测一轮是否结束。

#### 代价
- 需要协调服务端 Companion 插件统一事件包络定义。

---

### 4. 可测试性：亟需抽离的高复杂度状态与业务逻辑

#### 结论
目前测试覆盖（`model_test.dart`、`timeline_test.dart`、`turn_clock_test.dart`）仅停留在纯数据模型与独立类，**而状态转移最脆弱、Bug 最集中的 UI 编排逻辑全部深锁在 `StatefulWidget` 内部**，导致无法编写免启动渲染的单元测试。

#### 亟需抽离为纯函数的四大逻辑

1. **骨架气泡生命周期状态机（`_SkeletonPhase` 转换机）**
   - **现状**：`chat_page.dart` 中由 `_startSkeleton`、`_endSkeleton`、`_fadeSkeleton`、`_removeSkeleton` 等 8 个相互调用且包含 `Timer` 的函数驱动。
   - **建议**：抽离为纯状态机 Reducer：
     ```dart
     SkeletonState nextSkeletonState(SkeletonState current, SkeletonEvent event);
     ```
     测试即可通过喂入模拟事件序列（如 `onTurnStart -> onAbort -> onNewMessage`），单测覆盖率可达 100%。

2. **连续消息聚合与头像槽合并计算（`GroupHeader` 判定）**
   - **现状**：在 `ListView.builder` 构建子项时即时比对前后索引元素（`chat_page.dart:1600+`）。
   - **建议**：重构成纯管道函数 `List<DecoratedTimelineItem> groupTimeline(List<TimelineItem> raw)`。输入扁平消息列表，输出已标明 `showHeader`、`topPadding` 的展示视图模型。

3. **会话列表的活跃/归档切分器（`_split()`）**
   - **现状**：`sessions_page.dart:798` 在 `_split()` 内部直接硬编码读取 `DateTime.now()`，导致针对 72 小时活跃窗口的边界测试必须依赖延迟模拟。
   - **建议**：抽为顶层纯函数：
     ```dart
     (List<SessionRow>, List<SessionRow>) partitionSessions(
       List<SessionRow> rows, {
       required DateTime currentTime,
       Duration activeWindow = const Duration(days: 3),
     });
     ```

4. **正文占位文案探测与剥离器**
   - **现状**：`message_view.dart:584` 的 `_placeholderOnly()` 与正则逻辑紧贴渲染流程，难以独立回归测试各类平台媒体占位文案。

#### 代价
- 需要做一次代码重构，将部分页面内部方法迁移到 `lib/features/chat/domain/` 纯 Dart 逻辑域中。

---

### 5. 风险清单：用户可感知的 Top 5 隐患与最小复现路径

| 序号 | 隐患故障现象 | 潜在触发机制与代码根因 | 最小复现路径 (Minimal Repro) | 建议缓解措施 |
|---|---|---|---|---|
| **1** | **长会话生成结束瞬间严重卡顿 0.5~1 秒** | `chat_page.dart:1298` `_adoptTiming()` 在消息落地后拉取并反序列化全量 Transcript，阻塞 UI 线程。 | 进一个历史消息 > 300 条的会话，让 bot 画一张图。消息生成结束的瞬间，界面水波纹与列表滚动完全冻结。 | 彻底删除 `_adoptTiming`，仅用本地钟盖印气泡耗时。 |
| **2** | **切网/息屏切回后，状态灯永久卡在「轮询中」** | `chat_page.dart:323` 后台未断开 SSE，恢复前台后直接 `_restartLive()`，旧连接变半死 Zombie 连接，导致后续握手持续超时或触发 409。 | 手机开启 5G，进入会话详情页，锁屏 3 分钟；解锁后向 bot 发送消息。观察顶部胶囊，持续显示红色「轮询中」，不再切换「思考中」。 | `AppLifecycleState.paused` 时显式 `cancel()` 所有 SSE 订阅；回到前台后按需重建。 |
| **3** | **骨架气泡计时文本每秒跳动、边界闪烁** | `_SkeletonBubble` 顶部骑缝标签未设置固定约束或对齐基线，秒数位数递增或阶段文本变长时产生水平挤压抖动。 | 触发一次长时间任务（如绘图耗时 > 10s）。观察标签骑在边框上的位置，随着 `9.9s` 变 `10.0s` 以及阶段词切替，描边切断处频繁跳字。 | 骑缝标签增加 `fontFeatures: [FontFeature.tabularFigures()]` 并设定固定最小展示宽度。 |
| **4** | **会话列表项在 72 小时临界点神秘消失** | `sessions_page.dart:799` 每次流事件触发重建都以设备即时时间重新切分活跃与归档，会话被动态踢入归档。 | 找到一条距离最后发言恰好 71 小时 59 分钟的会话。保持列表开着，等待 1 分钟后收到任意其他会话的消息推帧，当前行瞬间在眼前消失。 | 会话列表页面挂载期间锁定一个相对 `snapshotTime`，或归档状态变更时增加微动效提示。 |
| **5** | **长按删除已加载会话后，刷新又复活** | `sessions_page.dart:616` 调用 `_repo.delete()` 仅删除了 ChatLuna 的会话存储，而平台伴侣插件的消息真源表依然保留该会话。 | 长按一个已加载会话选择「删除」，提示成功；下拉列表刷新，该会话再次作为「未加载」会话重新出现在列表中。 | 在交互上明确区分「删除 ChatLuna 状态」与「删除平台历史」，或在插件侧提供真正的软删除/隐藏 API。 |
