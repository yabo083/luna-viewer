/// 能力层：入站消息旁路记录的实时流（`GET /api/traffic/stream`，SSE）。
///
/// 与 [TrafficRepository] 的分工：仓库一次拉一批（消息记录页），这里负责
/// 「详情页开着的那段时间里，进来一条补一条」。
/// 服务端**不做**会话过滤，唯一的过滤入口是 [candidateIdsOf] / [matchesTraffic]。
library;

import 'dart:async';

import '../model/models.dart';
import '../transport/api_client.dart';
import 'traffic_repository.dart';

/// 从会话标题里抽候选 id，统一小写：
/// - `[0-9A-Fa-f]{16,}`：QQ 私聊 openid 是长 16 进制串；
/// - `\d{7,}`：群号 / 频道号等长数字 id。
Set<String> candidateIdsOf(String title) {
  final ids = <String>{};
  for (final match in _candidatePattern.allMatches(title)) {
    final id = match.group(0);
    if (id != null && id.isNotEmpty) ids.add(id.toLowerCase());
  }
  return ids;
}

final RegExp _candidatePattern = RegExp(r'[0-9A-Fa-f]{16,}|\d{7,}');

/// 归一：去掉 `route:` 前缀与 `:user:` / `:lane:` 段。
/// 服务端 `conversationKey` 是 `r-<hash>`，App 会话 id 是 `route:r-<hash>:user:<id>`：
/// 两边归一后，同一个群 / 私聊 route 才相等。
String normalizeConversationKey(String value) {
  final trimmed = value.trim();
  final key = trimmed.startsWith(_routePrefix) ? trimmed.substring(_routePrefix.length) : trimmed;
  final cut = key.indexOf(_suffixMarker);
  return cut > 0 ? key.substring(0, cut) : key;
}

const String _routePrefix = 'route:';
final RegExp _suffixMarker = RegExp(r':(user|lane):');

/// 一条流量记录所属会话的归一键：
/// - 新插件给了会话键（`r-<hash>`）→ 归一后就是会话 id 的中段；
/// - 旧插件没有会话键 → 只能分到频道粒度，用 `平台\u0000频道`（[TrafficEntry.conversationKey]）。
///
/// 列表页用 `route:$key` 合成「仅流量会话」的 id，详情页再归一回来过滤实时流：
/// 这条规则是列表与详情两边唯一的一致性来源。
String trafficConversationKey(TrafficEntry entry) {
  final key = entry.serverKey?.trim() ?? '';
  if (key.isNotEmpty) return normalizeConversationKey(key);
  if (entry.platform.isEmpty && entry.channelId.isEmpty) return '';
  return entry.conversationKey;
}

/// 指令形态：`chatluna …`（插件命令空间）或以 `/` 开头的斜杠命令。
/// 普通消息同样会进旁路流，但它们在 `/events` 里已经有真实气泡，
/// 不能再画一张标成「指令」的卡：只有被指令层吃掉的那些才需要旁路补出来。
bool isCommandish(String text) {
  final head = text.trimLeft();
  return head.toLowerCase().startsWith('chatluna') || head.startsWith('/');
}

/// 命中条目的判断（任一命中即可）：
/// 1. 服务端给了会话键：归一后与 [sessionId] 相等；
/// 2. 没有会话键（旧插件）：条目的「平台 + 频道」分组键等于归一后的 [sessionId]
///    —— 仅流量会话的 id 就是 `route:` + 这个分组键，详情页因此能收到它的实时流；
/// 3. 标题里的候选 id：频道 / 群 / 发言者任一相同（忽略大小写）。
///
/// 后两级都要留：插件拿不到 `session.conversation` 时会把 `channelId` 填进会话键，
/// 那种键永远对不上会话 id（`r-<hash>`），只有标题 id 能兜住。
/// 反过来群会话里标题 id 是另一套命名空间，只有会话键能命中。
///
/// `routeId` 不参与判断：它是 `r-<sha256 前 12 位>`，标题里没有推导它的原料，且与 `conversationKey` 同值。
bool matchesTraffic(Set<String> ids, TrafficEntry entry, String sessionId) {
  final session = normalizeConversationKey(sessionId);
  final key = entry.serverKey;
  if (key != null && key.isNotEmpty) {
    if (normalizeConversationKey(key) == session) return true;
  } else if (entry.conversationKey == session) {
    // 旧插件没有会话键：仅流量会话的 id 就是 `route:平台\u0000频道`，与条目的分组键直接相等。
    return true;
  }
  if (ids.isEmpty) return false;
  for (final value in <String?>[entry.channelId, entry.guildId, entry.userId]) {
    if (value == null || value.isEmpty) continue;
    if (ids.contains(value.toLowerCase())) return true;
  }
  return false;
}

/// 一条入站消息的实时订阅：先收服务端回放的最近 20 条，之后实时推。
///
/// - 断线退避 1→2→4→8→16→30s；收到任意帧（含 15s 一次的 `: ping` 心跳）就回到 1s，
///   健康的连接断一次不会越等越久；
/// - 端点不存在（插件版本落后，404）时退化为 3s 轮询 `/api/traffic?limit=20`；
/// - `dispose`（或取消订阅）会真的关掉 SSE 请求，不留在后台空跑。
class TrafficStream {
  TrafficStream(this.base, this.token) : _api = ApiClient(base: base, token: token) {
    _controller = StreamController<TrafficEntry>(
      onListen: _open,
      // 取消订阅必须真的关掉请求：推迟一拍，别在 onCancel 里同步关闭自己。
      onCancel: () => scheduleMicrotask(dispose),
    );
  }

  /// 退化轮询周期：端点缺失时才用，正常路径一律走 SSE。
  static const pollInterval = Duration(seconds: 3);

  /// 去重集上限：只挡「同一个 id 重复入列」（重连重放 / 轮询重复拉），旧 id 可以淘汰。
  static const _seenLimit = 400;

  final Uri base;
  final String? token;
  final ApiClient _api;

  late final StreamController<TrafficEntry> _controller;
  StreamSubscription<SseEvent>? _sse;
  Timer? _retry;
  Timer? _poll;
  final Set<String> _seen = {};
  int _backoff = 1;
  bool _retrying = false;
  bool _polling = false;
  bool _closed = false;

  /// 单订阅：详情页打开期间消费一份；不再需要时 [dispose]。
  Stream<TrafficEntry> get entries => _controller.stream;

  void _open() {
    if (_closed) return;
    _sse?.cancel();
    _sse = _api
        .sse('/api/traffic/stream', includeComments: true)
        .listen(
          (event) {
            // 任何帧都证明链路健康（`: ping` 也走这里）：退避回到 1s。
            _backoff = 1;
            if (event.event != 'traffic') return;
            final entry = TrafficEntry.fromJson(event.data);
            if (entry != null) _collect(entry);
          },
          onError: (Object error) {
            if (error is ApiFailure && error.status == 404) {
              // 旧版插件没有 `/api/traffic/stream`：GET 会拐到静态资源处理上返回 404。
              // 这时只能退化轮询 `/api/traffic`（3s 一拍），保底把指令补出来；
              // 端点上线后页面重开即自动回到 SSE。
              _startPolling();
              return;
            }
            // 401 之类也走同一条退避：不在能力层跳页，页面生命周期由调用方管。
            _scheduleRetry();
          },
          onDone: _scheduleRetry,
          cancelOnError: true,
        );
  }

  /// 断线退避 1→2→4→8→16→30s，封顶后不再涨。
  void _scheduleRetry() {
    if (_closed || _retrying || _polling) return;
    _retrying = true;
    final seconds = _backoff;
    _backoff = seconds >= 16 ? 30 : seconds * 2;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: seconds), () {
      _retrying = false;
      _open();
    });
  }

  void _startPolling() {
    if (_closed || _polling) return;
    _polling = true;
    _sse?.cancel();
    _sse = null;
    _pollTick();
  }

  Future<void> _pollTick() async {
    if (_closed || !_polling) return;
    try {
      final items = await TrafficRepository(_api).list(limit: 20);
      if (_closed) return;
      // `list` 是新 → 旧：倒序发，调用方按到达顺序追加就是时间顺序。
      for (final entry in items.reversed) {
        _collect(entry);
      }
    } on ApiFailure {
      // 轮询失败不向上层抛：下一拍再来，详情页照常显示历史。
    } catch (_) {
      // 解析异常同样吞掉：这条链路只负责补消息，不能把页面拖垮。
    }
    if (_closed || !_polling) return;
    _poll = Timer(pollInterval, _pollTick);
  }

  /// 同一个 id 只发一次；重放 / 轮询重复拉到的不再打扰上层。
  void _collect(TrafficEntry entry) {
    final key = entry.dedupeKey;
    if (!_seen.add(key)) return;
    if (_seen.length > _seenLimit) _seen.remove(_seen.first);
    _emit(entry);
  }

  void _emit(TrafficEntry entry) {
    if (_closed || _controller.isClosed) return;
    _controller.add(entry);
  }

  /// 关掉 SSE / 轮询与底层 http 连接。页面 `dispose` 与取消订阅都会走到这里。
  void dispose() {
    if (_closed) return;
    _closed = true;
    _retry?.cancel();
    _poll?.cancel();
    final sub = _sse;
    _sse = null;
    // 先取消订阅、让在途响应正常收尾；立刻 close 会让它以 ClientException 结束并被当成未处理错误。
    unawaited(sub?.cancel().catchError((Object _) {}));
    _controller.close();
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      try {
        _api.close();
      } catch (_) {}
    });
  }
}
