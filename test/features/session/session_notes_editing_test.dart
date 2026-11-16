import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/session/session_notes_editing.dart';
import 'package:quadrille/features/session/session_providers.dart';

import 'session_notes_fixture.dart';

void main() {
  late NotesFixture fixture;
  setUp(() async {
    fixture = NotesFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  Future<SessionNotesOpening> open() async {
    final owner = fixture.container.read(sessionNotesEditingProvider);
    final workout = (await fixture.aRepository.watchSession('session').first)!;
    final opening = owner.edit(workout);
    addTearDown(opening.release);
    return opening;
  }

  test(
    'one opening claims pending before reentry and success is terminal',
    () async {
      final owner = fixture.container.read(sessionNotesEditingProvider);
      final workout = (await fixture.aRepository
          .watchSession('session')
          .first)!;
      final opening = owner.edit(workout);
      addTearDown(opening.release);
      expect(opening.initialNotes, 'Original');
      expect(opening.state, SessionNotesEditingState.idle);
      expect(opening.canSubmit, isTrue);
      final gate = NotesWrite();
      fixture.aRepository.waiting = gate;
      Future<SessionNotesEditingState>? reentrant;
      opening.addListener(() {
        if (opening.state == SessionNotesEditingState.pending) {
          expect(opening.canSubmit, isFalse);
          reentrant = opening.save('Reentrant');
        }
      });
      final first = opening.save(' Accepted ');
      expect(reentrant, same(first));
      expect(opening.save('Repeated'), same(first));
      await gate.entered.future;
      expect(fixture.aRepository.submissions, 1);
      gate.completion.complete();
      expect(await first, SessionNotesEditingState.succeeded);
      expect(opening.canSubmit, isFalse);
      expect(
        await opening.save('Too late'),
        SessionNotesEditingState.succeeded,
      );
      expect(fixture.aRepository.submissions, 1);
      expect(await fixture.notes(fixture.aRepository), 'Accepted');
    },
  );

  test(
    'failure permits retry with the latest text and an independent future',
    () async {
      final opening = await open();
      final firstGate = NotesWrite()..fail = true;
      fixture.aRepository.waiting = firstGate;
      final first = opening.save('First draft');
      await firstGate.entered.future;
      firstGate.completion.complete();
      expect(await first, SessionNotesEditingState.failed);
      expect(opening.state, SessionNotesEditingState.failed);
      expect(opening.errorMessage, isNotNull);
      expect(opening.canSubmit, isTrue);
      expect(await fixture.notes(fixture.aRepository), 'Original');

      final retryGate = NotesWrite();
      fixture.aRepository.waiting = retryGate;
      final retry = opening.save(' Latest draft ');
      expect(retry, isNot(same(first)));
      expect(opening.errorMessage, isNull);
      await retryGate.entered.future;
      retryGate.completion.complete();
      expect(await retry, SessionNotesEditingState.succeeded);
      expect(fixture.aRepository.submissions, 2);
      expect(await fixture.notes(fixture.aRepository), 'Latest draft');
    },
  );

  test(
    'distinct openings for one workout retain independent attempts and snapshots',
    () async {
      final first = await open();
      final second = await open();
      expect(first, isNot(same(second)));
      final firstGate = NotesWrite();
      fixture.aRepository.waiting = firstGate;
      final firstSave = first.save('First opening');
      await firstGate.entered.future;
      expect(second.state, SessionNotesEditingState.idle);
      expect(second.canSubmit, isTrue);
      final secondGate = NotesWrite()..fail = true;
      fixture.aRepository.waiting = secondGate;
      final secondSave = second.save('Second opening');
      expect(secondSave, isNot(same(firstSave)));
      await secondGate.entered.future;
      firstGate.completion.complete();
      expect(await firstSave, SessionNotesEditingState.succeeded);
      expect(second.state, SessionNotesEditingState.pending);
      expect(second.initialNotes, 'Original');
      secondGate.completion.complete();
      expect(await secondSave, SessionNotesEditingState.failed);
      expect(first.state, SessionNotesEditingState.succeeded);
      expect(fixture.aRepository.submissions, 2);
      expect(await fixture.notes(fixture.aRepository), 'First opening');
      final fresh = await open();
      expect(fresh.initialNotes, 'First opening');
      expect(fresh.sessionId, 'session');
    },
  );

  for (final fail in [false, true]) {
    test(
      'release rejects new saves and suppresses delayed ${fail ? 'error' : 'success'}',
      () async {
        final opening = await open();
        final gate = NotesWrite()..fail = fail;
        fixture.aRepository.waiting = gate;
        var notifications = 0;
        opening.addListener(() => notifications++);
        final pending = opening.save('Released write');
        await gate.entered.future;
        expect(notifications, 1);
        opening.release();
        opening.release();
        expect(opening.isCurrent, isFalse);
        expect(opening.canSubmit, isFalse);
        expect(
          await opening.save('Rejected'),
          SessionNotesEditingState.superseded,
        );
        gate.completion.complete();
        expect(await pending, SessionNotesEditingState.superseded);
        expect(opening.errorMessage, isNull);
        expect(notifications, 1);
        expect(fixture.aRepository.submissions, 1);
        expect(
          await fixture.notes(fixture.aRepository),
          fail ? 'Original' : 'Released write',
        );
      },
    );
  }

  for (final retirement in [
    'profile switch',
    'unobserved round trip',
    'database replacement',
    'repository replacement',
    'module invalidation',
    'container disposal',
  ]) {
    for (final fail in [false, true]) {
      test(
        '$retirement supersedes delayed ${fail ? 'error' : 'success'} permanently',
        () async {
          final owner = fixture.container.read(sessionNotesEditingProvider);
          final opening = await open();
          final gate = NotesWrite()..fail = fail;
          fixture.aRepository.waiting = gate;
          final pending = opening.save('Captured destination');
          await gate.entered.future;
          switch (retirement) {
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
            case 'repository replacement':
              fixture.replacement = fixture.bRepository;
              fixture.container.invalidate(sessionRepositoryProvider);
            case 'module invalidation':
              fixture.container.invalidate(sessionNotesEditingProvider);
            case 'container disposal':
              fixture.disposeOwner();
          }
          expect(opening.isCurrent, isFalse);
          expect(opening.canSubmit, isFalse);
          expect(opening.state, SessionNotesEditingState.superseded);
          expect(
            await opening.save('Rejected'),
            SessionNotesEditingState.superseded,
          );
          gate.completion.complete();
          expect(await pending, SessionNotesEditingState.superseded);
          expect(opening.errorMessage, isNull);
          expect(
            await fixture.notes(fixture.aRepository),
            fail ? 'Original' : 'Captured destination',
          );
          expect(await fixture.notes(fixture.bRepository), 'Original');
          expect(fixture.aRepository.submissions, 1);
          expect(fixture.bRepository.submissions, 0);
          final snapshot = (await fixture.aRepository
              .watchSession('session')
              .first)!;
          final obsolete = owner.edit(snapshot);
          addTearDown(obsolete.release);
          expect(obsolete.canSubmit, isFalse);
          if (!fixture.disposed) {
            final fresh = fixture.container
                .read(sessionNotesEditingProvider)
                .edit(snapshot);
            addTearDown(fresh.release);
            expect(fresh.canSubmit, isTrue);
            expect(opening.isCurrent, isFalse);
          }
        },
      );
    }
  }
}
