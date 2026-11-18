import 'package:flutter_test/flutter_test.dart';

import 'package:chatluna_mobile/core/model/models.dart';
import 'package:chatluna_mobile/core/update/update_checker.dart';
import 'package:chatluna_mobile/core/store/connection_store.dart';

void main() {
  group('normalizeBase', () {
    test('补默认 scheme 与端口', () {
      final lan = normalizeBase('192.168.0.107:5028')!;
      expect((lan.scheme, lan.host, lan.port), ('http', '192.168.0.107', 5028));

      final pub = normalizeBase('bot.example.com')!;
      expect((pub.scheme, pub.host, pub.port), ('https', 'bot.example.com', 443));

      final explicit = normalizeBase('https://bot.example.com:8443')!;
      expect((explicit.scheme, explicit.host, explicit.port), ('https', 'bot.example.com', 8443));
    });

    test('拒绝空值与无主机输入', () {
      expect(normalizeBase('   '), isNull);
      expect(normalizeBase('http://'), isNull);
    });

    test('拒绝全角标点（adb/输入法误输入的常见形态）', () {
      expect(normalizeBase('192。168。0。107：5028'), isNull);
      expect(normalizeBase('192%2E168%2E0%2E1:5028'), isNull);
    });
  });

  group('ChatMessage.bodyMarkdown', () {
    test('露出 <message> 正文并丢弃 status 标记', () {
      final message = ChatMessage.fromJson({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': '<message>大家早安。</message>\n\n<status mood="清朗"/>'},
        ],
      });
      expect(message.bodyMarkdown, '大家早安。');
    });

    test('无标记时原样返回', () {
      final message = ChatMessage.fromJson({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '你好'},
        ],
      });
      expect(message.bodyMarkdown, '你好');
    });

    test('<img> 转成 markdown 图片', () {
      final message = ChatMessage.fromJson({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': '<message>给你看<img src="medialuna/a.png">这张</message>'},
        ],
      });
      expect(message.bodyMarkdown, contains('![](medialuna/a.png)'));
      expect(message.bodyMarkdown, isNot(contains('<img')));
    });

    test('envelope 里的嵌套文本会被取出', () {
      final message = ChatMessage.fromJson({
        'role': 'user',
        'content': [
          {
            'type': 'envelope',
            'kind': 'message',
            'content': [
              {'type': 'text', 'text': '鸭子眺望远方'},
            ],
          },
        ],
      });
      expect(message.bodyMarkdown, '鸭子眺望远方');
    });

    test('reply 工具的 content 作为正文', () {
      final message = ChatMessage.fromJson({
        'role': 'assistant',
        'content': [
          {
            'type': 'tool-call',
            'toolName': 'reply',
            'input': {'content': '<message>你好<img src="a.png"></message>'},
          },
        ],
      });
      expect(message.bodyMarkdown, contains('你好'));
      expect(message.bodyMarkdown, contains('![](a.png)'));
      expect(message.toolCallCount, 0);
    });

    test('工具结果按 toolCallId 关联', () {
      final message = ChatMessage.fromJson({
        'role': 'assistant',
        'content': [
          {
            'type': 'tool-call',
            'toolCallId': 'c1',
            'toolName': 'bash',
            'input': {'command': 'ls'},
          },
          {
            'type': 'tool-result',
            'toolCallId': 'c1',
            'output': {
              'type': 'content',
              'value': [
                {'type': 'text', 'text': 'a.txt'},
              ],
            },
          },
        ],
      });
      expect(message.toolCalls.single.name, 'bash');
      expect(message.toolCalls.single.output, 'a.txt');
      expect(message.toolCalls.single.prettyInput, contains('ls'));
    });

    test('reasoning 与工具调用分别统计', () {
      final message = ChatMessage.fromJson({
        'role': 'assistant',
        'content': [
          {'type': 'reasoning', 'text': '先想想'},
          {'type': 'tool-call', 'toolName': 'bash'},
          {'type': 'tool-result', 'toolName': 'bash'},
          {'type': 'tool-call', 'toolName': 'reply'},
        ],
      });
      expect(message.reasoningText, '先想想');
      expect(message.toolCallCount, 1, reason: 'reply 是发言工具，不计入工具条');
      expect(message.bodyMarkdown, '');
    });
  });

  group('LiveEvent.fromSse', () {
    test('text part 产出 delta', () {
      final event = LiveEvent.fromSse('agent/assistant-stream', {
        'part': {'type': 'text', 'index': 0, 'delta': '你'},
      });
      expect(event?.kind, LiveEventKind.delta);
      expect(event?.delta, '你');
    });

    test('settled 带 reason', () {
      final event = LiveEvent.fromSse('agent/assistant-settled', {
        'outcome': {'reason': 'completed'},
      });
      expect(event?.kind, LiveEventKind.settled);
      expect(event?.reason, 'completed');
    });

    test('snapshot 收集已累积的文本 part', () {
      final event = LiveEvent.fromSse('snapshot', {
        'attempt': {
          'parts': [
            {'type': 'text', 'index': 0, 'delta': '半'},
            {'type': 'text', 'index': 0, 'delta': '句'},
          ],
        },
      });
      expect(event?.kind, LiveEventKind.snapshot);
      expect(event?.parts.length, 2);
    });

    test('未知事件忽略', () {
      expect(LiveEvent.fromSse('pong', null), isNull);
    });
  });

  group('UpdateChecker.isNewer', () {
    test('比较数字段并忽略 v 前缀与预发布后缀', () {
      expect(UpdateChecker.isNewer('v0.2.0', '0.1.0'), isTrue);
      expect(UpdateChecker.isNewer('0.1.1', '0.1.0'), isTrue);
      expect(UpdateChecker.isNewer('0.1.0', '0.1.0'), isFalse);
      expect(UpdateChecker.isNewer('0.1.0-rc.1', '0.1.0'), isFalse);
      expect(UpdateChecker.isNewer('0.10.0', '0.9.9'), isTrue);
    });
  });

  group('SessionSummary', () {
    test('satori 会话不可写', () {
      final session = SessionSummary.fromJson({
        'id': 'route:r-1',
        'title': 'qq',
        'createdAt': 0,
        'origin': 'satori',
        'running': false,
        'engine': 'character',
      });
      expect(session.writable, isFalse);
    });
  });
}
