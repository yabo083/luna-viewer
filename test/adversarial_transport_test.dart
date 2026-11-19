/// 对抗性用例：传输层与仓储层在「坏网络 / 坏字段」下的表现。
///
/// 全部用 `MockClient` 充当服务端：不碰真机、不碰实例。
/// 命名里带「待修」的用例是当前实现会露出的真实缺陷（红），修 lib 之后应当转绿。
/// 失败不是用例写错，而是 `docs/adversarial-review.md` 里的待修项。
library;

import 'dart:async';
import 'dart:convert';

import 'package:chatluna_mobile/core/capability/platform_repository.dart';
import 'package:chatluna_mobile/core/capability/sessions_repository.dart';
import 'package:chatluna_mobile/core/model/models.dart';
import 'package:chatluna_mobile/core/transport/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final Uri base = Uri.parse('http://192.168.0.107:5028');

/// 普通 REST 客户端：handler 直接给 `Response`。
ApiClient rest(
  Future<http.Response> Function(http.Request request) handler, {
  String token = 'test-token',
}) => ApiClient(base: base, token: token, client: MockClient(handler));

/// SSE 客户端：把整段原始帧（含 `\n\n`）当作响应体一次吐出。
ApiClient sse(String payload, {int status = 200}) => ApiClient(
  base: base,
  token: 'test-token',
  client: MockClient.streaming((request, _) async {
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(payload)),
      status,
      request: request,
    );
  }),
);

String frame(String event, Map<String, Object?> data, {String? id}) =>
    '${id == null ? '' : 'id: $id\n'}event: $event\ndata: ${jsonEncode(data)}\n\n';

void main() {
  group('状态码与返回体', () {
    test('500 的 HTML 错误页整段进 message（UI 会原样显示给用户）', () async {
      const page = '<html><body><h1>502 Bad Gateway</h1><p>nginx/1.24.0</p></body></html>';
      final api = rest((_) async => http.Response(page, 500));
      addTearDown(api.close);

      await expectLater(
        api.getJson('/api/sessions'),
        throwsA(
          isA<ApiFailure>()
              .having((e) => e.code, 'code', 'INTERNAL')
              .having((e) => e.status, 'status', 500)
              .having((e) => e.message, 'message', contains('<html>')),
        ),
      );
    });

    test('402 没有专门映射：code 退成 UNKNOWN（服务端正文仍保留）', () async {
      final api = rest(
        (_) async => http.Response(
          jsonEncode({'message': '额度已用完，请在 WebUI 充值'}),
          402,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.getJson('/api/sessions'),
        throwsA(
          isA<ApiFailure>()
              .having((e) => e.code, 'code', 'UNKNOWN')
              .having((e) => e.status, 'status', 402)
              .having((e) => e.message, 'message', contains('额度已用完')),
        ),
      );
    });

    test('401：UNAUTHORIZED 透出，正文里的 message 不被丢弃', () async {
      final api = rest(
        (_) async => http.Response(
          jsonEncode({'code': 'UNAUTHORIZED', 'message': 'token 已轮换'}),
          401,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.getJson('/api/sessions'),
        throwsA(
          isA<ApiFailure>()
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)
              .having((e) => e.message, 'message', 'token 已轮换'),
        ),
      );
    });

    test('404 有专门映射', () async {
      final api = rest((_) async => http.Response('', 404));
      addTearDown(api.close);
      await expectLater(
        api.getJson('/api/sessions/s1'),
        throwsA(isA<ApiFailure>().having((e) => e.code, 'code', 'NOT_FOUND')),
      );
    });

    test('200 返回非 JSON：INTERNAL，且不把正文当数据', () async {
      final api = rest((_) async => http.Response('<html>login</html>', 200));
      addTearDown(api.close);
      await expectLater(
        api.getJson('/api/sessions'),
        throwsA(isA<ApiFailure>().having((e) => e.code, 'code', 'INTERNAL')),
      );
    });

    test('204 → null', () async {
      final api = rest((_) async => http.Response('', 204));
      addTearDown(api.close);
      expect(await api.getJson('/api/sessions'), isNull);
    });

    test('待修：JSON 没带 charset 时按 latin1 解码，中文标题变乱码', () async {
      final api = rest(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'items': [
                {'id': 's1', 'title': '与小猫的对话'},
              ],
            }),
          ),
          200,
          // 故意不带 charset：很多反代/老服务端就这样回。
          headers: {'content-type': 'application/json'},
        ),
      );
      addTearDown(api.close);
      final page = await SessionsRepository(api).list();
      expect(
        page.items.single.title,
        '与小猫的对话',
        reason: '客户端应固定按 UTF-8 解码（jsonDecode(utf8.decode(bodyBytes))）',
      );
    });
  });

  group('SSE 解析', () {
    test('CRLF、注释心跳、event 名复位', () async {
      final api = sse(
        ': ping\r\n'
        '\r\n'
        'event: snapshot\r\n'
        'id: s:1\r\n'
        'data: {"n":1}\r\n'
        '\r\n'
        'data: {"n":2}\r\n'
        '\r\n',
      );
      addTearDown(api.close);
      final events = await api.sse('/api/x', includeComments: true).toList();
      expect(events.map((e) => e.event), ['comment', 'snapshot', 'message']);
      expect(events[1].id, 's:1');
      expect(events[2].data, {'n': 2});
    });

    test('非 JSON 的 data：不抛错，data 为 null（坏帧被静默丢弃）', () async {
      final api = sse('event: message\ndata: {"n":1\n\n');
      addTearDown(api.close);
      final events = await api.sse('/api/x').toList();
      expect(events.single.event, 'message');
      expect(events.single.data, isNull);
    });

    test('超过 1MB 的单帧不截断', () async {
      final huge = 'x' * (1200 * 1024);
      final api = sse('event: message\ndata: {"text":"$huge"}\n\n');
      addTearDown(api.close);
      final events = await api.sse('/api/x').toList();
      expect((events.single.data!['text']! as String).length, huge.length);
    });

    test('id 在连接内沿用：下一帧没有 id 时沿用上一帧（SSE 规范）', () async {
      final api = sse(
        'id: s:7\nevent: message\ndata: {"n":7}\n\nevent: message\ndata: {"n":8}\n\n',
      );
      addTearDown(api.close);
      final events = await api.sse('/api/x').toList();
      expect(events.map((e) => e.id), ['s:7', 's:7']);
    });

    test('500 且没有帧：抛 ApiFailure 而不是静默结束', () async {
      final api = sse('', status: 500);
      addTearDown(api.close);
      await expectLater(
        api.sse('/api/x').toList(),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 500)),
      );
    });

    test('401 的 SSE 以 UNAUTHORIZED 结束（调用方据此跳登录）', () async {
      final api = sse('', status: 401);
      addTearDown(api.close);
      await expectLater(
        api.sse('/api/x').toList(),
        throwsA(isA<ApiFailure>().having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)),
      );
    });

    test('待修：错误响应的 body 永远读不完时，既不报错也不重连（半死连接）', () async {
      // 反代/移动网络常见：响应头已到，错误页的 body 卡住不收尾。
      // 服务端把 502 的错误页分块发出后 TCP 半死，`sse()` 会永久停在 bytesToString()。
      final controller = StreamController<List<int>>();
      final api = ApiClient(
        base: base,
        token: 'test-token',
        client: MockClient.streaming((request, _) async {
          return http.StreamedResponse(controller.stream, 502, request: request);
        }),
      );
      addTearDown(() async {
        await controller.close();
        api.close();
      });

      final pending = api.sse('/api/platform/stream').toList();
      // 吞掉 teardown 关流后迟到的错误，避免污染下一个用例。
      unawaited(pending.then<void>((_) {}, onError: (Object _) {}));

      await expectLater(
        pending.timeout(const Duration(seconds: 2)),
        throwsA(isA<ApiFailure>()),
        reason: '错误响应体需要超时（如 5s），否则 PlatformStream / /events 永远不会退避重连',
      );
    });
  });

  group('仓储层：坏字段不能打死整页', () {
    test('待修：/api/sessions 里 running 是 1 时整页抛 TypeError', () async {
      final api = rest(
        (_) async => http.Response(
          jsonEncode({
            'items': [
              {'id': 's1', 'title': 'ok', 'running': false},
              {'id': 's2', 'title': 'bad', 'running': 1},
            ],
          }),
          200,
        ),
      );
      addTearDown(api.close);
      await expectLater(
        SessionsRepository(api).list(),
        throwsA(isA<ApiFailure>()),
        reason: '一条坏行不该让整个会话列表变错误页；解析应容错或转成 ApiFailure',
      );
    });

    test('待修：createdAt 是 ISO 字符串时整页抛 TypeError', () async {
      final api = rest(
        (_) async => http.Response(
          jsonEncode({
            'items': [
              {'id': 's1', 'title': 'ok', 'createdAt': '2026-11-19T10:00:00.000Z'},
            ],
          }),
          200,
        ),
      );
      addTearDown(api.close);
      await expectLater(SessionsRepository(api).list(), throwsA(isA<ApiFailure>()));
    });

    test('待修：items 不是数组时整页抛 TypeError（应为 ApiFailure 或空页）', () async {
      final api = rest((_) async => http.Response(jsonEncode({'items': {'a': 1}}), 200));
      addTearDown(api.close);
      await expectLater(SessionsRepository(api).list(), throwsA(isA<ApiFailure>()));
    });

    test('待修：/api/platform/conversations 里 count 是字符串时整表抛 TypeError', () async {
      final api = rest(
        (_) async => http.Response(
          jsonEncode({
            'items': [
              {'key': 'r-1', 'title': 'a', 'count': 3},
              {'key': 'r-2', 'title': 'b', 'count': '12'},
            ],
          }),
          200,
        ),
      );
      addTearDown(api.close);
      await expectLater(PlatformRepository(api).conversations(), throwsA(isA<ApiFailure>()));
    });

    test('待修：消息块的 type 不是字符串时整段 transcript 抛 TypeError', () async {
      final api = rest(
        (_) async => http.Response(
          jsonEncode({
            'messages': [
              {
                'id': 'm1',
                'role': 'assistant',
                'content': [
                  {'type': 5, 'text': 'bad'},
                ],
              },
            ],
            'length': 1,
          }),
          200,
        ),
      );
      addTearDown(api.close);
      await expectLater(SessionsRepository(api).transcript('s1'), throwsA(isA<ApiFailure>()));
    });

    test('待修：settled 的 reason 不是字符串时整条 /live 流被异常打断', () async {
      final api = sse(frame('agent/assistant-settled', {
        'outcome': {'reason': 7},
      }));
      addTearDown(api.close);
      final events = await SessionsRepository(api).live('s1').toList();
      expect(events.single.kind, LiveEventKind.settled);
      expect(events.single.reason, isNull, reason: '坏 reason 应降级为 null，而不是抛异常');
    });

    test('待修：hasMore 是 1 时被当成 false，翻页提前结束', () async {
      final api = rest(
        (_) async => http.Response(
          jsonEncode({
            'items': [
              {'id': 'm1', 'time': 1763000000000, 'dir': 'in', 'content': 'hi'},
            ],
            'hasMore': 1,
          }),
          200,
        ),
      );
      addTearDown(api.close);
      final page = await PlatformRepository(api).messages('r-1');
      expect(page.items, hasLength(1));
      expect(page.hasMore, isTrue);
    });
  });

  group('/events 帧', () {
    test('mark 的 time 是字符串毫秒时被丢弃（重放过滤因此失效）', () async {
      final api = sse(frame('mark', {
        'n': 3,
        'kind': 'mark',
        'name': 'prompt',
        'time': '1795026108000',
      }));
      addTearDown(api.close);
      final events = await SessionsRepository(api).events('s1').toList();
      expect(events.single.name, 'prompt');
      expect(
        events.single.time?.millisecondsSinceEpoch,
        1795026108000,
        reason: '字符串毫秒应被接受；否则 ChatPage 的 `_eventsOpenedAt` 过滤无从判断新旧',
      );
    });

    test('message 是数组的帧被静默丢弃（不是崩溃，但消息永远不出现）', () async {
      final api = sse(frame('message', {
        'n': 1,
        'kind': 'message',
        'message': [
          {'id': 'm1', 'role': 'user'},
        ],
      }));
      addTearDown(api.close);
      expect(await SessionsRepository(api).events('s1').toList(), isEmpty);
    });

    test('cut 帧推进游标（否则重连会把上一轮的 mark 重放）', () async {
      final api = sse(frame('mark', {'n': 9, 'kind': 'cut'}, id: 's1:9'));
      addTearDown(api.close);
      final events = await SessionsRepository(api).events('s1').toList();
      expect(events.single.name, 'cut');
      expect(events.single.id, 's1:9');
    });

    test('truncated 帧转成 SessionEvent.truncated（调用方应据此重取全量）', () async {
      final api = sse(frame('truncated', {}));
      addTearDown(api.close);
      final events = await SessionsRepository(api).events('s1').toList();
      expect(events.single.truncated, isTrue);
    });

    test('待修：帧没有 id 且带 n 时仍沿用上一帧的 id，第二条被去重吞掉', () async {
      final api = sse(
        'id: s1:10\nevent: message\ndata: {"n":10,"kind":"message","message":'
        '{"role":"assistant","form":"notice","content":[{"type":"text","text":"第一条"}]}}\n\n'
        // 第二帧服务端漏了 id，但带了 n（旧数据/半截帧）。
        'event: message\ndata: {"n":11,"kind":"message","message":'
        '{"role":"assistant","form":"notice","content":[{"type":"text","text":"第二条"}]}}\n\n',
      );
      addTearDown(api.close);
      final events = await SessionsRepository(api).events('s1').toList();
      expect(events, hasLength(2));
      final ids = events.map((event) => event.message!.id).toList();
      expect(
        ids.toSet(),
        hasLength(2),
        reason: '两条不同消息拿到同一个 id ($ids)：UI 的 _frameworkIds 会丢掉后一条；'
            '有 n 时应优先用 `sessionId:n`，而不是沿用的 SSE id',
      );
      expect(events.last.id, 's1:11');
    });
  });

  group('URL 编码与凭证', () {
    test('route: 会话 id 逐段编码，token 只在头里', () async {
      late Uri seen;
      late Map<String, String> headers;
      final api = rest((request) async {
        seen = request.url;
        headers = request.headers;
        return http.Response('{}', 200);
      });
      addTearDown(api.close);

      await SessionsRepository(api).cancel('route:r-1:user:2');

      expect(seen.toString(), contains('route%3Ar-1%3Auser%3A2'));
      expect(seen.toString(), isNot(contains('test-token')));
      expect(seen.query, isEmpty);
      expect(headers['authorization'], 'Bearer test-token');
      expect(seen.pathSegments.last, 'cancel');
    });

    test('平台会话 key 作为查询参数按值编码（& # + 不撕开 URL）', () async {
      late Uri seen;
      final api = rest((request) async {
        seen = request.url;
        return http.Response(jsonEncode({'items': [], 'hasMore': false}), 200);
      });
      addTearDown(api.close);

      await PlatformRepository(api).messages('a+b&c#d', limit: 50);

      expect(seen.queryParameters['key'], 'a+b&c#d');
      expect(seen.queryParameters['limit'], '50');
      expect(seen.toString(), isNot(contains('test-token')));
    });

    test('SSE 带 Last-Event-ID 头，而不是拼进 URL', () async {
      http.BaseRequest? request;
      final api = ApiClient(
        base: base,
        token: 'test-token',
        client: MockClient.streaming((req, _) async {
          request = req;
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode(': ping\n\n')),
            200,
            request: req,
          );
        }),
      );
      addTearDown(api.close);
      await api.sse('/api/sessions/s1/events', lastEventId: 's1:42').toList();
      expect(request!.headers['last-event-id'], 's1:42');
      expect(request!.url.toString(), isNot(contains('s1%3A42')));
      expect(request!.url.toString(), isNot(contains('test-token')));
    });

    test('错误文案不回显请求头/token', () async {
      final api = rest(
        (_) async => http.Response(
          jsonEncode({'code': 'INTERNAL', 'message': 'boom'}),
          500,
          headers: {'content-type': 'application/json'},
        ),
      );
      addTearDown(api.close);
      try {
        await api.getJson('/api/sessions');
        fail('应当抛错');
      } on ApiFailure catch (e) {
        expect(e.toString(), isNot(contains('test-token')));
      }
    });
  });
}
