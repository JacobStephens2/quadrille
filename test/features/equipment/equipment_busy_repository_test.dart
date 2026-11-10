import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/features/equipment/data/equipment_busy_repository.dart';
import 'package:quadrille/features/equipment/domain/equipment_busy_history.dart';

void main() {
  test(
    'groups busy reports by gym weekday and hour, most reported first',
    () async {
      final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final reports = EquipmentBusyRepository(db);
      // November 2, 2026 is Monday; the third is Tuesday.
      await reports.recordBusy('Bench', at: DateTime(2026, 11, 3, 8, 30));
      await reports.recordBusy('BENCH', at: DateTime(2026, 11, 2, 17, 5));
      await reports.recordBusy(' Bench ', at: DateTime(2026, 11, 2, 17, 55));
      await reports.recordBusy('Squat rack', at: DateTime(2026, 11, 2, 17));

      final history = await reports.watchHistory(' bench ').first;

      expect(history.reports, hasLength(3));
      expect(history.times.map((t) => (t.weekday, t.hour, t.count)).toList(), [
        (DateTime.monday, 17, 2),
        (DateTime.tuesday, 8, 1),
      ]);
    },
  );

  test('undo removes only its observation from reactive history', () async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final reports = EquipmentBusyRepository(db);
    final first = await reports.recordBusy(
      'Bench',
      at: DateTime(2026, 11, 2, 17),
    );
    final second = await reports.recordBusy(
      'Bench',
      at: DateTime(2026, 11, 2, 18),
    );
    final updated = expectLater(
      reports.watchHistory('Bench'),
      emitsThrough(
        predicate<EquipmentBusyHistory>(
          (h) => h.reports.length == 1 && h.reports.single.id == second,
        ),
      ),
    );

    await reports.undo(first);
    await updated;
    expect((await reports.watchHistory('Bench').first).times.single.hour, 18);
  });

  test('busy reports survive closing and reopening the database', () async {
    final directory = await Directory.systemTemp.createTemp('quadrille-busy-');
    final file = File('${directory.path}/workout.sqlite');
    var db = QuadrilleDatabase.forTesting(NativeDatabase(file));
    try {
      final at = DateTime(2026, 11, 2, 17, 30);
      final id = await EquipmentBusyRepository(db).recordBusy('Bench', at: at);
      await db.close();
      db = QuadrilleDatabase.forTesting(NativeDatabase(file));
      final history = await EquipmentBusyRepository(
        db,
      ).watchHistory('Bench').first;
      expect(history.reports.single.id, id);
      expect(history.times.single.hour, 17);
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });
}
