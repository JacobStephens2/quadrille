import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/features/session/session_notes_editing.dart';

import 'session_notes_fixture.dart';

// Lifecycle scenarios (reentrancy, every retirement reason and timing,
// retry, masking, release) live at the Retained opening seam in
// test/core/retained_opening_test.dart. These tests pin what is specific to
// Session notes editing: the fixed workout snapshot, the notes write and
// error message, and destination retention across a profile switch.
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

  test('save persists the notes for the fixed workout snapshot', () async {
    final opening = await open();
    expect(opening.sessionId, 'session');
    expect(opening.initialNotes, 'Original');
    expect(opening.state, SessionNotesEditingState.idle);
    expect(opening.canSubmit, isTrue);
    expect(
      await opening.save(' Accepted '),
      SessionNotesEditingState.succeeded,
    );
    expect(opening.state, SessionNotesEditingState.succeeded);
    expect(opening.errorMessage, isNull);
    expect(fixture.aRepository.submissions, 1);
    expect(await fixture.notes(fixture.aRepository), 'Accepted');
    expect(await fixture.notes(fixture.bRepository), 'Original');
  });

  test(
    'failure reports the notes error and a retry saves the latest text',
    () async {
      final opening = await open();
      final firstGate = NotesWrite()..fail = true;
      fixture.aRepository.waiting = firstGate;
      final first = opening.save('First draft');
      await firstGate.entered.future;
      firstGate.completion.complete();
      expect(await first, SessionNotesEditingState.failed);
      expect(opening.state, SessionNotesEditingState.failed);
      expect(opening.errorMessage, 'Could not save notes. Please try again.');
      expect(await fixture.notes(fixture.aRepository), 'Original');

      fixture.aRepository.waiting = null;
      expect(
        await opening.save(' Latest draft '),
        SessionNotesEditingState.succeeded,
      );
      expect(opening.errorMessage, isNull);
      expect(fixture.aRepository.submissions, 2);
      expect(await fixture.notes(fixture.aRepository), 'Latest draft');
    },
  );

  test(
    'distinct openings for one workout retain independent snapshots',
    () async {
      final first = await open();
      final second = await open();
      expect(first, isNot(same(second)));
      expect(
        await first.save('First opening'),
        SessionNotesEditingState.succeeded,
      );
      expect(second.state, SessionNotesEditingState.idle);
      expect(second.initialNotes, 'Original');
      expect(second.canSubmit, isTrue);
      final fresh = await open();
      expect(fresh.initialNotes, 'First opening');
      expect(fresh.sessionId, 'session');
    },
  );

  test(
    'an accepted save retains its destination across a profile switch',
    () async {
      final opening = await open();
      final gate = NotesWrite();
      fixture.aRepository.waiting = gate;
      final pending = opening.save('Captured destination');
      await gate.entered.future;
      fixture.switchToB();
      expect(opening.isCurrent, isFalse);
      expect(opening.state, SessionNotesEditingState.superseded);
      gate.completion.complete();
      expect(await pending, SessionNotesEditingState.superseded);
      expect(opening.errorMessage, isNull);
      expect(await fixture.notes(fixture.aRepository), 'Captured destination');
      expect(await fixture.notes(fixture.bRepository), 'Original');
      expect(fixture.aRepository.submissions, 1);
      expect(fixture.bRepository.submissions, 0);
    },
  );
}
