import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart'
    show
        ApplyInterceptor,
        QueryExecutor,
        QueryInterceptor,
        TransactionExecutor,
        driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/auth/auth_controller.dart';
import 'package:quadrille/features/auth/data/auth_api.dart';
import 'package:quadrille/features/auth/data/profile_store.dart';
import 'package:quadrille/features/auth/data/token_store.dart';
import 'package:quadrille/features/backup/data/backup_service.dart';
import 'package:quadrille/features/backup/backup_providers.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';
import 'package:quadrille/features/settings/data/settings_repository.dart';

class Tokens extends TokenStore {
  String? token = 'token-a';
  PendingCall? reading;
  PendingCall? writing;

  @override
  Future<String?> read() async {
    await reading?.wait();
    return token;
  }

  @override
  Future<void> write(String value) async {
    await writing?.wait();
    token = value;
  }

  @override
  Future<void> clear() async => token = null;
}

class Profiles extends ProfileStore {
  PendingCall? writing;

  @override
  Future<void> write(String profileName) async {
    await writing?.wait();
  }
}

class PendingCall {
  final entered = Completer<void>();
  final completion = Completer<void>();

  Future<void> wait() {
    if (!entered.isCompleted) entered.complete();
    return completion.future;
  }
}

class DatabaseWaits extends QueryInterceptor {
  String? table;
  PendingCall? selecting;
  PendingCall? committing;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (table != null && statement.contains(table!)) await selecting?.wait();
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    await committing?.wait();
    await super.commitTransaction(inner);
  }
}

Map<String, dynamic> user(String id, {bool verified = true}) => {
  'id': id,
  'email': '$id@example.com',
  'emailVerified': verified,
};

http.Response response(Object body) => http.Response(jsonEncode(body), 200);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Map<String, QuadrilleDatabase> databases;
  late ProviderContainer container;
  late Future<http.Response> Function(http.Request) syncRequest;
  late Future<http.Response> Function(http.Request) authRequest;
  late Tokens tokens;
  late Profiles profiles;
  late Map<String, DatabaseWaits> waits;
  late List<http.Request> requests;

  Future<Object> outcome<T>(Future<T> future) =>
      future.then<Object>((value) => value as Object, onError: (Object e) => e);

  Future<void> login(String id) =>
      container.read(authControllerProvider.notifier).login(id, 'password');

  setUp(() async {
    waits = {
      for (final id in ['a', 'b', 'guest']) id: DatabaseWaits(),
    };
    databases = {
      for (final id in ['a', 'b'])
        userProfileName(id): QuadrilleDatabase.forTesting(
          NativeDatabase.memory().interceptWith(waits[id]!),
        ),
      localProfileName: QuadrilleDatabase.forTesting(
        NativeDatabase.memory().interceptWith(waits['guest']!),
      ),
    };
    for (final database in databases.values) {
      await SettingsRepository(database).read();
    }
    tokens = Tokens();
    profiles = Profiles();
    requests = [];
    syncRequest = (_) async => response({'exists': false, 'revision': 0});
    authRequest = (request) async {
      if (request.url.path == '/auth/me') return response({'user': user('a')});
      if (request.url.path == '/auth/login' ||
          request.url.path == '/auth/register') {
        final id = (jsonDecode(request.body) as Map)['email'] as String;
        return response({'user': user(id), 'token': 'token-$id'});
      }
      return response({});
    };
    container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(tokens),
        profileStoreProvider.overrideWithValue(profiles),
        adoptionBackupServiceProvider.overrideWith(
          (ref, profile) => BackupService(databases[profile]!),
        ),
        databaseProvider.overrideWith(
          (ref) => databases[ref.watch(currentProfileProvider)]!,
        ),
        authApiProvider.overrideWithValue(
          AuthApi(
            baseUrl: 'https://example.com',
            client: MockClient((request) async {
              if (request.url.path.startsWith('/auth/')) {
                return authRequest(request);
              }
              requests.add(request);
              return syncRequest(request);
            }),
          ),
        ),
      ],
    );
    await container.read(authControllerProvider.future);
  });

  tearDown(() async {
    container.dispose();
    for (final db in databases.values) {
      await db.close();
    }
  });

  test(
    'superseded guest adoption preserves guest rows for the next account',
    () async {
      await container.read(authControllerProvider.notifier).logout();
      await ExerciseRepository(
        databases[localProfileName]!,
      ).create(name: 'Guest lift');
      final gate = PendingCall();
      waits['guest']!.committing = gate;
      final obsolete = outcome(login('a').then((_) => true));
      await gate.entered.future;
      final latest = login('b');
      gate.completion.complete();
      expect(await obsolete, isA<AuthException>());
      await latest;
      final preservedNames = <String>[];
      for (final database in databases.values) {
        preservedNames.addAll(
          (await ExerciseRepository(
            database,
          ).watchAll().first).map((row) => row.name),
        );
      }
      expect(preservedNames, contains('Guest lift'));
    },
  );
}
