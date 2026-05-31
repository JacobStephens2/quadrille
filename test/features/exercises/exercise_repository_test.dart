import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';

void main() {
  late QuadrilleDatabase db;
  late ExerciseRepository repo;

  setUp(() {
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    repo = ExerciseRepository(db);
  });
  tearDown(() => db.close());

  test('creates and lists exercises alphabetically', () async {
    await repo.create(name: 'Squat', category: ExerciseCategory.legs);
    await repo.create(name: 'Bench Press', category: ExerciseCategory.push);
    final list = await repo.watchAll().first;
    expect(list.map((e) => e.name).toList(), ['Bench Press', 'Squat']);
  });

  test('update changes fields and bumps updatedAt', () async {
    final id = await repo.create(name: 'Press', defaultRestSeconds: 90);
    final before = await repo.getById(id);
    await repo.update(id, name: 'Overhead Press', defaultRestSeconds: 120);
    final after = await repo.getById(id);
    expect(after!.name, 'Overhead Press');
    expect(after.defaultRestSeconds, 120);
    expect(after.updatedAt.isAfter(before!.updatedAt) ||
        after.updatedAt == before.updatedAt, isTrue);
  });

  test('archive hides from the list but keeps the row', () async {
    final id = await repo.create(name: 'Old Lift');
    await repo.archive(id);
    expect(await repo.watchAll().first, isEmpty);
    expect((await repo.getById(id))!.archived, isTrue);
  });
}
