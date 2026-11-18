import 'package:flutter_test/flutter_test.dart';

import 'package:chatluna_mobile/core/model/models.dart';
import 'package:chatluna_mobile/core/store/connection_store.dart';

void main() {
  group('normalizeBase', () {
    test('补默认 scheme 与端口', () {
      expect(normalizeBase('192.168.0.107:5028')?.toString(), 'http://192.168.0.107:5028');
      expect(normalizeBase('bot.example.com')?.toString(), 'https://bot.example.com:443');
      expect(normalizeBase('https://bot.example.com:8443')?.toString(), 'https://bot.example.com:8443');
    });

    test('拒绝空值与无主机输入', () {
      expect(normalizeBase('   '), isNull);
      expect(normalizeBase('http://'), isNull);
    });
  });

  group('ChatMessage.displayText', () {
    test('露出 <message> 正文并丢弃 status 标记', () {
      final message = ChatMessage.fromJson({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': '<message>大家早安。</message>\n\n<status mood="清朗"/>'},
        ],
      });
      expect(message.displayText, '大家早安。');
    });

    test('无标记时原样返回', () {
      final message = ChatMessage.fromJson({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '你好'},
        ],
      });
      expect(message.displayText, '你好');
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
