import 'package:chatluna_mobile/features/chat/turn_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeTurnPhase', () {
    test('把实例的帧名归一到少数几个可读阶段', () {
      expect(normalizeTurnPhase('reasoning'), thinkingPhase);
      expect(normalizeTurnPhase('text'), replyPhase);
      expect(normalizeTurnPhase('chatluna:draw'), 'draw');
      expect(normalizeTurnPhase('tool:reply'), replyPhase);
      expect(normalizeTurnPhase('Tool/draw'), 'draw');
      expect(normalizeTurnPhase('wakeup'), 'wakeup');
      expect(normalizeTurnPhase('  '), thinkingPhase);
    });
  });

  group('TurnPhaseLog', () {
    test('并行阶段各算各的：耗时之和可以超过整轮', () {
      final log = TurnPhaseLog();
      log.enter(const Duration(seconds: 0), '思考');
      log.enter(const Duration(seconds: 1), 'draw');
      log.enter(const Duration(seconds: 2), 'reply');
      log.leave(const Duration(seconds: 6), 'draw');
      log.leave(const Duration(seconds: 7), 'reply');
      log.leave(const Duration(seconds: 8), '思考');

      final recent = log.recent;
      expect(recent.map((phase) => phase.name), ['思考', 'reply', 'draw']);
      expect(recent.first.elapsed, const Duration(seconds: 8));
      expect(recent[1].elapsed, const Duration(seconds: 5));
      expect(recent[2].elapsed, const Duration(seconds: 5));
      final sum = recent.fold(
        Duration.zero,
        (total, phase) => total + phase.elapsed,
      );
      expect(sum, greaterThan(const Duration(seconds: 8)));
    });

    test('同名阶段重试沿用原起点，按名字配对而不是新开一段', () {
      final log = TurnPhaseLog();
      log.enter(const Duration(seconds: 1), 'reply');
      log.enter(const Duration(seconds: 3), 'reply');
      expect(log.current, 'reply');
      log.leave(const Duration(seconds: 4), 'reply');
      expect(log.recent.single.elapsed, const Duration(seconds: 3));
      expect(log.isEmpty, isTrue);
    });
  });

  group('resolveTurnEnd', () {
    const grace = Duration(seconds: 3);

    test('生成没停就没有终点', () {
      expect(
        resolveTurnEnd(
          stoppedAt: null,
          deliveredAt: const Duration(seconds: 5),
          now: const Duration(seconds: 10),
          grace: grace,
        ),
        isNull,
      );
    });

    test('停表与投递都到齐时取更晚的那个', () {
      const deliveredLate = Duration(seconds: 9);
      const stoppedEarly = Duration(seconds: 7);
      expect(
        resolveTurnEnd(
          stoppedAt: stoppedEarly,
          deliveredAt: deliveredLate,
          now: const Duration(seconds: 10),
          grace: grace,
        ),
        deliveredLate,
      );
      expect(
        resolveTurnEnd(
          stoppedAt: const Duration(seconds: 9),
          deliveredAt: const Duration(seconds: 7),
          now: const Duration(seconds: 10),
          grace: grace,
        ),
        const Duration(seconds: 9),
      );
    });

    test('停了但一直没有外发：等满 grace 再按停止时刻收表', () {
      const stopped = Duration(seconds: 9);
      expect(
        resolveTurnEnd(
          stoppedAt: stopped,
          deliveredAt: null,
          now: const Duration(seconds: 11),
          grace: grace,
        ),
        isNull,
      );
      expect(
        resolveTurnEnd(
          stoppedAt: stopped,
          deliveredAt: null,
          now: const Duration(seconds: 13),
          grace: grace,
        ),
        stopped,
      );
    });
  });

  group('turnStartLead', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000000);

    test('信号早到多少就回填多少，超过 3s 一律不信任', () {
      expect(
        turnStartLead(now.subtract(const Duration(milliseconds: 500)), now),
        const Duration(milliseconds: 500),
      );
      expect(
        turnStartLead(now.subtract(const Duration(seconds: 30)), now),
        Duration.zero,
      );
      expect(
        turnStartLead(now.add(const Duration(seconds: 5)), now),
        Duration.zero,
      );
      expect(turnStartLead(null, now), Duration.zero);
    });

    test('起点取更早的那个，之后到达的较晚信号不重置表', () {
      var clock = const Duration(seconds: 3);
      final turn = TurnClock(now: () => clock);
      addTearDown(turn.dispose);

      // 首个信号自带 2s 的回填：本轮其实从 1s 开始。
      turn.start(lead: const Duration(seconds: 2));
      expect(turn.view.value?.total, const Duration(seconds: 2));

      // 后到的 snapshot 只知道「现在」，不能把起点挪后。
      clock = const Duration(seconds: 4);
      turn.start();
      expect(turn.view.value?.total, const Duration(seconds: 3));

      clock = const Duration(seconds: 6);
      turn.phase('draw');
      final view = turn.view.value!;
      expect(view.total, const Duration(seconds: 5));
      expect(view.phase, 'draw');
      expect(view.phaseElapsed, Duration.zero);
    });
  });

  group('TurnClock', () {
    test('跨后台不停表：没有 tick 也按真实墙钟累计', () {
      var clock = const Duration(seconds: 5);
      final turn = TurnClock(now: () => clock);
      addTearDown(turn.dispose);

      turn.start();
      clock = const Duration(seconds: 9);
      turn.suspend(); // 切后台：只停 tick
      clock = const Duration(seconds: 35);
      turn.resume();

      expect(turn.view.value?.total, const Duration(seconds: 30));
    });

    test('外发落库 + running=false 才收表，取更晚者', () {
      var clock = Duration.zero;
      final turn = TurnClock(now: () => clock);
      addTearDown(turn.dispose);

      turn.start();
      clock = const Duration(seconds: 5);
      turn.phase('reply');
      clock = const Duration(seconds: 6);
      turn.delivered();
      // 只有投递：还没有终点，表继续走。
      expect(turn.running, isTrue);
      expect(turn.view.value?.total, const Duration(seconds: 6));

      clock = const Duration(seconds: 8);
      turn.stopped();
      expect(turn.running, isFalse);
      expect(turn.view.value?.total, const Duration(seconds: 8));
      expect(turn.view.value?.previous, isFalse);
    });

    test('真实一轮的事件序列（2026-11-19 实例 /steer 实测）算出 27.2s', () {
      var clock = Duration.zero;
      final turn = TurnClock(now: () => clock);
      addTearDown(turn.dispose);

      // 1.1s input-enqueued；5.3s 首条 reasoning；5.4s tool-input tool_search …
      clock = const Duration(milliseconds: 1100);
      turn.start();

      void reasoningAt(int ms) {
        clock = Duration(milliseconds: ms);
        turn.phase('思考');
      }

      void toolAt(int ms, String name) {
        clock = Duration(milliseconds: ms);
        turn.endPhase('思考');
        turn.phase(name);
      }

      void toolResultAt(int ms) {
        clock = Duration(milliseconds: ms);
        final closed = turn.phaseFinished();
        if (closed != null && closed != replyPhase) turn.phase('思考');
      }

      reasoningAt(5300);
      toolAt(5400, 'tool_search');
      toolResultAt(6800);
      toolAt(9200, 'tool_search');
      toolResultAt(9400);
      toolAt(17300, 'tool_search');
      toolResultAt(17400);
      toolAt(22100, 'tool_search');
      toolResultAt(22200);
      toolAt(24800, 'reply');

      clock = const Duration(milliseconds: 25100);
      turn.delivered();
      clock = const Duration(milliseconds: 25500);
      turn.delivered();
      clock = const Duration(milliseconds: 28300);
      turn.phaseFinished();
      turn.stopped();

      final view = turn.view.value!;
      expect(view.total, const Duration(milliseconds: 27200));
      expect(view.phase, isNull);
      expect(
        view.recent.map(
          (phase) => '${phase.name} ${phase.elapsed.inMilliseconds}',
        ),
        ['reply 3500', '思考 2600', 'tool_search 100'],
      );
    });
  });

  group('formatElapsed', () {
    test('不足一分钟保留一位小数', () {
      expect(formatElapsed(Duration.zero), '0.0s');
      expect(formatElapsed(const Duration(milliseconds: 3200)), '3.2s');
      expect(formatElapsed(const Duration(milliseconds: 999)), '1.0s');
      expect(formatElapsed(const Duration(milliseconds: 59999)), '60.0s');
    });

    test('超过一分钟换成 分+两位秒，超过一小时换成 时+两位分', () {
      expect(formatElapsed(const Duration(minutes: 1)), '1m00s');
      expect(formatElapsed(const Duration(seconds: 64)), '1m04s');
      expect(formatElapsed(const Duration(minutes: 59, seconds: 59)), '59m59s');
      expect(formatElapsed(const Duration(minutes: 64)), '1h04m');
      expect(formatElapsed(const Duration(seconds: -3)), '0.0s');
    });
  });

  group('turnLineLabel', () {
    test('整轮总时长在前，当前阶段与阶段用时在后', () {
      expect(
        turnLineLabel(
          const TurnClockView(
            total: Duration(seconds: 64),
            phase: 'draw',
            phaseElapsed: Duration(milliseconds: 12300),
          ),
        ),
        '1m04s · draw 12.3s',
      );
      expect(
        turnLineLabel(
          const TurnClockView(
            total: Duration(milliseconds: 3200),
            phase: '思考',
            phaseElapsed: Duration(milliseconds: 3200),
          ),
        ),
        '3.2s · 思考 3.2s',
      );
    });

    test('阶段间隙只显示总时长；中止显示「已中止」', () {
      expect(
        turnLineLabel(const TurnClockView(total: Duration(seconds: 12))),
        '12.0s',
      );
      expect(
        turnLineLabel(
          const TurnClockView(total: Duration(seconds: 12)),
          aborted: true,
        ),
        '已中止 12.0s',
      );
    });
  });

  group('phaseHistogram', () {
    test('每段占比 = 阶段耗时 / 整轮（并行时之和可以超过 1）', () {
      final shares = phaseHistogram(const [
        TurnPhaseRecord('draw', Duration(seconds: 5)),
        TurnPhaseRecord('reply', Duration(seconds: 3)),
      ], const Duration(seconds: 10));
      expect(shares.map((share) => share.share), [0.5, 0.3]);
      expect(shares.first.name, 'draw');
    });

    test('总时长为 0 时占比归零，不除零', () {
      final shares = phaseHistogram(const [
        TurnPhaseRecord('思考', Duration(seconds: 3)),
      ], Duration.zero);
      expect(shares.single.share, 0);
    });
  });

  group('aggregatePhases', () {
    test('同名阶段聚合成一行：draw ×2 51.4s', () {
      final groups = aggregatePhases(const [
        TurnPhaseRecord('draw', Duration(milliseconds: 12000)),
        TurnPhaseRecord('reply', Duration(seconds: 2)),
        TurnPhaseRecord('draw', Duration(milliseconds: 39400)),
      ]);
      expect(groups.map(phaseGroupLabel), ['draw ×2 51.4s', 'reply 2.0s']);
      expect(groups.first.spans.map((span) => span.inMilliseconds), [
        12000,
        39400,
      ]);
      expect(groups.first.count, 2);
    });
  });

  group('中止与迟到信号', () {
    test('freeze 立即定格：之后的 settled/delivered 不再让读数增长', () {
      var clock = const Duration(seconds: 1);
      final turn = TurnClock(now: () => clock);
      addTearDown(turn.dispose);

      turn.start();
      clock = const Duration(seconds: 5);
      turn.phase('draw');
      turn.freeze();
      expect(turn.view.value!.finished, isTrue);
      expect(turn.view.value!.total, const Duration(seconds: 4));

      clock = const Duration(seconds: 9);
      turn.stopped();
      turn.delivered();
      turn.phase('reply');
      expect(turn.view.value!.total, const Duration(seconds: 4));
      expect(turn.view.value!.active, isEmpty);
    });

    test('刚收表 1s 内迟到的 mark 不重开一轮（避免 0.0s）', () {
      var clock = const Duration(seconds: 1);
      final turn = TurnClock(now: () => clock);
      addTearDown(turn.dispose);

      turn.start();
      clock = const Duration(seconds: 6);
      turn.stopped();
      turn.delivered();
      expect(turn.view.value!.finished, isTrue);

      clock = const Duration(seconds: 6, milliseconds: 400);
      turn.start();
      expect(turn.view.value!.finished, isTrue);
      expect(turn.view.value!.total, const Duration(seconds: 5));

      // 真下一轮（超过 1s）照常开表。
      clock = const Duration(seconds: 9);
      turn.start();
      expect(turn.view.value!.finished, isFalse);
      expect(turn.view.value!.total, Duration.zero);
    });

    test('折叠态并列显示两个并行阶段，超过两条收成 +N', () {
      const two = TurnClockView(
        total: Duration(seconds: 24),
        active: [
          TurnPhaseRecord('draw', Duration(milliseconds: 12300)),
          TurnPhaseRecord('reply', Duration(milliseconds: 1600)),
        ],
      );
      expect(turnLineLabel(two), '24.0s · draw 12.3s · reply 1.6s');

      const three = TurnClockView(
        total: Duration(seconds: 24),
        active: [
          TurnPhaseRecord('draw', Duration(seconds: 12)),
          TurnPhaseRecord('reply', Duration(seconds: 1)),
          TurnPhaseRecord('思考', Duration(seconds: 3)),
        ],
      );
      expect(turnLineLabel(three), '24.0s · draw 12.0s · reply 1.0s +1');
    });

    test('轮次序号只在真正新开一轮时递增', () {
      var clock = const Duration(seconds: 1);
      final turn = TurnClock(now: () => clock);
      addTearDown(turn.dispose);

      turn.start(lead: const Duration(seconds: 3)); // 回填 3s：首帧读数已经 >400ms
      final first = turn.view.value!.round;
      expect(turn.view.value!.total, const Duration(seconds: 3));

      turn.phase('draw'); // 同一轮里的后续信号
      expect(turn.view.value!.round, first);

      clock = const Duration(seconds: 8);
      turn.stopped();
      turn.delivered();
      expect(turn.view.value!.finished, isTrue);

      clock = const Duration(seconds: 12);
      turn.start();
      expect(turn.view.value!.round, first + 1);
    });

    test('finishTool 按名字关表，不误关之后重新开的「思考」', () {
      var clock = Duration.zero;
      final turn = TurnClock(now: () => clock);
      addTearDown(turn.dispose);

      turn.start();
      clock = const Duration(seconds: 2);
      turn.phase('draw');
      clock = const Duration(seconds: 3);
      turn.phase(thinkingPhase); // prompt 在 tool-input 之后到达，思考重新成为当前
      clock = const Duration(seconds: 12);
      final closed = turn.finishTool('draw');

      expect(closed, 'draw');
      expect(turn.view.value!.active.map((p) => p.name), [thinkingPhase]);
      expect(turn.view.value!.recent.single.elapsed, const Duration(seconds: 10));
    });

    test('标签里工具优先于「思考」', () {
      const view = TurnClockView(
        total: Duration(seconds: 24),
        active: [
          TurnPhaseRecord('思考', Duration(seconds: 3)),
          TurnPhaseRecord('draw', Duration(seconds: 12)),
        ],
      );
      expect(turnLineLabel(view), '24.0s · draw 12.0s · 思考 3.0s');
    });

    test('阶段间隙保留刚结束的工具耗时', () {
      const view = TurnClockView(
        total: Duration(milliseconds: 16400),
        recent: [TurnPhaseRecord('draw', Duration(seconds: 2))],
      );
      expect(turnLineLabel(view), '16.4s · draw 2.0s');
    });

    test('只开着思考时补上刚结束的工具耗时', () {
      const view = TurnClockView(
        total: Duration(milliseconds: 26400),
        active: [TurnPhaseRecord('思考', Duration(seconds: 24))],
        recent: [TurnPhaseRecord('draw', Duration(seconds: 2))],
      );
      expect(turnLineLabel(view), '26.4s · 思考 24.0s · draw 2.0s');
    });
  });
}
