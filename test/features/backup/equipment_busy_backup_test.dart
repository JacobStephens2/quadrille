import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/features/backup/data/backup_service.dart';
import 'package:quadrille/features/equipment/data/equipment_busy_repository.dart';
import 'package:quadrille/features/equipment/domain/equipment_busy_history.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  late QuadrilleDatabase source;
  late QuadrilleDatabase target;
  final at = DateTime.utc(2026, 11, 2, 17, 30);

  setUp(() {
    source = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    target = QuadrilleDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await source.close();
    await target.close();
  });

  test('full backup restores equipment busy reports', () async {
    final id = await EquipmentBusyRepository(
      source,
    ).recordBusy('Bench', at: at);
    final json = await BackupService(source).exportJson(now: at);

    await BackupService(target).importJson(json);
    final restored = await EquipmentBusyRepository(
      target,
    ).watchHistory('Bench').first;
    expect(restored.reports.single.id, id);
    expect(restored.reports.single.reportedAt.toUtc(), at);
    expect(restored.times.single.weekday, DateTime.monday);
    expect(restored.times.single.hour, 17);
  });

  test(
    'sync merges reports and propagates undo without losing local reports',
    () async {
      final sourceReports = EquipmentBusyRepository(source);
      final targetReports = EquipmentBusyRepository(target);
      final id = await sourceReports.recordBusy('Bench', at: at);
      await targetReports.recordBusy(
        'Bench',
        at: at.add(const Duration(hours: 1)),
      );
      final snapshot = await BackupService(source).exportSyncPayload();

      await BackupService(target).mergeIntoLocal(snapshot);
      await BackupService(target).mergeIntoLocal(snapshot);
      var history = await targetReports.watchHistory('Bench').first;
      expect(history.reports, hasLength(2));
      expect(history.reports.map((r) => r.id), contains(id));

      await sourceReports.undo(id);
      await BackupService(
        target,
      ).mergeIntoLocal(await BackupService(source).exportSyncPayload());
      history = await targetReports.watchHistory('Bench').first;
      expect(history.reports, hasLength(1));
      expect(history.times.single.hour, 18);
    },
  );

  test('wiping guest data clears equipment busy reports', () async {
    final reports = EquipmentBusyRepository(source);
    await reports.recordBusy('Bench', at: at);

    await BackupService(source).wipeAllData();

    expect((await reports.watchHistory('Bench').first).reports, isEmpty);
  });

  test(
    'an older sync snapshot cannot resurrect an undone busy report',
    () async {
      final reports = EquipmentBusyRepository(source);
      final id = await reports.recordBusy('Bench', at: at);
      final snapshot = await BackupService(source).exportSyncPayload();
      await reports.undo(id);

      await BackupService(source).mergeIntoLocal(snapshot);

      expect((await reports.watchHistory('Bench').first).reports, isEmpty);
    },
  );

  test(
    'sync keeps the original gym weekday and hour across time zones',
    () async {
      await EquipmentBusyRepository(
        source,
      ).recordBusy('Bench', at: DateTime.utc(2026, 11, 3, 1, 15));
      final payload = await BackupService(source).exportSyncPayload();
      // A device at UTC-5 observed this at 8:15 PM on Monday, not Tuesday.
      final tables = payload['tables'] as Map<String, dynamic>;
      final rows = tables['equipmentBusyReports'] as List<Map<String, dynamic>>;
      rows.single['utcOffsetMinutes'] = -300;

      await BackupService(target).mergeIntoLocal(payload);

      final history = await EquipmentBusyRepository(
        target,
      ).watchHistory('Bench').first;
      expect(
        history.reports.single.reportedGymTime,
        DateTime.utc(2026, 11, 2, 20, 15),
      );
      expect(history.times.single.weekday, DateTime.monday);
      expect(history.times.single.hour, 20);
    },
  );

  test(
    'restoring an older backup replaces busy reports with an empty history',
    () async {
      final reports = EquipmentBusyRepository(target);
      await reports.recordBusy('Bench', at: at);

      await BackupService(
        target,
      ).importJson('{"format":"quadrille.backup","version":2,"tables":{}}');

      expect((await reports.watchHistory('Bench').first).reports, isEmpty);
    },
  );
}
