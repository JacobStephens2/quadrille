import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/timer/data/timer_repository.dart';

void main() {
  late QuadrilleDatabase db;
  late TimerRepository repo;

  setUp(() {
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    repo = TimerRepository(db);
  });
  tearDown(() => db.close());

  test('start writes a wall-clock deadline ~duration ahead', () async {
    final before = DateTime.now();
    final endsAt = await repo.start(
      duration: const Duration(seconds: 120),
      label: 'Bench Press',
    );
    expect(endsAt.isAfter(before.add(const Duration(seconds: 118))), isTrue);

    final row = await repo.read();
    expect(row, isNotNull);
    expect(row!.status, TimerStatus.running);
    expect(row.label, 'Bench Press');
    expect(row.durationSeconds, 120);
  });

  test('start replaces any existing timer (singleton)', () async {
    await repo.start(duration: const Duration(seconds: 60), label: 'A');
    await repo.start(duration: const Duration(seconds: 90), label: 'B');
    final rows = await db.select(db.activeTimers).get();
    expect(rows, hasLength(1));
    expect(rows.single.label, 'B');
  });

  test('adjust extends the deadline', () async {
    final first = await repo.start(duration: const Duration(seconds: 60));
    final extended = await repo.adjust(const Duration(seconds: 30));
    expect(extended, isNotNull);
    expect(extended!.isAfter(first), isTrue);
  });

  test('adjust never lands the deadline in the past', () async {
    await repo.start(duration: const Duration(seconds: 60));
    final shortened = await repo.adjust(const Duration(seconds: -9999));
    expect(shortened, isNotNull);
    expect(shortened!.isBefore(DateTime.now().add(const Duration(seconds: 1))), isTrue);
    expect(shortened.isAfter(DateTime.now().subtract(const Duration(seconds: 2))), isTrue);
  });

  test('adjust on no timer returns null', () async {
    expect(await repo.adjust(const Duration(seconds: 30)), isNull);
  });

  test('clear removes the timer', () async {
    await repo.start(duration: const Duration(seconds: 60));
    await repo.clear();
    expect(await repo.read(), isNull);
  });
}
