/// 能力层：平台消息的实时流（`GET /api/platform/stream`，SSE）。
///
/// 一帧 = 一个会话多了一条消息：`{key, message}`。连上时服务端先回放每个会话
/// 最近 5 条，之后实时推；重连会再放一遍，靠「key + 消息 id」去重。
/// 服务端**不做**订阅过滤：只看某个会话的调用方自己按 [PlatformEvent.key] 过滤。
library;

import 'dart:async';

import '../model/models.dart';
import '../transport/api_client.dart';

/// 一帧：哪个会话新增了哪条消息。
class PlatformEvent {
  const PlatformEvent(this.key, this.message);

  /// 插件会话键；与已加载会话 id 归一后比较。
  final String key;
  final PlatformMessage message;
}

class PlatformStream {
  PlatformStream(this.base, this.token) : _api = ApiClient(base: base, token: token) {
    _controller = StreamController<PlatformEvent>(
      onListen: _open,
      // 取消订阅必须真的关掉请求：推迟一拍，别在 onCancel 里同步关闭自己。
      onCancel: () => scheduleMicrotask(dispose),
    );
  }

  /// 去重集上限：只挡「同一个 id 重复入列」（重连重放 / 回放帧），旧 id 可以淘汰。
  static const _seenLimit = 600;

  final Uri base;
  final String? token;
  final ApiClient _api;

  late final StreamController<PlatformEvent> _controller;
  StreamSubscription<SseEvent>? _sse;
  Timer? _retry;
  final Set<String> _seen = {};
  int _backoff = 1;
  bool _retrying = false;
  bool _closed = false;

  /// 单订阅：页面打开期间消费一份；不再需要时 [dispose]。
  Stream<PlatformEvent> get events => _controller.stream;

  void _open() {
    if (_closed) return;
    _sse?.cancel();
    _sse = _api
        .sse('/api/platform/stream', includeComments: true)
        .listen(
          (event) {
            // 任何帧都证明链路健康（`: ping` 也走这里）：退避回到 1s。
            _backoff = 1;
            if (event.event == 'comment') return;
            final data = event.data;
            if (data == null) return;
            final key = data['key'];
            final message = PlatformMessage.fromJson(data['message']);
            if (key is! String || key.isEmpty || message == null) return;
            _collect(PlatformEvent(key, message));
          },
          // 401 之类也走同一条退避：不在能力层跳页，页面生命周期由调用方管。
          onError: (Object _) => _scheduleRetry(),
          onDone: _scheduleRetry,
          cancelOnError: true,
        );
  }

  /// 断线退避 1→2→4→8→16→30s，封顶后不再涨。
  void _scheduleRetry() {
    if (_closed || _retrying) return;
    _retrying = true;
    final seconds = _backoff;
    _backoff = seconds >= 16 ? 30 : seconds * 2;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: seconds), () {
      _retrying = false;
      _open();
    });
  }

  /// 同一个（会话, 消息 id）只发一次：重放与重连都会重复送。
  void _collect(PlatformEvent event) {
    if (!_seen.add('${event.key}\u0000${event.message.id}')) return;
    if (_seen.length > _seenLimit) _seen.remove(_seen.first);
    if (_closed || _controller.isClosed) return;
    _controller.add(event);
  }

  /// 关掉 SSE 与底层 http 连接。页面 `dispose` 与取消订阅都会走到这里。
  void dispose() {
    if (_closed) return;
    _closed = true;
    _retry?.cancel();
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
