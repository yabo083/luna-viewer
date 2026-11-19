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

  testWidgets('读数变长变短都不改标签尺寸：盒子宽度恒定，文字缩在里面', (tester) async {
    final clock = ValueNotifier<TurnClockView?>(
      const TurnClockView(
        total: Duration(milliseconds: 9900),
        phase: '思考',
        phaseElapsed: Duration(milliseconds: 9900),
      ),
    );
    addTearDown(clock.dispose);
    await tester.pumpWidget(
      _host(TurnClockLabel(clock: clock, onTap: () {})),
    );
    final narrow = tester.getSize(find.byType(TurnClockLabel));

    // `9.9s` → `1m04s`、单阶段 → 多阶段：文字从 14 字长到 20 字。
    clock.value = const TurnClockView(
      total: Duration(seconds: 64),
      phase: 'draw',
      active: [
        TurnPhaseRecord('draw', Duration(milliseconds: 21600)),
        TurnPhaseRecord('reply', Duration(milliseconds: 12300)),
      ],
    );
    await tester.pump();

    expect(narrow.width, TurnClockLabel.boxWidth);
    expect(tester.getSize(find.byType(TurnClockLabel)), narrow);
    // 长读数没有被裁掉，还在盒子里等比缩小显示。
    expect(find.textContaining('1m04s · draw 21.6s'), findsOneWidget);
    final label = tester.widget<Text>(find.textContaining('1m04s'));
    expect(label.maxLines, 1);
    expect(label.softWrap, isFalse);
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
