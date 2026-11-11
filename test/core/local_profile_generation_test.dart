import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  late QuadrilleDatabase database;
  late ProviderContainer container;
  var disposed = false;

  setUp(() {
    disposed = false;
    database = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
  });
  tearDown(() async {
    if (!disposed) container.dispose();
    await database.close();
  });

  test(
    'unchanged profile and database retain one generation without listeners',
    () async {
      final generation = container.read(localProfileGenerationProvider);
      await container.pump();
      expect(container.read(localProfileGenerationProvider), same(generation));
      expect(generation.profileName, localProfileName);
      expect(generation.database, same(database));
      expect(generation.isCurrent, isTrue);

      container.read(currentProfileProvider.notifier).set(localProfileName);
      await container.pump();
      expect(container.read(localProfileGenerationProvider), same(generation));
      expect(generation.isCurrent, isTrue);
    },
  );

  test(
    'an unobserved profile round trip permanently retires the generation',
    () {
      final generation = container.read(localProfileGenerationProvider);

      container.read(currentProfileProvider.notifier).set('other');
      container.read(currentProfileProvider.notifier).set(localProfileName);

      expect(generation.isCurrent, isFalse);
      final fresh = container.read(localProfileGenerationProvider);
      expect(fresh, isNot(same(generation)));
      expect(fresh.database, same(database));
      expect(fresh.isCurrent, isTrue);
      expect(generation.isCurrent, isFalse);
    },
  );

  test(
    'profile retirement notifies once, synchronously, after becoming obsolete',
    () {
      final generation = container.read(localProfileGenerationProvider);
      final observed = <bool>[];
      generation.addListener(() => observed.add(generation.isCurrent));

      container.read(currentProfileProvider.notifier).set(localProfileName);
      expect(observed, isEmpty);
      container.read(currentProfileProvider.notifier).set('other');
      expect(observed, [false]);
      expect(generation.isCurrent, isFalse);
      final fresh = container.read(localProfileGenerationProvider);
      expect(fresh.profileName, 'other');
      expect(fresh.database, same(database));
      expect(fresh.isCurrent, isTrue);

      container.read(currentProfileProvider.notifier).set('third');
      container.dispose();
      disposed = true;
      expect(observed, [false]);
    },
  );

  test(
    'same-name database replacement permanently retires the old generation',
    () {
      var replacement = database;
      container.dispose();
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWith((ref) => replacement)],
      );
      final generation = container.read(localProfileGenerationProvider);
      final observed = <bool>[];
      generation.addListener(() => observed.add(generation.isCurrent));
      replacement = QuadrilleDatabase.forTesting(NativeDatabase.memory());
      addTearDown(replacement.close);

      container.invalidate(databaseProvider);
      expect(container.read(databaseProvider), same(replacement));
      expect(observed, [false]);
      expect(generation.isCurrent, isFalse);
      final fresh = container.read(localProfileGenerationProvider);
      expect(fresh, isNot(same(generation)));
      expect(fresh.profileName, localProfileName);
      expect(fresh.database, same(replacement));
      expect(fresh.isCurrent, isTrue);
      expect(generation.database, same(database));
      expect(generation.isCurrent, isFalse);
    },
  );

  test(
    'retained reads and listener removal are safe after container disposal',
    () {
      final generation = container.read(localProfileGenerationProvider);
      final observed = <bool>[];
      void listener() => observed.add(generation.isCurrent);
      generation.addListener(listener);

      container.dispose();
      disposed = true;
      expect(observed, [false]);
      expect(generation.isCurrent, isFalse);
      expect(generation.isCurrent, isFalse);
      expect(generation.profileName, localProfileName);
      expect(generation.database, same(database));
      generation.removeListener(listener);
      generation.removeListener(listener);
      expect(observed, [false]);
    },
  );

  test('a removed listener receives no retirement notification', () {
    final generation = container.read(localProfileGenerationProvider);
    var notifications = 0;
    void listener() => notifications++;
    generation.addListener(listener);
    generation.removeListener(listener);

    container.read(currentProfileProvider.notifier).set('other');
    expect(generation.isCurrent, isFalse);
    expect(notifications, 0);
  });
}
