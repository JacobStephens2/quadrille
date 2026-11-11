import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/history/history_deletion.dart';
import 'package:quadrille/features/session/data/session_repository.dart';
import 'package:quadrille/features/session/session_notes_provider.dart';
import 'package:quadrille/features/session/session_providers.dart';

import '../exercises/history_fixture.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  for (final editingNotes in [true, false]) {
    group(editingNotes ? 'Session notes' : 'History deletion', () {
      late QuadrilleDatabase a;
      late QuadrilleDatabase b;
      late QuadrilleDatabase current;
      late ProviderContainer container;
      var disposed = false;

      setUp(() async {
        disposed = false;
        a = QuadrilleDatabase.forTesting(NativeDatabase.memory());
        b = QuadrilleDatabase.forTesting(NativeDatabase.memory());
        for (final database in [a, b]) {
          await HistoryFixture(database).workout('session');
          await SessionRepository(
            database,
          ).setSessionNotes('session', 'Original');
        }
        current = a;
        container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWith((ref) {
              ref.watch(currentProfileProvider);
              return current;
            }),
          ],
        );
      });

      tearDown(() async {
        if (!disposed) container.dispose();
        await a.close();
        await b.close();
      });

      Future<bool> Function() capture() {
        if (editingNotes) {
          final save = container.read(saveSessionNotesProvider('session'));
          return () => save('Edited');
        }
        return container.read(deleteHistorySessionProvider('session'));
      }

      void invalidateFeature() {
        if (editingNotes) {
          container.invalidate(saveSessionNotesProvider('session'));
        } else {
          container.invalidate(deleteHistorySessionProvider('session'));
        }
      }

      Future<void> expectUnchanged() async {
        for (final database in [a, b]) {
          final repository = SessionRepository(database);
          expect(
            (await repository.watchSession('session').first)!.generalNotes,
            'Original',
          );
          expect((await repository.watchHistory().first).map((s) => s.id), [
            'session',
          ]);
          expect(await repository.readGrid('session'), hasLength(1));
        }
      }

      Future<void> expectFreshWork() async {
        expect(await capture()(), isTrue);
        final repository = SessionRepository(current);
        if (editingNotes) {
          expect(
            (await repository.watchSession('session').first)!.generalNotes,
            'Edited',
          );
        } else {
          expect(await repository.watchHistory().first, isEmpty);
          expect(await repository.readGrid('session'), isEmpty);
        }
      }

      test(
        'feature invalidation immediately rejects its old callback, including after recreation',
        () async {
          final old = capture();
          final generation = container.read(localProfileGenerationProvider);

          invalidateFeature();
          // No intervening provider read or pump may reconstruct the feature.
          expect(await old(), isFalse);
          expect(generation.isCurrent, isTrue);
          await expectUnchanged();

          final fresh = capture();
          expect(await old(), isFalse);
          await expectUnchanged();
          expect(await fresh(), isTrue);
          expect(
            container.read(localProfileGenerationProvider),
            same(generation),
          );
        },
      );

      test(
        'repository replacement rejects captured callbacks while the generation stays current',
        () async {
          final old = capture();
          final generation = container.read(localProfileGenerationProvider);
          container.invalidate(sessionRepositoryProvider);

          expect(await old(), isFalse);
          await expectUnchanged();
          expect(generation.isCurrent, isTrue);
          capture();
          expect(await old(), isFalse);
          await expectUnchanged();
          await expectFreshWork();
        },
      );

      for (final transition in [
        'profile switch',
        'unobserved round trip',
        'database replacement',
      ]) {
        test(
          '$transition rejects old callbacks with overlapping identifiers',
          () async {
            final old = capture();
            if (transition == 'database replacement') {
              current = b;
              container.invalidate(databaseProvider);
            } else {
              current = b;
              container.read(currentProfileProvider.notifier).set('b');
              if (transition == 'unobserved round trip') {
                current = a;
                container
                    .read(currentProfileProvider.notifier)
                    .set(localProfileName);
              }
            }

            expect(await old(), isFalse);
            await expectUnchanged();
            await expectFreshWork();
            expect(await old(), isFalse);
          },
        );
      }

      test(
        'container disposal leaves retained callbacks safe and unable to mutate',
        () async {
          final old = capture();
          container.dispose();
          disposed = true;
          expect(await old(), isFalse);
          await expectUnchanged();
        },
      );
    });
  }
}
