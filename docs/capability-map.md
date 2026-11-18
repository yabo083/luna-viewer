# 能力集 ↔ 端点（唯一权威副本）

任何新增路径先加进这张表再写代码。表里没有的路径 = 未经验证，禁止使用。

## 鉴权

| 事 | 调用 | 备注 |
|---|---|---|
| 探活 | `GET /api/health` | 公开，返回 `{ok,name,version}`；局域网发现指纹 |
| 密码/token 登录 | `POST /api/auth/login {token}` | 公开；返回 `{session,expiresAt}`；session 是 30 天 HMAC 串 |
| 验证码登录 | `GET /api/auth/code` → `POST /api/auth/code/send {target}` → `POST /api/auth/code/verify {code}` | 全部公开；码由机器人在聊天平台发出 |
| 确认会话 | `GET /api/auth/session` | 返回 `{source:'config'\|'env'\|'file'}`；顺带续签 |
| 轮换 | `POST /api/auth/token {current,next}` | 换新 access token |
| 登出 | `POST /api/auth/logout` | 服务端清 session |

所有 `/api/*` 请求一律 `Authorization: Bearer <session 或 access token>`。**cookie 不授权 `/api`。**

## 会话

| 事 | 调用 | 关键返回 |
|---|---|---|
| 列表 | `GET /api/sessions?cursor=&limit=` | `{items:[{id,title,createdAt,origin,running,engine,model}],nextCursor?}` |
| 新建 | `POST /api/sessions {title?,presetId?,engine?,model?}` + idem | 201 `{id,title,createdAt}` |
| 改名 | `POST /api/sessions/:id/title {title}` | `{ok:true}` |
| 删除 | `DELETE /api/sessions/:id` | `{ok:true}`（日志保留） |
| 历史 | `GET /api/sessions/:id/messages` | `{messages,length,cacheBreaks}` |
| 请求原文 | `GET /api/sessions/:id/request/:seq` | `{seq,request}` |
| 发消息 | `POST /api/sessions/:id/messages {text}` 或 `{content:[…]}` + idem | 202 `{accepted:true}`；仅 web 来源会话 |
| 插话 | `POST /api/sessions/:id/steer {text}` | 202 `{accepted:true}` |
| 取消 | `POST /api/sessions/:id/cancel` | `{ok:true}` |
| 压缩 | `POST /api/sessions/:id/compact {keep?}` | `{before,after,cut?}` |
| 分叉 | `POST /api/sessions/:id/fork {boundary?}` + idem | 201 `{sessionId,length,parent}` |
| 换模型 | `POST /api/sessions/:id/model {provider,model}` | `{ok:true,model}` |
| 实时流 | `GET /api/sessions/:id/live`（SSE） | `snapshot` / `agent/assistant-stream` / `agent/assistant-settled` / `lagged` |
| 事件流 | `GET /api/sessions/:id/events`（SSE） | `message` / `cut` / mark；`Last-Event-ID` 续传，超限先发 `truncated` |
| 多 agent | `GET /api/agents` | `[{rootSessionId,members:[…]}]` |
| 待审批 | `GET /api/interaction/pending?routeId=` / `POST /api/interaction/answer {routeId,answer}` | 回合会挂起等待 |
| 附件（storage） | `GET /files/:name` | 无鉴权、无 `/api` 前缀 |
| 工作区文件（伴侣插件） | `GET /api/workspace?path=<相对路径>` | 需 Bearer；路径限定在 `data/chatluna/agents-work`；消息里的相对 `<img src>` 走这里 |

## 平台消息（伴侣插件，App 的真源）

| 事 | 调用 | 说明 |
|---|---|---|
| 会话列表 | `GET /api/platform/conversations` | `{items:[{key,platform,selfId,channelId,guildId,kind,title,count,last}]}`，按最后消息倒序 |
| 消息分页 | `GET /api/platform/messages?key=&limit=&before=` | 时间升序，`before` 取更早一页，`hasMore` 判定 |
| 实时流 | `GET /api/platform/stream`（SSE） | 帧 `{key,message:{id,time,dir,userId,content}}`，连上先回放每会话最近 5 条 |

App 的会话与消息都以此为准；`/api/sessions*` 只提供已加载会话的状态与操作（模型、压缩、分叉、中止）。

## 平台与 bot

WS `sub {key:'adapters.bots'}` → `{bots:[{platform,selfId,status,user:{id,name,nick,avatar}}]}`。
WebUI「聊天平台」卡片显示的头像就来自 `user.avatar`；App 用同一个源，取不到时退化为渐变图标。

## 模型与引擎

`GET /api/engines`（引擎 + 每引擎可用预设）、`GET /api/models`、`GET /api/models/providers`、`GET /api/models/catalog`、`POST /api/models/discover {provider,baseURL,apiKey?}`、`GET /api/commands`。

## 预设

读：`GET /api/presets`（`{items,loaders}`）、`GET /api/presets/:id/download`；详情与源码走 WS state `presets.detail`。
写（全部 `POST /api/action/<name>`）：

| 动作 | 输入 |
|---|---|
| `presets.save` | `{id, text, revision?}`（revision 为字符串 SHA） |
| `presets.preview` | `{id, text?, env?, sample?}` |
| `presets.create` | `{id, loader, text?}` |
| `presets.remove` | `{id, revision?}` |
| `presets.duplicate` | `{id, target}` |
| `presets.import` | `{files:[{name,content,encoding}]}` |
| `presets.convert` | `{id}` |

## 路由与配置

读：WS `sub` → `routing.rules`、`routing.rule`、`routing.namespaces`、`routing.reach`、`routing.inherited`、`presets`、`providers`、`schema`。
写：`routing.save`（乐观锁 `ifRevision`，数字）、`routing.remove {id,ifRevision}`、`routing.reorder {ids,ifRevision}`、`routing.explain {}` → `{ruleIds,values}`。

## 能力层方法（Dart）

```dart
abstract class SessionRepository {
  Future<Page<SessionSummary>> list({String? cursor, int limit = 50});
  Future<SessionSummary> create({String? title, String? presetId, String? engine, ModelRef? model});
  Future<void> rename(String id, String title);
  Future<void> delete(String id);
  Future<Transcript> transcript(String id);
  Future<void> send(String id, MessageDraft draft);   // 202 已受理，不等结果
  Future<void> steer(String id, String text);
  Future<void> cancel(String id);
  Future<CompactResult> compact(String id, {int? keep});
  Future<SessionSummary> fork(String id, {Object? boundary});
  Future<void> setModel(String id, ModelRef model);
}

abstract class PlatformRepository {
  Future<List<PlatformConversation>> conversations();
  Future<PlatformMessagePage> messages(String key, {int limit = 50, DateTime? before});
}

/// `GET /api/platform/stream`：帧 `{key,message}`，服务端不过滤，调用方按 key 过滤。
abstract class PlatformStream {
  Stream<PlatformEvent> get events;
  void dispose();
}

abstract class ConfigRepository {
  Stream<RoutingRule> rule(String id);          // WS state
  Future<RoutingRule> save(RoutingRuleInput input, {int? ifRevision});
  Future<Explanation> explain();
}

abstract class PresetRepository {
  Future<List<PresetSummary>> list();
  Stream<PresetDetail> detail(String id);
  Future<Preview> preview(String id, {String? text, Map<String,Object?>? env, String? sample});
  Future<PresetDetail> save(String id, String text, {String? revision});
}
```

`LiveBus` 对上只暴露 `Stream<LiveEvent>`（`delta` / `settled` / `lagged` / `event`），页面按 sessionId 过滤。
