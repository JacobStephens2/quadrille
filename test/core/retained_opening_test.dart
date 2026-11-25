import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/providers.dart';

import 'retained_opening_fixture.dart';

void main() {
  late RetainedFixture fixture;
  setUp(() => fixture = RetainedFixture()..open());
  tearDown(() => fixture.close());

  FakeOpening open() {
    final opening = fixture.container.read(fakeEditingProvider).open();
    addTearDown(opening.release);
    return opening;
  }

  test(
    'one opening claims pending before reentry and completion is terminal',
    () async {
      final opening = open();
      expect(opening.state, FakeState.idle);
      expect(opening.canSubmit, isTrue);
      final gate = FakeGate();
      fixture.aDestination.waiting = gate;
      Future<FakeState>? reentrant;
      opening.addListener(() {
        if (opening.state == FakeState.pending) {
          expect(opening.canSubmit, isFalse);
          reentrant = opening.perform('Reentrant');
        }
      });
      final first = opening.perform('Accepted');
      expect(reentrant, same(first));
      expect(opening.perform('Repeated'), same(first));
      await gate.entered.future;
      expect(fixture.aDestination.attempts, 1);
      gate.completion.complete();
      expect(await first, FakeState.accepted);
      expect(opening.canSubmit, isFalse);
      expect(await opening.perform('Too late'), FakeState.accepted);
      expect(fixture.aDestination.attempts, 1);
      expect(fixture.aDestination.value, 'Accepted');
      expect(fixture.bDestination.attempts, 0);
    },
  );

  test('the completed-result mapping makes a refused write terminal', () async {
    final opening = open();
    final gate = FakeGate()..result = false;
    fixture.aDestination.waiting = gate;
    final refused = opening.perform('Nope');
    await gate.entered.future;
    gate.completion.complete();
    expect(await refused, FakeState.refused);
    expect(opening.state, FakeState.refused);
    expect(opening.isCurrent, isTrue);
    expect(opening.canSubmit, isFalse);
    expect(await opening.perform('Again'), FakeState.refused);
    expect(fixture.aDestination.attempts, 1);
    expect(fixture.aDestination.value, 'Original');
  });

  test('failure permits retry with an independent future', () async {
    final opening = open();
    final failed = FakeGate()..fail = true;
    fixture.aDestination.waiting = failed;
    final first = opening.perform('First');
    await failed.entered.future;
    failed.completion.complete();
    expect(await first, FakeState.failed);
    expect(opening.state, FakeState.failed);
    expect(opening.canSubmit, isTrue);
    expect(fixture.aDestination.value, 'Original');

    final gate = FakeGate();
    fixture.aDestination.waiting = gate;
    final retry = opening.perform('Latest');
    expect(retry, isNot(same(first)));
    expect(opening.perform('Repeated'), same(retry));
    await gate.entered.future;
    gate.completion.complete();
    expect(await retry, FakeState.accepted);
    expect(fixture.aDestination.attempts, 2);
    expect(fixture.aDestination.value, 'Latest');
  });

  test('fail-without-persisting fails retryably with no write', () async {
    final opening = open();
    expect(await opening.performBlank(), FakeState.failed);
    expect(opening.state, FakeState.failed);
    expect(opening.canSubmit, isTrue);
    expect(await opening.performBlank(), FakeState.failed);
    expect(fixture.aDestination.attempts, 0);
    expect(await opening.perform('Corrected'), FakeState.accepted);
    expect(fixture.aDestination.attempts, 1);
    expect(fixture.aDestination.value, 'Corrected');
  });

  test(
    'a sharing-key join shares one write and finishes by its own currency',
    () async {
      final first = open();
      final joined = open();
      final gate = FakeGate();
      fixture.aDestination.waiting = gate;
      final firstFuture = first.perform('Shared', sharingKey: 'key');
      await gate.entered.future;
      final joinedFuture = joined.perform('Shared', sharingKey: 'key');
      expect(joinedFuture, isNot(same(firstFuture)));
      expect(joined.perform('Shared', sharingKey: 'key'), same(joinedFuture));
      expect(fixture.aDestination.attempts, 1);
      first.release();
      gate.completion.complete();
      expect(await firstFuture, FakeState.superseded);
      expect(await joinedFuture, FakeState.accepted);
      expect(joined.state, FakeState.accepted);
      expect(fixture.aDestination.attempts, 1);
      expect(fixture.aDestination.value, 'Shared');

      // A different key persists on its own, even while this one ran.
      final other = open();
      fixture.aDestination.waiting = null;
      expect(
        await other.perform('Own', sharingKey: 'other'),
        FakeState.accepted,
      );
      expect(fixture.aDestination.attempts, 2);
      expect(fixture.aDestination.value, 'Own');
    },
  );

  test('a joined opening succeeds when its starter is released during the '
      'pending notification before persistence runs', () async {
    final first = open();
    final joined = open();
    Future<FakeState>? joinedFuture;
    var joinedSubmitted = false;
    first.addListener(() {
      if (first.state == FakeState.pending && !joinedSubmitted) {
        joinedSubmitted = true;
        joinedFuture = joined.perform('Shared', sharingKey: 'k');
        first.release();
      }
    });
    final firstFuture = first.perform('Shared', sharingKey: 'k');
    expect(await firstFuture, FakeState.superseded);
    expect(await joinedFuture!, FakeState.accepted);
    expect(joined.state, FakeState.accepted);
    expect(fixture.aDestination.attempts, 1);
    expect(fixture.aDestination.value, 'Shared');
  });

  test(
    'a sharing key never joins submissions with different result types',
    () async {
      final first = open();
      final joined = open();
      final gate = FakeGate();
      fixture.aDestination.waiting = gate;
      final firstFuture = first.perform('BoolPath', sharingKey: 'k');
      await gate.entered.future;
      final joinedFuture = joined.performText(sharingKey: 'k');
      gate.completion.complete();
      expect(await firstFuture, FakeState.accepted);
      expect(await joinedFuture, FakeState.accepted);
      expect(fixture.aDestination.attempts, 1);
      expect(fixture.aDestination.value, 'BoolPath');
    },
  );

  test(
    'concurrent non-sharing openings of one owner complete independently',
    () async {
      final first = open();
      final second = open();
      final firstGate = FakeGate();
      fixture.aDestination.waiting = firstGate;
      final firstFuture = first.perform('First opening');
      await firstGate.entered.future;
      expect(second.state, FakeState.idle);
      expect(second.canSubmit, isTrue);
      final secondGate = FakeGate()..fail = true;
      fixture.aDestination.waiting = secondGate;
      final secondFuture = second.perform('Second opening');
      expect(secondFuture, isNot(same(firstFuture)));
      await secondGate.entered.future;
      firstGate.completion.complete();
      expect(await firstFuture, FakeState.accepted);
      expect(second.state, FakeState.pending);
      secondGate.completion.complete();
      expect(await secondFuture, FakeState.failed);
      expect(first.state, FakeState.accepted);
      expect(fixture.aDestination.attempts, 2);
      expect(fixture.aDestination.value, 'First opening');
    },
  );

  test('a throwing completed-result mapping fails retryably instead of '
      'stranding the claimed future', () async {
    final opening = open();
    expect(await opening.performThrowingMap('Written'), FakeState.failed);
    expect(opening.state, FakeState.failed);
    expect(opening.canSubmit, isTrue);
    expect(fixture.aDestination.attempts, 1);
    expect(await opening.perform('Retried'), FakeState.accepted);
    expect(fixture.aDestination.attempts, 2);
    expect(fixture.aDestination.value, 'Retried');
  });

  test('an opening created superseded fires the retire hook once', () async {
    final owner = fixture.container.read(fakeEditingProvider);
    fixture.switchToB();
    final obsolete = owner.open();
    addTearDown(obsolete.release);
    expect(obsolete.state, FakeState.superseded);
    await Future<void>.delayed(Duration.zero);
    expect(obsolete.retireHookCalls, 1);
    obsolete.release();
    expect(obsolete.retireHookCalls, 1);
    expect(await obsolete.perform('Rejected'), FakeState.superseded);
    expect(fixture.aDestination.attempts, 0);
  });

  test('created-superseded hook runs after subclass body', () async {
    final owner = fixture.container.read(fakeEditingProvider);
    fixture.switchToB();
    late LateHookOpening opening;
    expect(() => opening = owner.openLate(), returnsNormally);
    addTearDown(opening.release);
    expect(opening.state, FakeState.superseded);
    await Future<void>.delayed(Duration.zero);
    expect(opening.retired, isTrue);
  });

  test(
    'the retire hook fires exactly once across retirement and release',
    () async {
      final opening = open();
      fixture.switchToB();
      expect(opening.retireHookCalls, 1);
      opening.release();
      opening.release();
      expect(opening.retireHookCalls, 1);
    },
  );

  test('the retire hook fires once on a bare double release', () async {
    final opening = open();
    opening.release();
    opening.release();
    expect(opening.retireHookCalls, 1);
  });

  test('masked state reports superseded over a stale failed state when the '
      'destination changes', () async {
    final opening = open();
    final failed = FakeGate()..fail = true;
    fixture.aDestination.waiting = failed;
    final first = opening.perform('First');
    await failed.entered.future;
    failed.completion.complete();
    expect(await first, FakeState.failed);
    expect(opening.state, FakeState.failed);

    fixture.replacement = fixture.bDestination;
    fixture.container.invalidate(fakeDestinationProvider);
    expect(opening.state, FakeState.superseded);
    expect(opening.isCurrent, isFalse);
    expect(opening.canSubmit, isFalse);
    expect(await opening.perform('Rejected'), FakeState.superseded);
    expect(fixture.bDestination.attempts, 0);
  });

  void retire(String reason) {
    switch (reason) {
      case 'release':
        throw StateError('Release is opening-specific');
      case 'profile switch':
        fixture.switchToB();
      case 'unobserved round trip':
        fixture.switchToB();
        fixture.current = fixture.a;
        fixture.container
            .read(currentProfileProvider.notifier)
            .set(localProfileName);
      case 'database replacement':
        fixture.current = fixture.b;
        fixture.container.invalidate(databaseProvider);
      case 'destination replacement':
        fixture.replacement = fixture.bDestination;
        fixture.container.invalidate(fakeDestinationProvider);
      case 'owner invalidation':
        fixture.container.invalidate(fakeEditingProvider);
      case 'container disposal':
        fixture.disposeOwner();
    }
  }

  const reasons = [
    'release',
    'profile switch',
    'unobserved round trip',
    'database replacement',
    'destination replacement',
    'owner invalidation',
    'container disposal',
  ];

  for (final reason in reasons) {
    for (final duringNotification in [false, true]) {
      test(
        '$reason ${duringNotification ? 'from a pending listener' : 'before submission'} rejects admission',
        () async {
          final opening = open();
          void revoke() {
            if (reason == 'release') {
              opening.release();
              opening.release();
            } else {
              retire(reason);
            }
          }

          if (duringNotification) {
            opening.addListener(() {
              if (opening.state == FakeState.pending) revoke();
            });
          } else {
            revoke();
          }
          expect(await opening.perform('Rejected'), FakeState.superseded);
          expect(opening.state, FakeState.superseded);
          expect(opening.isCurrent, isFalse);
          expect(opening.canSubmit, isFalse);
          expect(opening.retireHookCalls, 1);
          expect(fixture.aDestination.attempts, 0);
          expect(fixture.bDestination.attempts, 0);
          expect(fixture.aDestination.value, 'Original');
        },
      );
    }

    for (final fail in [false, true]) {
      test(
        '$reason supersedes accepted ${fail ? 'failure' : 'success'} and retains its destination',
        () async {
          final owner = fixture.container.read(fakeEditingProvider);
          final opening = open();
          final gate = FakeGate()..fail = fail;
          fixture.aDestination.waiting = gate;
          var notifications = 0;
          opening.addListener(() => notifications++);
          final pending = opening.perform('Captured destination');
          await gate.entered.future;
          if (reason == 'release') {
            opening.release();
            opening.release();
          } else {
            retire(reason);
          }
          expect(opening.isCurrent, isFalse);
          expect(opening.canSubmit, isFalse);
          expect(opening.retireHookCalls, 1);
          // The canonical prologue: a new submission from a non-current
          // opening returns superseded at once, never the pending future.
          expect(opening.perform('Rejected'), isNot(same(pending)));
          expect(await opening.perform('Rejected'), FakeState.superseded);
          gate.completion.complete();
          expect(await pending, FakeState.superseded);
          expect(opening.state, FakeState.superseded);
          expect(
            fixture.aDestination.value,
            fail ? 'Original' : 'Captured destination',
          );
          expect(fixture.bDestination.value, 'Original');
          expect(fixture.aDestination.attempts, 1);
          expect(fixture.bDestination.attempts, 0);
          if (reason == 'release') {
            expect(notifications, 1);
          } else {
            final obsolete = owner.open();
            addTearDown(obsolete.release);
            expect(obsolete.state, FakeState.superseded);
            expect(obsolete.canSubmit, isFalse);
            expect(await obsolete.perform('Rejected'), FakeState.superseded);
          }

          if (fixture.disposed) fixture.createOwner();
          final fresh = fixture.container.read(fakeEditingProvider).open();
          addTearDown(fresh.release);
          expect(fresh.canSubmit, isTrue);
          expect(opening.isCurrent, isFalse);
        },
      );
    }
  }

  test('an unobserved owner retains openings across provider pumps', () async {
    final opening = open();
    await fixture.container.pump();
    expect(opening.canSubmit, isTrue);
    expect(await opening.perform('Kept'), FakeState.accepted);
  });
}
