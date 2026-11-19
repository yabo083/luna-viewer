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
  static const int _retryFloorSeconds = 15;
  static const int _retryCeilSeconds = 120;
  int _backoff = _retryFloorSeconds;
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
            // 任何帧都证明链路健康（`: ping` 也走这里）：退避回到下限。
            _backoff = _retryFloorSeconds;
            if (event.event == 'comment') return;
            final data = event.data;
            if (data == null) return;
            final key = data['key'];
            final message = PlatformMessage.fromJson(data['message']);
            if (key is! String || key.isEmpty || message == null) return;
            _collect(PlatformEvent(key, message));
          },
          onError: (Object error) {
            // 凭证失效不重试：按退避反复打 401 也不会自己恢复，只会耗电。
            // 把错误交给页面，由页面提示「重新连接」。
            if (error is ApiFailure && error.isUnauthorized) {
              _failAuth(error);
              return;
            }
            _scheduleRetry();
          },
          onDone: _scheduleRetry,
          cancelOnError: true,
        );
  }

  /// 401：停掉退避表，把错误原样送给订阅方，然后像 [dispose] 一样收尾连接。
  void _failAuth(ApiFailure error) {
    if (_closed) return;
    _closed = true;
    _retry?.cancel();
    _retry = null;
    _retrying = false;
    final sub = _sse;
    _sse = null;
    unawaited(sub?.cancel().catchError((Object _) {}));
    if (!_controller.isClosed) {
      // 没有订阅方时不要再 addError（会变成未处理异常）；关闭照做。
      if (_controller.hasListener) _controller.addError(error);
      _controller.close();
    }
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      try {
        _api.close();
      } catch (_) {}
    });
  }

  /// 断线退避 15→30→60→120s，封顶后不再涨。
  /// 下限 15s：空闲时每次重连都是一条新 TCP，1s 起步会在服务端抖动时刷出一串连接；
  /// 断线期间列表/详情本来就没有帧可看，等 15s 不影响内容（重连会回放最近消息）。
  void _scheduleRetry() {
    if (_closed || _retrying) return;
    _retrying = true;
    final seconds = _backoff;
    _backoff = seconds >= _retryCeilSeconds ? _retryCeilSeconds : seconds * 2;
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
