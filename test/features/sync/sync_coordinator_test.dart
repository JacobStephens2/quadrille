import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/backup/data/backup_service.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';
import 'package:quadrille/features/settings/data/settings_repository.dart';
import 'package:quadrille/features/sync/data/sync_service.dart';
import 'package:quadrille/features/sync/sync_coordinator.dart';
import 'package:quadrille/features/sync/sync_providers.dart';

void main() {
  late QuadrilleDatabase db;
  late SettingsRepository settings;

  /// Builds a container whose sync service returns [remoteResponse] for GETs.
  (ProviderContainer, SyncCoordinator) harness(String remoteResponse) {
    final client = MockClient((req) async => http.Response(remoteResponse, 200));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncServiceProvider
            .overrideWithValue(SyncService(BackupService(db), client: client)),
      ],
    );
    addTearDown(container.dispose);
    return (container, container.read(syncCoordinatorProvider));
  }

  Future<String> cloudPayloadWith(String exerciseName) async {
    final source = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    await ExerciseRepository(source).create(name: exerciseName);
    final payload =
        jsonDecode(await BackupService(source).exportJson(now: DateTime(2026)));
    await source.close();
    return jsonEncode({'exists': true, 'revision': 5, 'payload': payload});
  }

  setUp(() {
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsRepository(db);
  });
  tearDown(() => db.close());

  test('does nothing when auto-sync is off', () async {
    final (_, coord) = harness('{"exists":false,"revision":0,"payload":null}');
    expect(await coord.pullOnLaunch(), PullOutcome.notConfigured);
  });

  test('auto-pulls newer cloud data when there are no local changes', () async {
    await settings.update(
      autoSync: true,
      syncToken: const Value('tok'),
      lastSyncedRevision: 0,
      lastSyncAt: Value(DateTime(2026, 6, 1, 12)),
    );
    final (_, coord) = harness(await cloudPayloadWith('Cloud Squat'));

    expect(await coord.pullOnLaunch(), PullOutcome.pulled);
    final names =
        (await ExerciseRepository(db).watchAll().first).map((e) => e.name);
    expect(names, ['Cloud Squat']);

    // The pull must NOT wipe this device's sync credentials.
    final after = await settings.read();
    expect(after.syncToken, 'tok');
    expect(after.autoSync, isTrue);
    expect(after.lastSyncedRevision, 5);
  });

  test('skips an auto-pull when the device has unsynced local changes', () async {
    // lastSyncAt far in the past; create a local exercise => local is dirty.
    await settings.update(
      autoSync: true,
      syncToken: const Value('tok'),
      lastSyncedRevision: 0,
      lastSyncAt: Value(DateTime(2020)),
    );
    await ExerciseRepository(db).create(name: 'My Local Lift');

    final (_, coord) = harness(await cloudPayloadWith('Cloud Squat'));
    expect(await coord.pullOnLaunch(), PullOutcome.skippedLocalChanges);
    // Local data is untouched.
    final names =
        (await ExerciseRepository(db).watchAll().first).map((e) => e.name);
    expect(names, ['My Local Lift']);
  });
}
