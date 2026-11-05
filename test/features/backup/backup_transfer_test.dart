import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/backup/backup_transfer.dart';
import 'package:quadrille/features/backup/data/backup_service.dart';

import 'backup_transfer_fixture.dart';

void main() {
  late TransferFixture fixture;
  setUp(() async {
    fixture = TransferFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  test(
    'current export copies before downloading using one captured instant',
    () async {
      final result = await fixture.transfer.export(
        fixture.presentation.adapter,
      );
      expect(result.status, BackupTransferStatus.exported);
      expect(result.downloaded, isTrue);
      expect(fixture.effects, ['copy', 'download', 'feedback']);
      expect(
        fixture.platform.downloads.single.filename,
        'quadrille-backup-2026-11-05.json',
      );
      expect(
        fixture.platform.downloads.single.content,
        fixture.platform.copies.single,
      );
      final payload =
          jsonDecode(fixture.platform.copies.single) as Map<String, dynamic>;
      expect(payload['exportedAt'], fixture.now.toUtc().toIso8601String());
      expect(fixture.clockReads, 1);
      final tables = payload['tables'] as Map<String, dynamic>;
      expect(
        (tables['exercises'] as List<dynamic>).single,
        containsPair('name', 'A original'),
      );
      expect(tables, contains('appSettings'));
      expect(tables, isNot(contains('activeTimers')));
      expect(fixture.presentation.messages, [
        'Backup downloaded (and copied to clipboard)',
      ]);
      expect(fixture.transfer.isPending, isFalse);
    },
  );

  test(
    'current restore owns paste fallback, confirmation, counts and replacement',
    () async {
      fixture.presentation.content = await BackupService(
        fixture.b,
      ).exportJson(now: fixture.now);
      final result = await fixture.transfer.restore(
        fixture.presentation.adapter,
      );
      expect(result.status, BackupTransferStatus.restored);
      expect(result.summary!.exercises, 1);
      expect(result.summary!.templates, 0);
      expect(result.summary!.sessions, 0);
      expect(result.summary!.sets, 0);
      expect(await fixture.names(fixture.a), ['B original']);
      expect(await fixture.names(fixture.b), ['B original']);
      expect(fixture.effects, ['pick', 'paste', 'confirm', 'feedback']);
      expect(fixture.presentation.messages, [
        'Restored 1 exercises, 0 templates, 0 sessions.',
      ]);
      expect(fixture.transfer.isPending, isFalse);
      expect(fixture.container.read(currentProfileProvider), localProfileName);
    },
  );

  for (final stage in [
    'pick',
    'paste',
    'confirm',
    'acquire',
    'delete',
    'commit',
  ]) {
    test(
      'restore retired at $stage never redirects or starts a later stage',
      () async {
        final wait = fixture.pauseRestoreAt(stage);
        final transfer = fixture.transfer;
        final pending = transfer.restore(fixture.presentation.adapter);
        expect(transfer.isPending, isTrue);
        await wait.entered.future;
        final submitted = List<String>.of(fixture.effects);
        fixture.switchTo('b');
        wait.completion.complete();
        expect((await pending).status, BackupTransferStatus.superseded);
        expect(fixture.effects, submitted);
        expect(await fixture.names(fixture.b), ['B original']);
        expect(
          await fixture.names(fixture.a),
          ['delete', 'commit'].contains(stage) ? isEmpty : ['A original'],
        );
        expect(transfer.isPending, isFalse);
      },
    );
  }

  for (final stage in ['serialize', 'copy', 'download']) {
    test(
      'export retired at $stage submits no later output or feedback',
      () async {
        final wait = fixture.pauseExportAt(stage);
        final transfer = fixture.transfer;
        final pending = transfer.export(fixture.presentation.adapter);
        await wait.entered.future;
        final submitted = List<String>.of(fixture.effects);
        fixture.switchTo('b');
        wait.completion.complete();
        expect((await pending).status, BackupTransferStatus.superseded);
        expect(fixture.effects, submitted);
        expect(await fixture.names(fixture.a), ['A original']);
        expect(await fixture.names(fixture.b), ['B original']);
        expect(transfer.isPending, isFalse);
      },
    );
  }

  for (final exporting in [false, true]) {
    for (final retirement in [
      'A-to-B-to-A',
      'database replacement',
      'container disposal',
    ]) {
      test(
        '${exporting ? 'export' : 'restore'} is permanently retired by $retirement',
        () async {
          final wait = TransferWait();
          final original = fixture.a;
          if (exporting) {
            fixture.waits.selecting = wait;
          } else {
            fixture.platform.picking = wait;
          }
          final transfer = fixture.transfer;
          final pending = exporting
              ? transfer.export(fixture.presentation.adapter)
              : transfer.restore(fixture.presentation.adapter);
          await wait.entered.future;
          switch (retirement) {
            case 'A-to-B-to-A':
              fixture.switchTo('b');
              fixture.switchTo(localProfileName);
            case 'database replacement':
              fixture.a = await fixture.addDatabase('Replacement original');
              fixture.container.invalidate(databaseProvider);
            case 'container disposal':
              fixture.disposeContainer();
          }
          wait.completion.complete();
          expect((await pending).status, BackupTransferStatus.superseded);
          expect(
            (await transfer.restore(fixture.presentation.adapter)).status,
            BackupTransferStatus.superseded,
          );
          expect(fixture.effects, exporting ? isEmpty : ['pick']);
          expect(await fixture.names(original), ['A original']);
          expect(await fixture.names(fixture.b), ['B original']);
          if (retirement == 'database replacement') {
            expect(await fixture.names(fixture.a), ['Replacement original']);
          }
        },
      );
    }
  }

  test(
    'overlap is busy, including synchronous adapter reentry, without more effects',
    () async {
      final wait = fixture.platform.picking = TransferWait();
      final transfer = fixture.transfer;
      Future<BackupTransferOutcome>? reentrant;
      fixture.platform.onPick = () {
        expect(transfer.isPending, isTrue);
        reentrant = transfer.export(fixture.presentation.adapter);
      };
      final pending = transfer.restore(fixture.presentation.adapter);
      expect((await reentrant!).status, BackupTransferStatus.busy);
      expect(
        (await transfer.restore(fixture.presentation.adapter)).status,
        BackupTransferStatus.busy,
      );
      expect(fixture.effects, ['pick']);
      wait.completion.complete();
      expect((await pending).status, BackupTransferStatus.restored);
      expect(transfer.isPending, isFalse);
    },
  );

  test(
    'new generation proceeds while old picker waits, and old finally cannot clear its pending state',
    () async {
      final oldWait = fixture.platform.picking = TransferWait();
      final old = fixture.transfer.restore(fixture.presentation.adapter);
      await oldWait.entered.future;
      fixture.switchTo('b');
      final newWait = fixture.platform.picking = TransferWait();
      final current = fixture.transfer;
      final fresh = current.restore(fixture.presentation.adapter);
      await newWait.entered.future;
      oldWait.completion.complete();
      expect((await old).status, BackupTransferStatus.superseded);
      expect(current.isPending, isTrue);
      newWait.completion.complete();
      expect((await fresh).status, BackupTransferStatus.restored);
      expect(current.isPending, isFalse);
      expect(await fixture.names(fixture.a), ['A original']);
      expect(await fixture.names(fixture.b), isEmpty);
      expect(fixture.presentation.messages, [
        'Restored 0 exercises, 0 templates, 0 sessions.',
      ]);
    },
  );

  for (final cancellation in [
    'null paste',
    'blank paste',
    'blank file',
    'false confirmation',
    'null confirmation',
  ]) {
    test('$cancellation cancels, preserves rows and permits retry', () async {
      switch (cancellation) {
        case 'null paste':
          fixture.presentation.content = null;
        case 'blank paste':
          fixture.presentation.content = ' \n ';
        case 'blank file':
          fixture.platform.content = ' \n ';
        case 'false confirmation':
          fixture.presentation.confirmed = false;
        case 'null confirmation':
          fixture.presentation.confirmed = null;
      }
      final transfer = fixture.transfer;
      expect(
        (await transfer.restore(fixture.presentation.adapter)).status,
        BackupTransferStatus.cancelled,
      );
      expect(await fixture.names(fixture.a), ['A original']);
      expect(fixture.presentation.messages, isEmpty);
      expect(transfer.isPending, isFalse);
      fixture.platform.content = emptyBackup;
      fixture.presentation.confirmed = true;
      expect(
        (await transfer.restore(fixture.presentation.adapter)).status,
        BackupTransferStatus.restored,
      );
    });
  }

  test(
    'fresh export completes while a retired clipboard submission still waits',
    () async {
      final wait = fixture.platform.copying = TransferWait();
      final old = fixture.transfer.export(fixture.presentation.adapter);
      await wait.entered.future;
      fixture.switchTo('b');
      fixture.platform.copying = null;
      final fresh = await fixture.transfer.export(fixture.presentation.adapter);
      expect(fresh.status, BackupTransferStatus.exported);
      expect(fixture.platform.copies, hasLength(2));
      final payload =
          jsonDecode(fixture.platform.copies.last) as Map<String, dynamic>;
      final tables = payload['tables'] as Map<String, dynamic>;
      expect(
        (tables['exercises'] as List<dynamic>).single,
        containsPair('name', 'B original'),
      );
      expect(fixture.platform.downloads, hasLength(1));
      wait.completion.complete();
      expect((await old).status, BackupTransferStatus.superseded);
      expect(fixture.platform.downloads, hasLength(1));
      expect(fixture.presentation.messages, hasLength(1));
    },
  );

  test(
    'retired download failure cannot report clipboard-only success',
    () async {
      final wait = fixture.platform.downloading = TransferWait();
      fixture.platform.downloadError = StateError('Download blocked');
      final pending = fixture.transfer.export(fixture.presentation.adapter);
      await wait.entered.future;
      fixture.switchTo('b');
      wait.completion.complete();
      expect((await pending).status, BackupTransferStatus.superseded);
      expect(fixture.presentation.messages, isEmpty);
    },
  );

  for (final accepted in [false, true]) {
    test(
      'container disposal ${accepted ? 'after acceptance lets captured replacement finish' : 'before transaction entry preserves rows'}',
      () async {
        final wait = TransferWait();
        if (accepted) {
          fixture.waits.deleting = wait;
        } else {
          fixture.waits.acquiring = wait;
        }
        final pending = fixture.transfer.restore(fixture.presentation.adapter);
        await wait.entered.future;
        fixture.disposeContainer();
        wait.completion.complete();
        expect((await pending).status, BackupTransferStatus.superseded);
        expect(
          await fixture.names(fixture.a),
          accepted ? isEmpty : ['A original'],
        );
        expect(await fixture.names(fixture.b), ['B original']);
        expect(fixture.presentation.messages, isEmpty);
      },
    );
  }

  test(
    'failed accepted replacement rolls back rows and settings, then permits retry',
    () async {
      fixture.platform.content = await BackupService(
        fixture.b,
      ).exportJson(now: fixture.now);
      final before = await BackupService(
        fixture.a,
      ).exportJson(now: fixture.now);
      fixture.waits.failReplacement = true;
      final result = await fixture.transfer.restore(
        fixture.presentation.adapter,
      );
      expect(result.status, BackupTransferStatus.failed);
      expect(result.error, isA<StateError>());
      expect(
        await BackupService(fixture.a).exportJson(now: fixture.now),
        before,
      );
      expect(fixture.presentation.messages, [
        'Import failed. Please try again.',
      ]);
      expect(fixture.transfer.isPending, isFalse);
      fixture.waits.failReplacement = false;
      expect(
        (await fixture.transfer.restore(fixture.presentation.adapter)).status,
        BackupTransferStatus.restored,
      );
    },
  );

  test('format error retains its concise message and original rows', () async {
    fixture.platform.content = 'not JSON';
    final result = await fixture.transfer.restore(fixture.presentation.adapter);
    expect(result.status, BackupTransferStatus.failed);
    expect(result.error, isA<BackupFormatException>());
    expect(fixture.presentation.messages, ['Import failed: Not valid JSON.']);
    expect(await fixture.names(fixture.a), ['A original']);
  });

  for (final stage in [
    'picker',
    'paste',
    'confirmation',
    'serialization',
    'clipboard',
    'feedback',
  ]) {
    test(
      '$stage failure settles as failed and releases pending state',
      () async {
        final error = StateError('Unavailable');
        final exporting = ['serialization', 'clipboard'].contains(stage);
        switch (stage) {
          case 'picker':
            fixture.platform.pickError = error;
          case 'paste':
            fixture.presentation.pasteError = error;
          case 'confirmation':
            fixture.presentation.confirmationError = error;
          case 'serialization':
            await fixture.a.close();
          case 'clipboard':
            fixture.platform.copyError = error;
          case 'feedback':
            fixture.presentation.feedbackError = error;
        }
        final transfer = fixture.transfer;
        final result = exporting
            ? await transfer.export(fixture.presentation.adapter)
            : await transfer.restore(fixture.presentation.adapter);
        expect(result.status, BackupTransferStatus.failed);
        expect(result.error, isNotNull);
        expect(transfer.isPending, isFalse);
        expect(fixture.platform.downloads, isEmpty);
        if (stage != 'feedback') {
          expect(fixture.presentation.messages, [
            '${exporting ? 'Export' : 'Import'} failed. Please try again.',
          ]);
        }
      },
    );
  }

  for (final supportsDownload in [false, true]) {
    test(
      'export succeeds through clipboard when download is ${supportsDownload ? 'failing' : 'unavailable'}',
      () async {
        fixture.platform.downloadAvailable = supportsDownload;
        fixture.platform.downloadError = StateError('Download blocked');
        final result = await fixture.transfer.export(
          fixture.presentation.adapter,
        );
        expect(result.status, BackupTransferStatus.exported);
        expect(result.downloaded, isFalse);
        expect(fixture.platform.copies, hasLength(1));
        expect(fixture.platform.downloads, hasLength(supportsDownload ? 1 : 0));
        expect(fixture.presentation.messages, ['Backup copied to clipboard']);
      },
    );
  }

  for (final exporting in [false, true]) {
    test(
      'supersession takes precedence over an obsolete ${exporting ? 'clipboard' : 'picker'} error',
      () async {
        final wait = TransferWait();
        if (exporting) {
          fixture.platform.copying = wait;
          fixture.platform.copyError = StateError('Clipboard blocked');
        } else {
          fixture.platform.picking = wait;
          fixture.platform.pickError = StateError('Picker failed');
        }
        final pending = exporting
            ? fixture.transfer.export(fixture.presentation.adapter)
            : fixture.transfer.restore(fixture.presentation.adapter);
        await wait.entered.future;
        fixture.switchTo('b');
        wait.completion.complete();
        expect((await pending).status, BackupTransferStatus.superseded);
        expect(fixture.presentation.messages, isEmpty);
        expect(fixture.platform.downloads, isEmpty);
      },
    );
  }

  for (final stage in [
    'pick',
    'paste',
    'confirm',
    'acquire',
    'delete',
    'commit',
  ]) {
    test(
      'screen removal at $stage suppresses presentation and preserves accepted restore semantics',
      () async {
        final wait = fixture.pauseRestoreAt(stage);
        final pending = fixture.transfer.restore(fixture.presentation.adapter);
        await wait.entered.future;
        fixture.presentation.available = false;
        wait.completion.complete();
        final accepted = ['acquire', 'delete', 'commit'].contains(stage);
        expect(
          (await pending).status,
          accepted
              ? BackupTransferStatus.restored
              : BackupTransferStatus.cancelled,
        );
        expect(
          await fixture.names(fixture.a),
          accepted ? isEmpty : ['A original'],
        );
        expect(fixture.presentation.messages, isEmpty);
      },
    );
  }

  for (final stage in ['serialize', 'copy', 'download']) {
    test(
      'screen removal during $stage permits current export outputs without feedback',
      () async {
        final wait = fixture.pauseExportAt(stage);
        final pending = fixture.transfer.export(fixture.presentation.adapter);
        await wait.entered.future;
        fixture.presentation.available = false;
        wait.completion.complete();
        expect((await pending).status, BackupTransferStatus.exported);
        expect(fixture.effects, ['copy', 'download']);
        expect(fixture.presentation.messages, isEmpty);
      },
    );
  }
}
