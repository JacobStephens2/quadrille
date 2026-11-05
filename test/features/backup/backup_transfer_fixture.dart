import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
import 'package:quadrille/features/backup/backup_transfer.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';

const emptyBackup = '{"format":"quadrille.backup","version":2,"tables":{}}';

class TransferWait {
  final entered = Completer<void>();
  final completion = Completer<void>();

  Future<void> wait() {
    if (!entered.isCompleted) entered.complete();
    return completion.future;
  }
}

class TransferDatabaseWaits extends QueryInterceptor {
  TransferWait? selecting;
  TransferWait? acquiring;
  TransferWait? deleting;
  TransferWait? committing;
  bool failReplacement = false;

  @override
  Future<bool> ensureOpen(
    QueryExecutor executor,
    QueryExecutorUser user,
  ) async {
    if (executor is TransactionExecutor) await acquiring?.wait();
    return super.ensureOpen(executor, user);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('exercises')) await selecting?.wait();
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    await deleting?.wait();
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) async {
    if (failReplacement) throw StateError('Disk full');
    return super.runBatched(executor, statements);
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    await committing?.wait();
    return super.commitTransaction(inner);
  }
}

class TransferPlatform implements BackupPlatform {
  TransferPlatform(this.effects);
  final List<String> effects;
  TransferWait? picking;
  TransferWait? copying;
  TransferWait? downloading;
  String? content;
  bool downloadAvailable = true;
  Object? pickError;
  Object? copyError;
  Object? downloadError;
  void Function()? onPick;
  final copies = <String>[];
  final downloads = <({String filename, String content})>[];

  @override
  Future<String?> pickText() async {
    effects.add('pick');
    onPick?.call();
    await picking?.wait();
    if (pickError case final error?) throw error;
    return content;
  }

  @override
  Future<void> copyText(String content) async {
    effects.add('copy');
    copies.add(content);
    await copying?.wait();
    if (copyError case final error?) throw error;
  }

  @override
  bool get supportsDownload => downloadAvailable;

  @override
  Future<void> download(String filename, String content) async {
    effects.add('download');
    downloads.add((filename: filename, content: content));
    await downloading?.wait();
    if (downloadError case final error?) throw error;
  }
}

class TransferPresentation {
  TransferPresentation(this.effects);
  final List<String> effects;
  bool available = true;
  String? content = emptyBackup;
  bool? confirmed = true;
  TransferWait? pasting;
  TransferWait? confirming;
  Object? pasteError;
  Object? confirmationError;
  Object? feedbackError;
  final messages = <String>[];

  late final adapter = BackupPresentation(
    isAvailable: () => available,
    paste: () async {
      effects.add('paste');
      await pasting?.wait();
      if (pasteError case final error?) throw error;
      return content;
    },
    confirmReplacement: () async {
      effects.add('confirm');
      await confirming?.wait();
      if (confirmationError case final error?) throw error;
      return confirmed;
    },
    feedback: (message) {
      effects.add('feedback');
      if (feedbackError case final error?) throw error;
      messages.add(message);
    },
  );
}

class TransferFixture {
  final databases = <QuadrilleDatabase>[];
  final interception = <QuadrilleDatabase, TransferDatabaseWaits>{};
  final effects = <String>[];
  late final platform = TransferPlatform(effects);
  late final presentation = TransferPresentation(effects);
  late ProviderContainer container;
  late QuadrilleDatabase a;
  late QuadrilleDatabase b;
  bool disposed = false;
  int clockReads = 0;
  DateTime now = DateTime(2026, 11, 5, 23, 59, 59);

  Future<QuadrilleDatabase> addDatabase(String name) async {
    final waits = TransferDatabaseWaits();
    final db = QuadrilleDatabase.forTesting(
      NativeDatabase.memory().interceptWith(waits),
    );
    databases.add(db);
    interception[db] = waits;
    await ExerciseRepository(db).create(name: name);
    return db;
  }

  Future<void> open() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    a = await addDatabase('A original');
    b = await addDatabase('B original');
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWith(
          (ref) => ref.watch(currentProfileProvider) == 'b' ? b : a,
        ),
        backupPlatformProvider.overrideWithValue(platform),
        authControllerProvider.overrideWith(_TransferAuth.new),
        backupNowProvider.overrideWithValue(() {
          clockReads++;
          return now;
        }),
      ],
    );
  }

  BackupTransfer get transfer => container.read(backupTransferProvider);
  TransferDatabaseWaits get waits => interception[a]!;

  TransferWait pauseRestoreAt(String stage) {
    final wait = TransferWait();
    platform.content = emptyBackup;
    switch (stage) {
      case 'pick':
        platform.picking = wait;
      case 'paste':
        platform.content = null;
        presentation.pasting = wait;
      case 'confirm':
        presentation.confirming = wait;
      case 'acquire':
        waits.acquiring = wait;
      case 'delete':
        waits.deleting = wait;
      case 'commit':
        waits.committing = wait;
      default:
        throw ArgumentError.value(stage, 'stage');
    }
    return wait;
  }

  TransferWait pauseExportAt(String stage) {
    final wait = TransferWait();
    switch (stage) {
      case 'serialize':
        waits.selecting = wait;
      case 'copy':
        platform.copying = wait;
      case 'download':
        platform.downloading = wait;
      default:
        throw ArgumentError.value(stage, 'stage');
    }
    return wait;
  }

  void switchTo(String profile) =>
      container.read(currentProfileProvider.notifier).set(profile);

  Future<List<String>> names(QuadrilleDatabase db) async =>
      (await ExerciseRepository(
        db,
      ).watchAll().first).map((row) => row.name).toList();

  void disposeContainer() {
    container.dispose();
    disposed = true;
  }

  Future<void> close() async {
    if (!disposed) disposeContainer();
    for (final db in databases) {
      await db.close();
    }
  }
}

class _TransferAuth extends AuthController {
  @override
  Future<AuthState> build() async => AuthState.localOnly;
}
