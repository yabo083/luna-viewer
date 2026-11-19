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
}
