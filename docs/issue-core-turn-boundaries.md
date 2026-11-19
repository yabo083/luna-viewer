# [Feature] `/live`: 显式轮次边界事件 `turn/start` / `turn/end`

> 目标仓库：ChatLunaLab/chatluna（`packages/api/core`，必要时 `packages/agent/core`）
> 发起人：第三方客户端维护者（Flutter 移动端，QQ + Web 会话）
> 难度评估：**小**（约 60–90 行 + 测试；不涉及数据库、协议版本、权限）

## 背景

`/api/sessions/:id/live` 目前只暴露 **attempt 级**的事件：

- `snapshot`（当前 attempt 的快照或 null）
- `agent/assistant-stream`（`part` 帧：reasoning / text / tool-input）
- `agent/assistant-settled`（一次 attempt 结束）

但一次 **turn** 可以由多个 attempt 与多个步骤组成（工具调用、异步工具转后台、后续 step 再开一轮 attempt）。客户端无法从 `/live` 直接得知「这一轮什么时候开始、什么时候真的结束」，只能用 `/events` 的 mark + `/api/sessions` 的 `running` 推断，代价是三处歧义：

1. **起点**：`agent/input-enqueued` 只表示「有输入排队」，`target: "next-turn"` 会等定时/唤醒，不是立即开跑；真正的开跑要等 `agent/input-admitted` 或 `engine/activity {stage:prepare}`，两者与首个 attempt 帧之间还差几十到几百毫秒。
2. **终点**：`agent/assistant-settled` 是 attempt 结束，不代表本轮结束；本轮真正结束要等「最后一条 bot 外发落库 + `running=false`」，实测 `settled` 与 `chat/delivered` 之间有 **1–2 秒**差。
3. **异步工具（draw 等）**：工具会在 attempt settle 之后继续执行、产物稍后由新 attempt 处理；客户端必须自己判定「工具还没返回 = 转后台」，否则阶段计时被缩短到只含参数生成时间（实测 1.6 s 对 25 s）。

这些推断逻辑每个客户端都要重写一遍，且容易写错（我们的移动端就踩过整套）。

## 提议

在 `/live` 上增加两个显式事件（SSE `event:` 名即协议）：

```text
event: turn/start
data: {"sessionId":"route:...","turn":31,"at":1795026108000,"streamEpoch":"..."}

event: turn/end
data: {"sessionId":"route:...","turn":31,"at":1795026143000,"reason":"settled","streamEpoch":"..."}
```

语义：

- `turn/start`：该 turn 的 agent 循环真正开始执行（`++state.turn` 之后、首个 step 之前）。**同一 turn 只发一次**；断线重连由 `snapshot` 携带当前 `turn` 状态（见下）。
- `turn/end`：`chatluna/agent-turn` 事件到达时发（即 agent 的内层循环结束），`reason` 取 agent 的 `TurnResult['reason']`（`settled` / `blocked` / `max-steps` / `skipped` / `preset-rejected` …）。
  - 投递（`chat/delivered`）仍可能在其后 1–2 秒发生；`turn/end` 不承诺「消息已送达」，只承诺「本轮不再产生新的 attempt」。需要投递确认的客户端继续读 `/events`，但**不需要它来判断轮次边界**。
- `snapshot` 增加字段 `turn`（当前进行中的 turn 号，没有则 null），让重连的客户端不必从历史 mark 里猜。

## 实现要点（可行性已核对）

1. **起点**：`packages/agent/core/src/loop/agent.ts` 在 `const turn = ++this.state.turn` 之后新增 `this.ctx.emit('chatluna/agent-turn-start', { agent: this, turn })`；`packages/agent/core/src/events.ts` 补事件声明。
   - 备选（完全不改 agent 包）：在 `packages/api/core/src/index.ts` 里监听 `chatluna/agent-output`，按 `event.turn` 与每会话已见最大 turn 比较，首次出现即发 `turn/start`。代价是「没有输出的 turn」（`blocked`/`skipped`）不会发 `turn/start`，但 `turn/end` 仍会到；客户端可容忍。
2. **终点**：`packages/api/core/src/index.ts` 在构造函数里 `ctx.on('chatluna/agent-turn', ({agent, reason}) => ...)`，用 `agent.session.id` 找会话、转发到 `chatluna-api/live`。
3. **转发**：`attachLiveStream` 的 `forward()` 目前只有 `frame` / 其它（settled）两个分支；新增 `kind: 'turn'` 分支，按事件名 `turn/start` / `turn/end` 发送。
4. **类型**：`LiveEvent` 联合类型补 `{ kind: 'turn'; phase: 'start' | 'end'; sessionId; turn; at; reason?; streamEpoch; revision }`。
5. **快照**：`liveAttempts` 之外维护 `Map<sessionId, turn>`，随 `turn/start`/`turn/end` 更新；`snapshot` 里带上当前值。

## 兼容性

- SSE 客户端按事件名分派，未知事件名会被忽略（我们的 Flutter 客户端、浏览器 `EventSource` 都是这样），因此**新增事件是向后兼容的**，不需要协议版本号。
- 现有 `agent/assistant-*` 行为完全不变。

## 测试

- `tests/integration/server-api.test.ts`：现有 live 测试基础上断言一次完整 turn 的事件序列含 `turn/start`（一次）→ 若干 `agent/assistant-stream` → `turn/end`（一次，`reason === 'settled'`）。
- 覆盖异步工具场景（或构造多 step）：`turn/end` 只在最后一步之后出现一次，中间 attempt 的 settled 不产生 `turn/end`。
- 覆盖 `blocked`/`skipped`：`turn/end` 的 `reason` 正确，且不要求 `turn/start` 一定出现（若采用备选方案）。

## 备选方案与不采用的理由

| 方案 | 不采用原因 |
|---|---|
| 客户端继续用 `/events` mark 推断 | 已是各客户端的重复劳动；`enqueued` 与真正开跑之间不可靠，`settled` 与投递之间 1–2 s 差需要额外 grace 窗口 |
| 暴露 `/api/sessions` 的 `running` 轮询 | 1–3 s 粒度，且多实例/多会话下轮询成本高 |
| 只发 `turn/end` | 起点仍需猜，收益减半 |

## 影响面

- `packages/agent/core`（事件声明，可选实现点）
- `packages/api/core`（转发 + 类型 + snapshot 字段）
- WebUI 可选：改用 `turn/start`/`turn/end` 后可以删掉 `running` 轮询与 grace 判定

## 我们这边的依赖

Flutter 客户端当前用「本地计时 + `/events` mark 校正」实现，`turn/start`/`turn/end` 一到即可删掉 `_verifyTurnEnd` 的 grace 判定和 `/api/sessions` 轮询兜底，状态机可减约 150 行。这也是我们提这个 issue 的直接动机。
