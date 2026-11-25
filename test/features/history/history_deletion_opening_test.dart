import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/history/history_deletion.dart';

import '../exercises/history_fixture.dart';
import 'history_deletion_fixture.dart';

// Lifecycle scenarios (reentrancy, every retirement reason and timing,
// retry, masking, release) live at the Retained opening seam in
// test/core/retained_opening_test.dart. These tests pin what is specific
// to History deletion: the fixed workout snapshot, the
// deleted/unavailable mapping, and destination retention across a
// profile switch.
void main() {
  late DeletionFixture fixture;
  setUp(() async {
    fixture = DeletionFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  Future<HistoryDeletionOpening> open() async {
    final owner = fixture.container.read(historyDeletionProvider);
    final workout = (await fixture.aRepository.watchSession('session').first)!;
    final opening = owner.open(workout);
    addTearDown(opening.release);
    return opening;
  }

  test('delete persists for the fixed workout snapshot', () async {
    final opening = await open();
    expect(opening.sessionId, 'session');
    expect(opening.name, 'Push session');
    expect(opening.startedAt, HistoryFixture.date);
    expect(opening.state, HistoryDeletionState.idle);
    expect(opening.canSubmit, isTrue);
    expect(await opening.delete(), HistoryDeletionState.deleted);
    expect(opening.state, HistoryDeletionState.deleted);
    expect(opening.canSubmit, isFalse);
    expect(await opening.delete(), HistoryDeletionState.deleted);
    expect(fixture.aRepository.submissions, 1);
    expect(await fixture.exists(fixture.aRepository), isFalse);
    expect(await fixture.exists(fixture.bRepository), isTrue);
  });

  test('a current failure permits one independent retry', () async {
    final opening = await open();
    final failed = DeletionWrite()..fail = true;
    fixture.aRepository.waiting = failed;
    final first = opening.delete();
    await failed.entered.future;
    failed.completion.complete();
    expect(await first, HistoryDeletionState.failed);
    expect(opening.state, HistoryDeletionState.failed);
    expect(opening.canSubmit, isTrue);
    expect(await fixture.exists(fixture.aRepository), isTrue);

    fixture.aRepository.waiting = null;
    expect(await opening.delete(), HistoryDeletionState.deleted);
    expect(fixture.aRepository.submissions, 2);
    expect(await fixture.exists(fixture.aRepository), isFalse);
  });

  for (final target in ['missing', 'deleted', 'discarded', 'active']) {
    test(
      '$target workout is unavailable and terminal through the opening',
      () async {
        final workout = (await fixture.aRepository
            .watchSession('session')
            .first)!;
        var snapshot = workout;
        switch (target) {
          case 'missing':
            snapshot = workout.copyWith(id: 'missing');
          case 'deleted':
            await fixture.aRepository.deleteCompletedSession('session');
          case 'discarded':
          case 'active':
            await HistoryFixture(
              fixture.a,
            ).workout('protected', status: SessionStatus.active);
            snapshot = (await fixture.aRepository
                .watchSession('protected')
                .first)!;
            if (target == 'discarded') {
              await fixture.aRepository.discardSession('protected');
            }
        }
        final opening = fixture.container
            .read(historyDeletionProvider)
            .open(snapshot);
        addTearDown(opening.release);
        final before = fixture.aRepository.submissions;
        expect(await opening.delete(), HistoryDeletionState.unavailable);
        expect(opening.state, HistoryDeletionState.unavailable);
        expect(opening.isCurrent, isTrue);
        expect(opening.canSubmit, isFalse);
        expect(await opening.delete(), HistoryDeletionState.unavailable);
        expect(fixture.aRepository.submissions, before + 1);
        if (target == 'active') {
          expect(await fixture.aRepository.readGrid('protected'), hasLength(1));
        }
      },
    );
  }

  test(
    'distinct openings retain independent snapshots and map through persistence',
    () async {
      final first = await open();
      final second = await open();
      expect(first, isNot(same(second)));
      expect(await first.delete(), HistoryDeletionState.deleted);
      expect(second.state, HistoryDeletionState.idle);
      expect(second.name, 'Push session');
      expect(second.startedAt, HistoryFixture.date);
      expect(second.canSubmit, isTrue);
      expect(await second.delete(), HistoryDeletionState.unavailable);
      expect(fixture.aRepository.submissions, 2);
    },
  );

  test(
    'an accepted deletion retains its destination across a profile switch',
    () async {
      final opening = await open();
      final gate = DeletionWrite();
      fixture.aRepository.waiting = gate;
      final pending = opening.delete();
      await gate.entered.future;
      fixture.switchToB();
      expect(opening.isCurrent, isFalse);
      expect(opening.state, HistoryDeletionState.superseded);
      gate.completion.complete();
      expect(await pending, HistoryDeletionState.superseded);
      expect(await fixture.exists(fixture.aRepository), isFalse);
      expect(await fixture.exists(fixture.bRepository), isTrue);
      expect(fixture.aRepository.submissions, 1);
      expect(fixture.bRepository.submissions, 0);
    },
  );
}
