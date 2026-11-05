import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
import 'package:quadrille/features/auth/data/auth_api.dart';
import 'package:quadrille/features/settings/data/settings_repository.dart';
import 'package:quadrille/features/session/session_ending.dart';
import 'package:quadrille/features/sync/sync_coordinator.dart';

import 'session_ending_fixture.dart';

void main() {
  late EndingFixture fixture;

  setUp(() async {
    fixture = EndingFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  SessionEndingHandle bind([String id = EndingFixture.sessionId]) =>
      fixture.container.read(sessionEndingProvider(id));

  test(
    'Finish completes locally after cancelling the singleton Rest timer',
    () async {
      final ending = fixture.container.read(
        sessionEndingProvider(EndingFixture.sessionId),
      );
      final gate = EndingWait();
      fixture.notifications.cancelling = gate;
      final pending = ending.end(SessionEndingIntent.finish);
      await gate.entered.future;
      expect((await fixture.session(fixture.a)).status, SessionStatus.active);
      expect(ending.isPending, isTrue);
      gate.completion.complete();

      final outcome = await pending;
      expect(outcome.status, SessionEndingStatus.ended);
      expect(outcome.intent, SessionEndingIntent.finish);
      expect(
        (await fixture.session(fixture.a)).status,
        SessionStatus.completed,
      );
      expect(await fixture.timer(fixture.a), isNull);
      expect(await fixture.timer(fixture.b), isNotNull);
      expect(fixture.notifications.cancellations, 1);
      expect(fixture.requests, isEmpty);
    },
  );

  for (final intent in SessionEndingIntent.values) {
    test(
      '$intent leaves both session copies and B Rest timer untouched after a switch',
      () async {
        fixture.changeSync();
        await SettingsRepository(fixture.a).update(autoSync: true);
        final ending = bind();
        final savedA = await fixture.session(fixture.a);
        final savedB = await fixture.session(fixture.b);
        final timerB = await fixture.timer(fixture.b);
        final gate = EndingWait();
        fixture.notifications.cancelling = gate;
        final pending = ending.end(intent);
        await gate.entered.future;
        fixture.switchTo('b');
        gate.completion.complete();
        expect((await pending).status, SessionEndingStatus.superseded);
        expect(await fixture.session(fixture.a), savedA);
        expect(await fixture.session(fixture.b), savedB);
        expect(await fixture.timer(fixture.b), timerB);
        expect(fixture.notifications.cancellations, 1);
        expect(fixture.watch.clears, 0);
        expect(fixture.requests, isEmpty);
      },
    );

    test('$intent ends a live session with an empty Session grid', () async {
      fixture.a = await fixture.addDatabase(withGrid: false);
      fixture.container.invalidate(databaseProvider);
      expect(
        await fixture.sessions(fixture.a).readGrid(EndingFixture.sessionId),
        isEmpty,
      );
      expect((await bind().end(intent)).status, SessionEndingStatus.ended);
      final saved = await fixture.session(fixture.a);
      if (intent == SessionEndingIntent.finish) {
        expect(saved.status, SessionStatus.completed);
      } else {
        expect(saved.deletedAt, isNotNull);
      }
    });

    test(
      '$intent stays obsolete after A-to-B-to-A during cancellation',
      () async {
        final ending = bind();
        final gate = EndingWait();
        fixture.notifications.cancelling = gate;
        final pending = ending.end(intent);
        await gate.entered.future;
        fixture.switchTo('b');
        fixture.switchTo('a');
        gate.completion.complete();
        expect((await pending).status, SessionEndingStatus.superseded);
        expect((await fixture.session(fixture.a)).status, SessionStatus.active);
        expect((await fixture.session(fixture.a)).deletedAt, isNull);
        expect(await fixture.timer(fixture.b), isNotNull);
        expect(bind().isCurrent, isTrue);
      },
    );

    test(
      '$intent is permanently obsolete before confirmation after A-to-B-to-A',
      () async {
        final ending = bind();
        fixture.switchTo('b');
        fixture.switchTo('a');
        expect(ending.isCurrent, isFalse);
        expect(
          (await ending.end(intent)).status,
          SessionEndingStatus.superseded,
        );
        expect(fixture.notifications.cancellations, 0);
        expect((await fixture.session(fixture.a)).status, SessionStatus.active);
        expect((await fixture.session(fixture.b)).deletedAt, isNull);
        expect(await fixture.timer(fixture.a), isNotNull);
        expect(await fixture.timer(fixture.b), isNotNull);
        expect(bind().isCurrent, isTrue);
      },
    );

    test(
      '$intent stops after a profile switch during cancellation; new owner does not wait',
      () async {
        fixture.changeSync();
        await SettingsRepository(fixture.a).update(autoSync: true);
        final ending = bind();
        final gate = EndingWait();
        fixture.notifications.cancelling = gate;
        final pending = ending.end(intent);
        await gate.entered.future;
        fixture.switchTo('b');
        expect(await fixture.timer(fixture.b), isNotNull);
        expect((await fixture.session(fixture.b)).status, SessionStatus.active);
        fixture.notifications.cancelling = null;
        // The replacement owner gets an independent ending before A settles.
        expect(
          (await bind().end(SessionEndingIntent.finish)).status,
          SessionEndingStatus.ended,
        );
        gate.completion.complete();
        expect((await pending).status, SessionEndingStatus.superseded);
        expect((await fixture.session(fixture.a)).status, SessionStatus.active);
        expect((await fixture.session(fixture.a)).deletedAt, isNull);
        expect(
          (await fixture.session(fixture.b)).status,
          SessionStatus.completed,
        );
        expect(fixture.watch.clears, 1);
        expect(fixture.requests, isEmpty);
      },
    );

    test(
      '$intent coalesces duplicate and conflicting requests and stays terminal',
      () async {
        final ending = bind();
        final gate = EndingWait();
        fixture.notifications.cancelling = gate;
        final pending = ending.end(intent);
        final other = intent == SessionEndingIntent.finish
            ? SessionEndingIntent.discard
            : SessionEndingIntent.finish;
        expect(identical(pending, bind().end(intent)), isTrue);
        expect(identical(pending, bind().end(other)), isTrue);
        await gate.entered.future;
        gate.completion.complete();
        final ended = await pending;
        final saved = await fixture.session(fixture.a);
        expect(ended.intent, intent);
        expect(identical(await ending.end(other), ended), isTrue);
        expect(await fixture.session(fixture.a), saved);
        expect(fixture.notifications.cancellations, 1);
        expect(ending.isPending, isFalse);
      },
    );

    test(
      '$intent cancellation failure is retryable and never uploads',
      () async {
        fixture.changeSync();
        await SettingsRepository(fixture.a).update(autoSync: true);
        fixture.notifications.fail = true;
        final ending = bind();
        final failed = await ending.end(intent);
        expect(failed.status, SessionEndingStatus.failed);
        expect(
          failed.error.toString(),
          contains('Alerts could not be cancelled'),
        );
        expect(ending.isPending, isFalse);
        expect((await fixture.session(fixture.a)).status, SessionStatus.active);
        expect(fixture.requests, isEmpty);
        fixture.notifications.fail = false;
        expect((await ending.end(intent)).status, SessionEndingStatus.ended);
      },
    );

    test(
      '$intent persistence failure is retryable and never uploads',
      () async {
        fixture.changeSync();
        await SettingsRepository(fixture.a).update(autoSync: true);
        fixture.waits.first.failMutation = true;
        final ending = bind();
        expect((await ending.end(intent)).status, SessionEndingStatus.failed);
        expect((await fixture.session(fixture.a)).status, SessionStatus.active);
        expect(fixture.requests, isEmpty);
        fixture.waits.first.failMutation = false;
        expect((await ending.end(intent)).status, SessionEndingStatus.ended);
      },
    );

    for (final state in ['missing', 'completed', 'deleted']) {
      test(
        '$intent reports $state as unavailable without cancellation',
        () async {
          if (state == 'completed') {
            await fixture
                .sessions(fixture.a)
                .completeSession(EndingFixture.sessionId);
          } else if (state == 'deleted') {
            await fixture
                .sessions(fixture.a)
                .discardSession(EndingFixture.sessionId);
          }
          final saved = await fixture.session(fixture.a);
          final ending = bind(
            state == 'missing' ? 'missing' : EndingFixture.sessionId,
          );
          expect(
            (await ending.end(intent)).status,
            SessionEndingStatus.unavailable,
          );
          expect(await fixture.session(fixture.a), saved);
          expect(fixture.notifications.cancellations, 0);
        },
      );
    }

    test(
      '$intent does not rewrite a session made unavailable during cancellation',
      () async {
        final ending = bind();
        final gate = EndingWait();
        fixture.notifications.cancelling = gate;
        final pending = ending.end(intent);
        await gate.entered.future;
        await fixture
            .sessions(fixture.a)
            .completeSession(EndingFixture.sessionId);
        final saved = await fixture.session(fixture.a);
        gate.completion.complete();
        expect((await pending).status, SessionEndingStatus.unavailable);
        expect(await fixture.session(fixture.a), saved);
        expect(fixture.requests, isEmpty);
      },
    );
  }

  test(
    'same-name database replacement invalidates old dialogs permanently',
    () async {
      final ending = bind();
      final original = fixture.a;
      fixture.a = await fixture.addDatabase();
      fixture.container.invalidate(databaseProvider);
      expect(
        (await ending.end(SessionEndingIntent.finish)).status,
        SessionEndingStatus.superseded,
      );
      expect((await fixture.session(original)).status, SessionStatus.active);
      expect((await fixture.session(fixture.a)).status, SessionStatus.active);
      expect(fixture.notifications.cancellations, 0);
      expect(
        (await bind().end(SessionEndingIntent.finish)).status,
        SessionEndingStatus.ended,
      );
    },
  );

  test(
    'database replacement during cancellation cannot mutate either copy',
    () async {
      final ending = bind();
      final original = fixture.a;
      final gate = EndingWait();
      fixture.notifications.cancelling = gate;
      final pending = ending.end(SessionEndingIntent.discard);
      await gate.entered.future;
      fixture.a = await fixture.addDatabase();
      fixture.container.invalidate(databaseProvider);
      gate.completion.complete();
      expect((await pending).status, SessionEndingStatus.superseded);
      expect((await fixture.session(original)).deletedAt, isNull);
      expect((await fixture.session(fixture.a)).deletedAt, isNull);
      expect(await fixture.timer(fixture.a), isNotNull);
      expect(fixture.watch.clears, 0);
    },
  );

  test('ownership is checked after the initial session read', () async {
    final gate = EndingWait();
    fixture.waits.first.selecting = gate;
    final pending = bind().end(SessionEndingIntent.finish);
    await gate.entered.future;
    fixture.switchTo('b');
    gate.completion.complete();
    expect((await pending).status, SessionEndingStatus.superseded);
    expect(fixture.notifications.cancellations, 0);
    expect(await fixture.timer(fixture.b), isNotNull);
  });

  test(
    'an already-started mutation stays in its captured database and cannot upload',
    () async {
      fixture.changeSync();
      await SettingsRepository(fixture.a).update(autoSync: true);
      final gate = EndingWait();
      fixture.waits.first.updating = gate;
      final pending = bind().end(SessionEndingIntent.finish);
      await gate.entered.future;
      fixture.switchTo('b');
      gate.completion.complete();
      expect((await pending).status, SessionEndingStatus.superseded);
      expect(
        (await fixture.session(fixture.a)).status,
        SessionStatus.completed,
      );
      expect((await fixture.session(fixture.b)).status, SessionStatus.active);
      expect(fixture.requests, isEmpty);
    },
  );

  test(
    'Discard committing during a database replacement stays in the captured database',
    () async {
      final original = fixture.a;
      final gate = EndingWait();
      fixture.waits.first.committing = gate;
      final pending = bind().end(SessionEndingIntent.discard);
      await gate.entered.future;
      fixture.a = await fixture.addDatabase();
      fixture.container.invalidate(databaseProvider);
      gate.completion.complete();
      expect((await pending).status, SessionEndingStatus.superseded);
      expect((await fixture.session(original)).deletedAt, isNotNull);
      expect((await fixture.session(fixture.a)).deletedAt, isNull);
      expect(await fixture.timer(fixture.a), isNotNull);
      expect(fixture.requests, isEmpty);
    },
  );

  test('obsolete duplicates still share the accepted pending result', () async {
    final ending = bind();
    final gate = EndingWait();
    fixture.notifications.cancelling = gate;
    final pending = ending.end(SessionEndingIntent.finish);
    await gate.entered.future;
    fixture.switchTo('b');
    final duplicate = ending.end(SessionEndingIntent.discard);
    final shared = identical(duplicate, pending);
    gate.completion.complete();
    expect((await pending).status, SessionEndingStatus.superseded);
    expect((await duplicate).status, SessionEndingStatus.superseded);
    expect(shared, isTrue);
  });

  test('supersession takes precedence over a cancellation failure', () async {
    final gate = EndingWait();
    fixture.notifications.cancelling = gate;
    fixture.notifications.fail = true;
    final pending = bind().end(SessionEndingIntent.finish);
    await gate.entered.future;
    fixture.switchTo('b');
    gate.completion.complete();
    expect((await pending).status, SessionEndingStatus.superseded);
  });

  test(
    'Discard tombstones parent and all children with one timestamp and never uploads',
    () async {
      fixture.changeSync();
      await SettingsRepository(fixture.a).update(autoSync: true);
      final outcome = await bind().end(SessionEndingIntent.discard);
      expect(outcome.status, SessionEndingStatus.ended);
      final session = await fixture.session(fixture.a);
      final exercise = await fixture.a
          .select(fixture.a.sessionExercises)
          .getSingle();
      final set = await fixture.a.select(fixture.a.setEntries).getSingle();
      expect(session.deletedAt, isNotNull);
      expect([
        session.updatedAt,
        exercise.deletedAt,
        exercise.updatedAt,
        set.deletedAt,
        set.updatedAt,
      ], everyElement(session.deletedAt));
      expect(set.weight, 70);
      expect(set.reps, 10);
      expect(set.completedAt, DateTime(2026, 11, 4, 12));
      expect(fixture.requests, isEmpty);
    },
  );

  test(
    'a failed child tombstone rolls back the entire Discard and permits retry',
    () async {
      fixture.waits.first.failSets = true;
      final ending = bind();
      expect(
        (await ending.end(SessionEndingIntent.discard)).status,
        SessionEndingStatus.failed,
      );
      expect((await fixture.session(fixture.a)).deletedAt, isNull);
      expect(
        await fixture.sessions(fixture.a).readGrid(EndingFixture.sessionId),
        hasLength(1),
      );
      fixture.waits.first.failSets = false;
      expect(
        (await ending.end(SessionEndingIntent.discard)).status,
        SessionEndingStatus.ended,
      );
    },
  );

  test(
    'Finish submits once using the accepted Account sync owner without waiting for transport',
    () async {
      fixture.changeSync();
      await SettingsRepository(fixture.a).update(autoSync: true);
      final gate = EndingWait();
      fixture.transport = (_) async {
        await gate.wait();
        return http.Response('{"revision": 9}', 200);
      };
      final ending = bind();
      expect(
        (await ending.end(SessionEndingIntent.finish)).status,
        SessionEndingStatus.ended,
      );
      await gate.entered.future;
      final request = fixture.requests.single;
      expect(request.headers['Authorization'], 'Bearer token-a');
      expect(request.headers['X-Quadrille-Expected-Account'], 'a');
      expect(request.body, contains('completed'));
      expect(
        (jsonDecode(request.body) as Map).toString(),
        isNot(contains('active_timers')),
      );
      await ending.end(SessionEndingIntent.discard);
      expect(fixture.requests, hasLength(1));
      gate.completion.complete();
      // The existing Account sync FIFO drains the submitted upload.
      await fixture.container.read(syncCoordinatorProvider).pullOnLaunch();
    },
  );

  for (final policy in [
    'auto-sync off',
    'local-only',
    'unverified',
    'changed generation',
    'wrong profile',
    'transport failure',
  ]) {
    test('Finish preserves local success with $policy', () async {
      if (policy != 'local-only' && policy != 'unverified') {
        fixture.changeSync();
      }
      if (policy == 'unverified') {
        fixture.auth.change(
          const AuthState(
            status: AuthStatus.signedIn,
            user: AuthUser(
              id: 'a',
              email: 'a@example.com',
              emailVerified: false,
            ),
          ),
        );
      }
      await SettingsRepository(
        fixture.a,
      ).update(autoSync: policy != 'auto-sync off');
      if (policy == 'wrong profile') fixture.changeSync(account: 'b');
      final gate = EndingWait();
      fixture.notifications.cancelling = gate;
      fixture.transport = (_) async => http.Response('unavailable', 503);
      final pending = bind().end(SessionEndingIntent.finish);
      await gate.entered.future;
      if (policy == 'changed generation') fixture.changeSync();
      gate.completion.complete();
      expect((await pending).status, SessionEndingStatus.ended);
      expect(
        (await fixture.session(fixture.a)).status,
        SessionStatus.completed,
      );
      await fixture.container.read(syncCoordinatorProvider).pullOnLaunch();
      if (policy == 'transport failure') {
        expect(fixture.requests.where((r) => r.method == 'PUT'), hasLength(1));
      } else {
        expect(fixture.requests.where((r) => r.method == 'PUT'), isEmpty);
      }
    });
  }

  test(
    'container disposal during cancellation stops downstream work',
    () async {
      final gate = EndingWait();
      fixture.notifications.cancelling = gate;
      final pending = bind().end(SessionEndingIntent.finish);
      await gate.entered.future;
      fixture.container.dispose();
      gate.completion.complete();
      expect((await pending).status, SessionEndingStatus.superseded);
      expect((await fixture.session(fixture.a)).status, SessionStatus.active);
    },
  );
}
