import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
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
import 'package:quadrille/features/exercises/data/exercise_repository.dart';
import 'package:quadrille/features/backup/backup_providers.dart';
import 'package:quadrille/features/backup/data/backup_service.dart';

class AdoptionTokens extends TokenStore {
  final firstWriteEntered = Completer<void>();
  final releaseFirstWrite = Completer<void>();
  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String value) async {
    if (value == 'token-a') {
      firstWriteEntered.complete();
      await releaseFirstWrite.future;
    }
    token = value;
  }
}

class AdoptionProfiles extends ProfileStore {
  @override
  Future<void> write(String profileName) async {}
}

void main() {
  test('superseding guest adoption preserves the guest workout', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final databases = {
      for (final profile in [
        localProfileName,
        userProfileName('a'),
        userProfileName('b'),
      ])
        profile: QuadrilleDatabase.forTesting(NativeDatabase.memory()),
    };
    final tokens = AdoptionTokens();
    final container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(tokens),
        profileStoreProvider.overrideWithValue(AdoptionProfiles()),
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
              if (request.url.path == '/auth/me') {
                return http.Response('{}', 401);
              }
              final id = (jsonDecode(request.body) as Map)['email'];
              return http.Response(
                jsonEncode({
                  'user': {
                    'id': id,
                    'email': '$id@example.com',
                    'emailVerified': true,
                  },
                  'token': 'token-$id',
                }),
                200,
              );
            }),
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      for (final database in databases.values) {
        await database.close();
      }
    });
    await container.read(authControllerProvider.future);
    await ExerciseRepository(
      databases[localProfileName]!,
    ).create(name: 'Guest workout');
    final auth = container.read(authControllerProvider.notifier);
    final first = auth
        .login('a', 'password')
        .then<Object?>((_) => null, onError: (Object e) => e);
    await tokens.firstWriteEntered.future;
    final second = auth.login('b', 'password');
    tokens.releaseFirstWrite.complete();
    expect(await first, isA<AuthException>());
    await second;
    final preservedNames = <String>[];
    for (final database in databases.values) {
      preservedNames.addAll(
        (await ExerciseRepository(
          database,
        ).watchAll().first).map((row) => row.name),
      );
    }
    expect(preservedNames, contains('Guest workout'));
  });
}
