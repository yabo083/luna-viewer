import 'package:flutter_test/flutter_test.dart';

import 'package:chatluna_mobile/features/chat/chat_chrome.dart';

void main() {
  group('formatElapsed', () {
    test('不足一分钟保留一位小数', () {
      expect(formatElapsed(Duration.zero), '0.0s');
      expect(formatElapsed(const Duration(milliseconds: 3200)), '3.2s');
      expect(formatElapsed(const Duration(milliseconds: 999)), '1.0s');
      expect(formatElapsed(const Duration(milliseconds: 59999)), '60.0s');
    });

    test('超过一分钟换成 分+两位秒', () {
      expect(formatElapsed(const Duration(minutes: 1)), '1m00s');
      expect(formatElapsed(const Duration(seconds: 64)), '1m04s');
      expect(formatElapsed(const Duration(minutes: 59, seconds: 59)), '59m59s');
    });

    test('超过一小时换成 时+两位分', () {
      expect(formatElapsed(const Duration(hours: 1)), '1h00m');
      expect(formatElapsed(const Duration(minutes: 64)), '1h04m');
    });

    test('负数按 0 处理：时钟回拨不该显示负耗时', () {
      expect(formatElapsed(const Duration(seconds: -3)), '0.0s');
    });
  });
}
