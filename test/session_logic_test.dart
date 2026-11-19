import 'package:chatluna_mobile/core/model/models.dart';
import 'package:chatluna_mobile/features/sessions/session_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 固定基准：边界断言不依赖设备时钟。
  final now = DateTime(2026, 11, 19, 12);

  SessionRow row(
    String key, {
    Duration age = Duration.zero,
    bool running = false,
  }) => SessionRow(
    key: key,
    title: key,
    subtitle: null,
    count: 0,
    time: now.subtract(age),
    session: running
        ? SessionSummary(
            id: key,
            title: key,
            createdAt: now.subtract(age),
            origin: 'web',
            running: true,
            engine: 'chatluna',
          )
        : null,
  );

  List<String> keys(List<SessionRow> rows) => [for (final row in rows) row.key];

  group('partitionSessions', () {
    test('活跃窗口是 3 天', () {
      expect(activeWindow, const Duration(days: 3));
    });

    test('71h59m 仍留在活跃列表', () {
      final (active, archived) = partitionSessions(
        [row('a', age: const Duration(hours: 71, minutes: 59))],
        now: now,
      );
      expect(keys(active), ['a']);
      expect(archived, isEmpty);
    });

    test('恰好 72h 算活跃（边界含等号）', () {
      final (active, archived) = partitionSessions(
        [row('a', age: const Duration(hours: 72))],
        now: now,
      );
      expect(keys(active), ['a']);
      expect(archived, isEmpty);
    });

    test('72h01m 收进归档', () {
      final (active, archived) = partitionSessions(
        [row('a', age: const Duration(hours: 72, minutes: 1))],
        now: now,
      );
      expect(active, isEmpty);
      expect(keys(archived), ['a']);
    });

    test('运行中的会话无论多久以前都算活跃', () {
      final (active, archived) = partitionSessions(
        [
          row('running', age: const Duration(hours: 200), running: true),
          row('old', age: const Duration(hours: 200)),
        ],
        now: now,
      );
      expect(keys(active), ['running']);
      expect(keys(archived), ['old']);
    });

    test('两段都保持输入顺序', () {
      final (active, archived) = partitionSessions(
        [
          row('a', age: const Duration(hours: 1)),
          row('b', age: const Duration(hours: 100)),
          row('c', age: const Duration(hours: 2)),
          row('d', age: const Duration(hours: 200)),
        ],
        now: now,
      );
      expect(keys(active), ['a', 'c']);
      expect(keys(archived), ['b', 'd']);
    });

    test('窗口可由调用方覆盖', () {
      final rows = [
        row('fresh', age: const Duration(minutes: 30)),
        row('stale', age: const Duration(hours: 2)),
      ];
      final (active, archived) = partitionSessions(
        rows,
        now: now,
        window: const Duration(hours: 1),
      );
      expect(keys(active), ['fresh']);
      expect(keys(archived), ['stale']);
    });
  });
}
