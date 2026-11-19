import 'package:chatluna_mobile/features/chat/chat_chrome.dart';
import 'package:chatluna_mobile/features/chat/turn_clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('骑缝计时标签可点击，命中区高于视觉高度', (tester) async {
    final clock = ValueNotifier<TurnClockView?>(
      const TurnClockView(total: Duration(milliseconds: 12400), phase: 'draw',
          phaseElapsed: Duration(milliseconds: 2100)),
    );
    addTearDown(clock.dispose);
    var taps = 0;
    await tester.pumpWidget(_host(TurnClockLabel(clock: clock, onTap: () => taps++)));
    expect(find.textContaining('12.4s · draw 2.1s'), findsOneWidget);
    await tester.tap(find.byType(TurnClockLabel));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('没有读数时标签为空，也不拦点击', (tester) async {
    final clock = ValueNotifier<TurnClockView?>(null);
    addTearDown(clock.dispose);
    var taps = 0;
    await tester.pumpWidget(_host(TurnClockLabel(clock: clock, onTap: () => taps++)));
    expect(find.byType(TurnClockLabel), findsOneWidget);
    await tester.pump();
    expect(taps, 0);
  });
}
