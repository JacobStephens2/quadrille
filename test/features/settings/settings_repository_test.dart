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

  test(
    'voice cues are enabled by default and can be disabled persistently',
    () async {
      expect((await repo.read()).voiceCuesEnabled, isTrue);
      await repo.update(voiceCuesEnabled: false);
      final reopened = SettingsRepository(db);
      expect((await reopened.watch().first).voiceCuesEnabled, isFalse);
      expect((await reopened.read()).autoStartTimer, isTrue);
    },
  );

  test('v7 settings upgrade preserves preferences and enables voice cues', () async {
    await db.close();
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory(setup: (sqlite) {
      // Frozen v7 settings schema, independent of current Drift output.
      sqlite.execute('''
        CREATE TABLE app_settings (
          id TEXT NOT NULL PRIMARY KEY DEFAULT 'singleton',
          units TEXT NOT NULL DEFAULT 'lb',
          default_rest_seconds INTEGER NOT NULL DEFAULT 120,
          auto_start_timer INTEGER NOT NULL DEFAULT 1,
          keep_screen_awake INTEGER NOT NULL DEFAULT 1,
          watch_haptics_enabled INTEGER NOT NULL DEFAULT 1,
          sync_endpoint TEXT NOT NULL DEFAULT 'https://quadrille.app/api',
          sync_token TEXT,
          auto_sync INTEGER NOT NULL DEFAULT 0,
          last_sync_at INTEGER,
          last_synced_revision INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO app_settings (units, default_rest_seconds, auto_start_timer)
          VALUES ('kg', 45, 0);
        PRAGMA user_version = 7;
      ''');
    }));
    repo = SettingsRepository(db);
    final s = await repo.read();
    expect(s.units, WeightUnit.kg);
    expect(s.defaultRestSeconds, 45);
    expect(s.autoStartTimer, isFalse);
    expect(s.voiceCuesEnabled, isTrue);
    await repo.update(voiceCuesEnabled: false);
    expect((await repo.read()).voiceCuesEnabled, isFalse);
  });
}
