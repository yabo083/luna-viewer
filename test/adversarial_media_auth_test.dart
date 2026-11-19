/// 对抗性用例：消息里的**外链图片**不得带上实例 token。
///
/// 走 `MessageView` 的真实渲染路径（markdown 图片 → `_ChatImage` → `Image.network`），
/// 用 `debugNetworkImageHttpClientProvider` 截获每一次图片请求的 URL 与请求头。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatluna_mobile/core/model/models.dart';
import 'package:chatluna_mobile/features/chat/message_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1×1 PNG：让解码成功，避免「解码失败 → 2s 自动重试定时器」干扰用例。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
  'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _Recorder {
  final Map<String, Map<String, List<String>>> headerByUrl = {};
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.rec);

  final _Recorder rec;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeRequest(rec, url);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, List<String>> values = {};

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    values.putIfAbsent(name.toLowerCase(), () => []).add('$value');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.rec, this.url);

  final _Recorder rec;
  final Uri url;
  final _FakeHeaders _headers = _FakeHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async {
    rec.headerByUrl[url.toString()] = _headers.values;
    return _FakeResponse(_png);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponse implements HttpClientResponse {
  _FakeResponse(this.bytes);

  final List<int> bytes;

  @override
  int get statusCode => 200;

  @override
  int get contentLength => bytes.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _base = 'http://192.168.0.107:5028';
const _bearer = 'Bearer test-token';

Future<void> _pump(
  WidgetTester tester,
  ChatMessage message, {
  List<PlatformMedia> media = const <PlatformMedia>[],
  Map<String, String> headers = const {'authorization': _bearer},
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MessageView(
          message: message,
          media: media,
          base: Uri.parse(_base),
          headers: headers,
          noticeOpen: <String, bool>{},
        ),
      ),
    ),
  );
  // 图片解析在微任务里发起请求；多推几帧等它落地。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

ChatMessage _text(String body) => ChatMessage.fromJson({
  'role': 'user',
  'content': [
    {'type': 'text', 'text': body},
  ],
  'form': 'message',
});

void main() {
  testWidgets('P0 待修：外链 markdown 图片携带实例 Bearer', (tester) async {
    final rec = _Recorder();
    final previous = debugNetworkImageHttpClientProvider;
    debugNetworkImageHttpClientProvider = () => _FakeHttpClient(rec);
    try {
      await _pump(tester, _text('看这张 ![x](https://evil.example/leak.png)'));

      final external = rec.headerByUrl.keys
          .where((url) => url.contains('evil.example'))
          .toList();
      expect(external, isNotEmpty, reason: '外链图片应该真的走网络请求（否则用例没有覆盖到路径）');
      for (final url in external) {
        expect(
          rec.headerByUrl[url]!.keys,
          isNot(contains('authorization')),
          reason: '实例 token 被发给了外部主机：$url（${rec.headerByUrl[url]}）',
        );
      }
    } finally {
      debugNetworkImageHttpClientProvider = previous;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    }
  });

  testWidgets('P0 待修：联系人发来的正文 markdown 图片同样泄露 token（无需 bot 配合）', (tester) async {
    final rec = _Recorder();
    final previous = debugNetworkImageHttpClientProvider;
    debugNetworkImageHttpClientProvider = () => _FakeHttpClient(rec);
    try {
      // 群聊里任何人发一条含 markdown 图片的消息，App 打开详情就会去取。
      final platform = PlatformMessage.fromJson({
        'id': 'p1',
        'time': 1763000000000,
        'dir': 'in',
        'content': '![a](https://attacker.example/pixel.png)',
      });
      await _pump(tester, platform!.view);

      final external = rec.headerByUrl.keys
          .where((url) => url.contains('attacker.example'))
          .toList();
      expect(external, isNotEmpty);
      for (final url in external) {
        expect(
          rec.headerByUrl[url]!.keys,
          isNot(contains('authorization')),
          reason: '远程联系人触发的取图请求带上了实例 token：$url',
        );
      }
    } finally {
      debugNetworkImageHttpClientProvider = previous;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    }
  });

  testWidgets('对照组：实例内 /files 图片带 Bearer', (tester) async {
    final rec = _Recorder();
    final previous = debugNetworkImageHttpClientProvider;
    debugNetworkImageHttpClientProvider = () => _FakeHttpClient(rec);
    try {
      await _pump(tester, _text('![x](/files/a.png)'));

      final local = rec.headerByUrl.keys
          .where((url) => url.contains('/files/a.png'))
          .toList();
      expect(local, isNotEmpty);
      for (final url in local) {
        expect(rec.headerByUrl[url]!.keys, contains('authorization'), reason: url);
      }
    } finally {
      debugNetworkImageHttpClientProvider = previous;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    }
  });

  testWidgets('对照组：platform media 里的外链图片不带 Bearer（正确实现路径）', (tester) async {
    final rec = _Recorder();
    final previous = debugNetworkImageHttpClientProvider;
    debugNetworkImageHttpClientProvider = () => _FakeHttpClient(rec);
    try {
      await _pump(
        tester,
        _text('图片'),
        media: const [PlatformMedia(kind: 'image', url: 'https://evil.example/m.png')],
      );

      final external = rec.headerByUrl.keys
          .where((url) => url.contains('evil.example'))
          .toList();
      expect(external, isNotEmpty);
      for (final url in external) {
        expect(rec.headerByUrl[url]!.keys, isNot(contains('authorization')));
      }
    } finally {
      debugNetworkImageHttpClientProvider = previous;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
    }
  });
}
