# 性能修复（第二轮）

> 依据：`docs/perf-recheck.md`（下称「复测」）§7.3 / §7.4 / §5。
> 本轮只改 `lib/`，不动既有报告；`flutter analyze` 零问题、`flutter test` 129 项全绿。
> **设备侧数值本轮未实测**（任务要求不碰手机）：下文收益均为按复测数值推算的预估，
> 「验证」一节给出下一轮复测的采集命令。

## 0. 改动清单

| 文件 | 改动 |
|---|---|
| `lib/core/design/app_tokens.dart` | 新增 `kAvatarMaxDisplaySize` + `avatarDecodeWidthFor()`：头像只有一档解码宽度 |
| `lib/features/chat/assistant_avatar.dart` | 新增 `AvatarPhoto`（统一 `cacheWidth`、`gaplessPlayback`、`frameBuilder` 占位）；`AssistantAvatar` 改用它 |
| `lib/features/chat/message_view.dart` | 人类/会话头像改用 `AvatarPhoto`；全屏查看器补 `cacheWidth`；测量完成后断开测量订阅 |
| `lib/main.dart` | ImageCache 48 MiB / 80 条；整进程监听生命周期：60s 后台才清、内存压力立即清 |
| `lib/features/chat/chat_page.dart` | `_pauseStreams()` 不再 `imageCache.clear()` |
| `lib/features/sessions/sessions_page.dart` | `/api/sessions` 补表改为「按需 + 15s 起步 + 60s 封顶退避」 |
| `lib/core/capability/platform_stream.dart` | SSE 重连退避 15→30→60→120s |

既有契约未动：Bearer 过滤（`_authHeadersFor` / `_needsAuth`）、SSE 空闲判死（20s）、
401 停止重试（`_failAuth` / `_handleAuthFailure`）。

---

## 1. 头像 / 图片反复重载

### 原问题（复测 §7.3）

1. 头像在 28dp（气泡）、32dp（顶栏/默认）、40dp（列表行）三处各按自己的尺寸解码：
   @dpr3 分别生成 84/96/120 px **三条 ImageCache entry**，同一 URL 被复制三份；
2. `chat_page._pauseStreams()` 在每次 `paused` 调用 `imageCache.clear()`：
   HOME 一下、被别的 App 盖一下，回来所有头像与气泡图片重新解码（源站没强缓存时还会重新下载）；
3. 头像 `Image.network` 没有 `frameBuilder` / `gaplessPlayback`：缓存未命中的那几帧是透明空窗，
   视觉上就是「闪一下再出来」。

### 改法

* `avatarDecodeWidthFor(context)` = `imageDecodeWidthFor(context, 40)`，即最大展示尺寸 × dpr
  （@dpr3 = 120 px；`imageDecodeWidthFor` 自带的 1.5× 上限继续生效）。
  三处头像全部走同一个值，同一 URL 只占一条 entry，列表 ↔ 详情互相命中。
* 新增 `AvatarPhoto`：占位垫在 `Stack` 底层，`Image.network` 盖在上面；
  `frameBuilder` 在第一帧到达前不画图片，露出的就是占位（渐变 / 首字 / 图标），
  不再有透明空窗；`gaplessPlayback: true` 保证 provider 更换时保留上一帧；失败也退回占位。
* 后台策略上移到 `main.dart` 的 `_ChatLunaAppState`（整进程一份）：
  * `paused` 起一个 **60s** 计时器，期间 `resumed` 就取消 —— 短暂切后台**不清缓存**；
  * 60s 到点或 `didHaveMemoryPressure()` 才 `imageCache.clear()`。
    这两条路径下屏幕不可见，不存在「清掉正在显示的图」的问题；正在显示的 Widget 仍持有
    自己的 `ImageInfo`，即便在内存压力路径中清了缓存，回前台第一帧也不会变空。
* 详情页 `_pauseStreams()` 只清本页的 Widget/解析缓存，不再碰全局解码位图。

### 预期

* 列表 ↔ 详情、HOME 8s 往返：头像不再重新解码/重复下载（复测里的「反复加载」消除）；
* 头像 entry 从「URL × 最多 3 档」降到「URL × 1 档」：@dpr3 每个 URL 省 84²+96² = 16 646 px ≈ 66 KB，
  30 个不同头像约省 2 MB，并减少大图被头像挤出 LRU 的次数；
* 代价：气泡里 28dp 头像从 84px 提到 120px 解码，单张 +29 KB —— 只影响留存的少数头像，
  换来跨页面命中，净占用仍降。

### 验证

```bash
# 观看路径：列表 → 详情 → 返回，重复 10 次；HOME 8s 再回来。
# 期望：头像无「空白 → 出现」闪烁；Graphics 不随往返次数逐次抬升。
adb -s "$D" shell dumpsys meminfo $P | grep -E "TOTAL PSS|Graphics:"

# 量化重复下载（需 root 或服务端访问日志；本轮未测）：
#   adb shell tcpdump -i any -l port 5028 | grep -c '/files/'
# 期望：同一头像 URL 在切换一次前台/后台后不再出现新的 GET。
```

---

## 2. PSS / Graphics

### 先算：解码后的可见图片字节（Σ w×h×4，@dpr3）

| 对象 | 解码尺寸 | 单张字节 |
|---|---|---|
| 头像（统一后） | 120×120 | 57.6 KB |
| 气泡缩略（4:3，260dp 宽） | 780×585 | 1.83 MB |
| 气泡缩略（1:1） | 780×780 | 2.43 MB |
| 网格格子（2 列，约 128dp） | 384×384 | 0.59 MB |
| 长截图（1080×8000 原图，缩略宽 780） | 780×5778 | **18.0 MB** |
| 全屏查看（4:3 原图 4000×3000） | 改前：原图 4000×3000 | **48.0 MB** |
| 全屏查看（改后） | 屏宽 1080 × 810 | 3.5 MB |

复测详情态 `Graphics = 87.7 MB`：在 64 MiB 的 `ImageCache` 上限下，这一块基本就是
「一两张长截图 + 若干 1.8–2.4 MB 缩略图 + 全屏查看留下的原图」。全屏查看原先没有
`cacheWidth`，是唯一能单张吃掉几十 MB 的入口，且关闭查看器后仍按 LRU 占着缓存。

### 改法

* `imageCache.maximumSizeBytes`: 64 → **48 MiB**；`maximumSize`: 120 → **80**。
  字节上限下移后，长会话的峰值由字节数决定；120→80 条避免大量小 entry 长期占位。
* 气泡内媒体本来就传 `_cacheWidth(context) = imageDecodeWidthFor(context, 260)`（260dp × dpr），
  网格按格子边长解码 —— 本轮复核无需改动，数值见上表。
* 全屏查看器补 `cacheWidth = imageDecodeWidthFor(context, 屏幕逻辑宽)`：
  4k 原图从 48 MB 降到 3.5 MB；1× 缩放下仍是像素一比一。
* 收敛长生命周期持有：`_ChatImage` 的 `_measure` 只是为了拿宽高，
  拿到尺寸后立刻 `_detach()` 断开测量订阅（错误路径同样断开），
  不再让测量用的解码结果长期挂在 `ImageCache` 的 live 表里；
  渲染用的 `_RetryableImage` 解析的是同一个 provider，命中同一份缓存。
  `PreviewImage` 一类的全局持有在仓库中不存在（`grep ui.Image` 无结果），无需处理。
* **先不给 `clearLiveImages()` 的结论**：复测的详情态没有「live 表庞大」的直接证据，
  本轮按要求不做，留待下一轮用 `imageCache` 计数实测后再定。

### 预期（预估，未实测）

* `ImageCache` 上限 −16 MiB ⇒ 稳态 `Graphics` 最多降 16 MiB；
* 全屏查看路径：单次查看从 48 MB 级降到 3.5 MB 级，滚动/查看混合场景少一次「缓存被一张大图清空」；
* 头像 key 合并 + 后台不再清缓存 ⇒ 重新解码次数显著下降（`Graphics` 曲线更平，而不是锯齿）；
* 合计估算：复测详情态 `Graphics 87.7 → 70–75 MB`，`PSS 244.8 → 228–235 MB`；
  列表态 `Graphics 64.0 → 52–58 MB`，`PSS 166.8 → 150–158 MB`。
  **这只是上限收敛后的推算**；240–260 MB 里还有 Native/Java/光栅缓存，48 MiB 的
  ImageCache 不可能把 PSS 压到 120 MB，下一轮要按分类 PSS 继续找。

### 验证

```bash
adb -s "$D" shell dumpsys meminfo $P | grep -E "TOTAL PSS|Graphics:"
# 场景：列表静置 → 详情首屏 → 滚到顶 → 打开一张 4k 图再关闭 → 回列表
# 期望：详情态 Graphics 下降 ≥ 10 MB；关闭全屏后 Graphics 立刻回落而不是停在 80 MB 量级。

# 直接读解码缓存（profile + disable-service-auth-codes 启动后，若 evaluate 可用）：
#   PaintingBinding.instance.imageCache.currentSizeBytes
#   PaintingBinding.instance.imageCache.currentSize
# 期望：稳定态 currentSizeBytes ≤ 48 MiB，currentSize ≤ 80。
```

---

## 3. 列表页每 3–6 s 新建短 TCP

### 来源（复测 §7.4 与代码对照）

| 候选 | 结论 |
|---|---|
| `PlatformStream` 重连 | **不是**。列表静置时 SSE 常驻不断（本地端口不变）；重连退避原为 1s 起步，只在断线时出现 |
| `chat_page._runningCheck` | **不是**。外发落库后的一次性定时器，不是周期轮询 |
| `sessions_page._syncConversations` | **不是主因**。只在「流里出现未知会话」时触发（2s 合并窗口），静置没有未知会话 |
| `sessions_page._syncLoaded`（轮询补表） | **是主因**：`_onBeat` 对**每一帧**调用它，内部 5s 节流 ⇒ 群聊有消息时每 5s 一次 `GET /api/sessions`。复测观察到的「第 2 条本地端口每 3–6 s 变一次」正好是这个节奏 |

`ApiClient` 复用同一个 `http.Client`，但服务端/空闲超时下连接会被回收，每次请求都新建 TCP；
所以「请求频率 = 新建连接频率」。

### 改法

* `_onBeat` 只在这一帧**可能改变行状态**时才补表：
  * 行还没有 `session`（等 agent 认领 → 绿点、状态、可进详情）；
  * 行在跑（这条可能就是本轮最后一条，`running` 要变 false）；
  * 对方刚发来消息（`!message.outbound`，agent 可能刚被叫醒）。
  机器人回复且状态早已静止的帧 → **一个请求都不发**。
* `_syncLoaded` 由「5s 节流」改为：**15s 起步**；连续两拍行状态（id + running 指纹）
  没变化就 2× 退避到 **60s**，有变化立即回到 15s；请求在途不叠加。
  用户主动返回列表仍走一次 `force: true`（一次性，不参与退避）。
* `PlatformStream` 断线退避 1→2→4→8→16→30 改为 **15→30→60→120s**
  （帧到达即复位到 15s）：服务端抖动时不再每秒刷一条新 TCP。
* 效果：**空闲（没有消息帧）时 0 请求**；活跃群聊最密 15s 一次，且状态静止时自动拉长到 60s。

### 预期

| 场景 | 改前（复测） | 改后（预估） |
|---|---|---|
| 列表静置 60s（无新消息） | 12–20 条新连接 | **0** |
| 活跃群聊 60s（每秒都有消息） | 12 条（5s 节流） | **1–4 条**（15s，状态变化会重置） |
| 状态静止的群聊 60s | 12 条 | **1–2 条**（退避到 60s） |
| 断线重连 | 1/2/4/8s | 15/30/60/120s |

### 验证（改前/改后同一口径）

```bash
# 60 次采样（每秒一次），只统计到 5028 的 ESTABLISHED 连接本地端口
adb -s "$D" shell 'i=0; while [ $i -lt 60 ]; do
  cat /proc/net/tcp /proc/net/tcp6 | awk '\''$3 ~ /:13A4$/ && $4=="01" {print $2}'\'' | tr "\n" " "; echo
  i=$((i+1)); sleep 1; done' > tmp/conn-after.txt

# 不同本地端口数 ≈ 窗口内新建连接数
tr ' ' '\n' < tmp/conn-after.txt | grep . | sort -u | wc -l
```

判读：改前静置窗口内会看到 ~12 个不断变化的端口 + 1 个常驻端口；改后期望只有 1 个常驻端口
（活跃群聊时另加 ≤4 个）。切后台（HOME）8s 后仍应为 0 条。

---

## 4. 未做 / 下一轮复测要看的两三个指标

未做（明确记录，不是遗漏）：

* `imageCache.clearLiveImages()`：缺少 live 表的实测数据，按要求先不做；
* 气泡长截图只限宽不限高（780×5778 = 18 MB）：`ResizeImage` 同时给宽高会改变比例，
  不能用；要压这块需要「先探原始尺寸再选解码高度」，属于下一轮设计；
* 设备侧复测（PSS/Graphics/连接数/帧）本轮全部未执行。

下一轮复测建议只看这三项：

1. **列表静置 60s 的新建连接数**（目标 0；活跃群聊 ≤4）。
2. **详情态 `Graphics` 与分类 PSS**（目标 Graphics ≤ 70 MB；同时抄 Java/Native/Code 三项，
   判断 240 MB 里剩余的大头在哪）。
3. **`imageCache.currentSizeBytes` / `currentSize`**（稳定态 ≤ 48 MiB / ≤ 80 条，
   来回切前台 5 次后不出现「重建到上限」的锯齿），配合头像闪烁的用户观察。
