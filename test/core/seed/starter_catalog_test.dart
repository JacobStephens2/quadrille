import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/seed/starter_catalog.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';

void main() {
  late QuadrilleDatabase db;

  setUp(() => db = QuadrilleDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('seeds the starter catalog into an empty database', () async {
    await seedStarterDataIfEmpty(db);
    final exercises = await ExerciseRepository(db).watchAll().first;
    expect(exercises, isNotEmpty);
    expect(exercises.map((e) => e.name), contains('Barbell Bench Press'));
    expect(exercises.map((e) => e.name), contains('Back Squat'));
  });

  test('is idempotent — a second run does not duplicate', () async {
    await seedStarterDataIfEmpty(db);
    final first = (await ExerciseRepository(db).watchAll().first).length;
    await seedStarterDataIfEmpty(db);
    final second = (await ExerciseRepository(db).watchAll().first).length;
    expect(second, first);
  });

  test('does not seed when the catalog already has entries', () async {
    await ExerciseRepository(db).create(name: 'My Custom Lift');
    await seedStarterDataIfEmpty(db);
    final exercises = await ExerciseRepository(db).watchAll().first;
    expect(exercises, hasLength(1));
    expect(exercises.single.name, 'My Custom Lift');
  });
}
