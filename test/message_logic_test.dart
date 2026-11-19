import 'package:chatluna_mobile/features/chat/message_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isPlaceholderOnly', () {
    test('单个中文占位文案', () {
      expect(isPlaceholderOnly('[图片]'), isTrue);
      expect(isPlaceholderOnly('[图片] '), isTrue);
      expect(isPlaceholderOnly('  [截图]\n'), isTrue);
      expect(isPlaceholderOnly('[ 视频消息 ]'), isTrue);
    });

    test('多个占位文案与包裹标点', () {
      expect(isPlaceholderOnly('[图片][视频]'), isTrue);
      expect(isPlaceholderOnly('（[图片]）'), isTrue);
      expect(isPlaceholderOnly('[图片] · [文件]'), isTrue);
    });

    test('英文占位与内联标签不算占位：宁可多显示，也不吞掉正文', () {
      expect(isPlaceholderOnly('[image]'), isFalse);
      expect(isPlaceholderOnly('<img src="a.png">'), isFalse);
    });

    test('纯空白不算占位', () {
      expect(isPlaceholderOnly(''), isFalse);
      expect(isPlaceholderOnly('   '), isFalse);
      expect(isPlaceholderOnly('\n\t '), isFalse);
    });

    test('正常文本不算占位', () {
      expect(isPlaceholderOnly('这是一段正常的回复'), isFalse);
      expect(isPlaceholderOnly('[图片] 看这张'), isFalse);
      expect(isPlaceholderOnly('[文件] —— 见附件'), isFalse);
    });
  });

  group('MemoCache', () {
    test('同一个键只计算一次；命中后仍然返回同一个结果', () {
      final cache = MemoCache<List<int>>(capacity: 4);
      var calls = 0;
      List<int> compute() {
        calls += 1;
        return [calls];
      }

      expect(cache.value('a', compute), [1]);
      expect(cache.value('a', compute), [1]);
      expect(calls, 1);
      expect(cache.length, 1);
    });

    test('可缓存 null（解析失败的结果也要记住）', () {
      final cache = MemoCache<String?>(capacity: 4);
      var calls = 0;
      String? compute() {
        calls += 1;
        return null;
      }

      expect(cache.value('x', compute), isNull);
      expect(cache.value('x', compute), isNull);
      expect(calls, 1);
    });

    test('超过容量淘汰最久未用的一项', () {
      final cache = MemoCache<int>(capacity: 2);
      cache.value('a', () => 1);
      cache.value('b', () => 2);
      // 命中 a：b 变成最久未用。
      cache.value('a', () => 1);
      cache.value('c', () => 3);
      expect(cache.length, 2);
      expect(cache.value('a', () => 10), 1);
      expect(cache.value('b', () => 20), 20);
    });

    test('clear 之后重新计算', () {
      final cache = MemoCache<int>(capacity: 2);
      var calls = 0;
      int compute() => ++calls;
      cache.value('a', compute);
      cache.clear();
      expect(cache.value('a', compute), 2);
    });
  });
}
