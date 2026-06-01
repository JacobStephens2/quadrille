import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/settings/data/settings_repository.dart';

void main() {
  late QuadrilleDatabase db;
  late SettingsRepository repo;

  setUp(() {
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    repo = SettingsRepository(db);
  });
  tearDown(() => db.close());

  test('exposes the seeded defaults', () async {
    final s = await repo.watch().first;
    expect(s.units, WeightUnit.lb);
    expect(s.autoStartTimer, isTrue);
    expect(s.keepScreenAwake, isTrue);
  });

  test('updates only the given fields', () async {
    await repo.update(units: WeightUnit.kg, autoStartTimer: false);
    final s = await repo.watch().first;
    expect(s.units, WeightUnit.kg);
    expect(s.autoStartTimer, isFalse);
    // Untouched field keeps its default.
    expect(s.keepScreenAwake, isTrue);
  });

  test('persists a new default rest', () async {
    await repo.update(defaultRestSeconds: 90);
    expect((await repo.watch().first).defaultRestSeconds, 90);
  });
}
