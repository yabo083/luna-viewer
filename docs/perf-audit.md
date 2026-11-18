# 性能集中审查（待执行）

> 用户要求：App 与实例插件的占用都不能高；先用数据说话，再改。
> 允许建立测试工程与采集脚本，结论必须带单位与口径。

## 1. App 侧指标

| 指标 | 采集方式 | 目标（初值，审查后校准） |
|---|---|---|
| 冷启动到首帧 | `adb shell am start -W` 的 `TotalTime`，取 5 次中位数 | ≤ 900 ms |
| 进入详情页耗时 | debug 头部 `net / live / msg` 三段，取 10 次 p50/p90 | net p90 ≤ 300 ms |
| 滚动掉帧 | `SchedulerBinding.addTimingsCallback` 采样 5 s，统计 over-16.7ms 帧比例 | ≤ 5% |
| 内存常驻 | `adb shell dumpsys meminfo <pkg>` 的 TOTAL PSS（打开详情页 30 s 后） | ≤ 120 MB |
| CPU（空闲） | `adb shell top -b -n 1 -d 1` 中进程 CPU%，停在详情页 30 s | ≤ 3% |
| 流式帧率 | 生成期间同样采样 5 s 的 build/raster p50/p90 | build p90 ≤ 16 ms |
| 连接数 | 打开详情页后 `ss` 看到 App 建立的 SSE 连接数 | 列表页 1（platform/stream）；详情页 2（platform/stream + /live，后者仅已加载会话） |

## 2. 插件侧指标

| 指标 | 采集方式 | 目标 |
|---|---|---|
| Node 进程 RSS | `ps -o rss= -p $(pgrep -f chatluna)` 连续 3 次间隔 60 s | 与加插件前基线差 ≤ 20 MB |
| 空闲 CPU | `top -b -n 2 -d 5` 的 chatluna 进程行 | ≤ 2% |
| 入站消息开销 | 1 万条合成 `message` 事件（测试脚本直接 `ctx.emit`）耗时 | ≤ 2 µs/条量级 |
| SSE 连接规模 | 并发 50 个 `curl -N` 客户端，观察 RSS 与帧延迟 | RSS 增长 ≤ 5 MB，帧延迟 p90 ≤ 200 ms |
| 环形缓冲 | 缓冲 500 / 5000 条的 RSS 差 | ≤ 3 MB |
| 泄漏 | 200 次 connect/disconnect 后 fd/连接数回到基线 | 完全回基线 |

## 3. 测试工程

- `lab/perf-harness/`（不入本仓库）：Dart 脚本通过 App 的 `ApiClient` 跑 REST/SSE；Node 脚本向插件发合成事件；`adb` 脚本采内存/CPU/帧统计。
- App 内的采样开关：`--dart-define=PERF=1` 打开 `PerfProbe`（写 `files/perf.log`，JSONL），默认关闭、不参与发布构建。
- 输出：一份 `docs/perf-report.md`（本次数据 + 结论 + 改动前后对比），数据表必须有 p50/p90/max 与采样时长。

## 4. 审查前先确认的三件事

1. 分页滚动时 markdown 渲染成本（每页 50 条，滚到尽头才取更早一页）。
2. platform/stream SSE 在后台（App 切到后台/息屏）是否仍保持连接；是否需要退订。
3. 插件 `ctx.on('message')` 对**所有** bot 生效，是否有其它插件同样监听导致重复开销。


## 首轮基线（2026-11-18，vivo V2425A / Android 16，release APK）

| 指标 | 实测 | 口径 |
|---|---|---|
| 冷启动到首帧 | 284 / 297 / 411 ms（3 次） | `am start -W` 的 TotalTime，release 包 |
| 详情页 PSS | 177.7 MB | 打开会话 6 s 后 `dumpsys meminfo` |
| 详情页 RSS | 345.2 MB | 同上 |
| App 空闲 CPU | 0.0% | `top -b -n 1`，停在详情页 |
| 插件进程 RSS | 72.6 MB | `ps -o rss`，Node 常驻 |
| 插件空闲 CPU | 0.0% | `top` 单次 |
| SSE 连接 | 3 | `ss state established sport = :5028`（App 开详情页时） |
| 安装包 | release 21 MB / debug 162 MB | arm64 单 ABI |

结论与疑点：
- 启动 300 ms 量级，主要成本是 Flutter 引擎 + secure storage 初始化；可接受。
- PSS 177 MB 偏高，需归因：图片缓存（`_ChatImage` 解码后是否按 260×320 约束）、Markdown 树、SSE 缓冲。下一步用 DevTools memory snapshot 拆解。
- 插件 RSS 72.6 MB 是实例整包，插件本身占比未知；需要在插件里加一个 `/api/diag` 返回 `process.memoryUsage()` 差值来定位。
