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
import 'package:flutter/material.dart';
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
import 'package:quadrille/features/exercises/data/exercise_repository.dart';
import 'package:quadrille/features/settings/data/settings_repository.dart';
import 'package:quadrille/features/settings/presentation/settings_screen.dart';
import 'package:quadrille/features/sync/sync_coordinator.dart';

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
  late SyncCoordinator sync;
  late Future<http.Response> Function(http.Request) syncRequest;
  late Future<http.Response> Function(http.Request) authRequest;
  late Tokens tokens;
  late Profiles profiles;
  late Map<String, DatabaseWaits> waits;
  late List<http.Request> requests;

  QuadrilleDatabase db(String id) => databases[userProfileName(id)]!;
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
    sync = container.read(syncCoordinatorProvider);
  });

  tearDown(() async {
    container.dispose();
    for (final db in databases.values) {
      await db.close();
    }
  });

  test('a delayed A download leaves replacement profile B unchanged', () async {
    final source = databases[userProfileName('a')]!;
    await ExerciseRepository(source).create(name: 'Account A workout data');
    final payload = await BackupService(source).exportSyncPayload();
    final entered = Completer<void>();
    final remote = Completer<http.Response>();
    syncRequest = (_) {
      entered.complete();
      return remote.future;
    };
    final download = sync.downloadNow();
    // Attach the rejection handler before releasing the remote response.
    final result = download.then<Object>(
      (value) => value,
      onError: (Object e) => e,
    );
    await entered.future;
    await container
        .read(authControllerProvider.notifier)
        .login('b', 'password');
    remote.complete(
      response({'exists': true, 'revision': 42, 'payload': payload}),
    );
    expect(await result, isA<SyncSuperseded>());

    final target = databases[userProfileName('b')]!;
    expect(await ExerciseRepository(target).watchAll().first, isEmpty);
    expect((await SettingsRepository(target).read()).lastSyncedRevision, 0);
  });

  test(
    'login closes eligibility before its request and throughout profile adoption',
    () async {
      final transport = PendingCall();
      final storage = PendingCall();
      final defaultAuth = authRequest;
      authRequest = (request) async {
        await transport.wait();
        return defaultAuth(request);
      };
      profiles.writing = storage;
      final signingIn = login('b');
      await expectLater(sync.uploadNow(), throwsA(isA<AuthException>()));
      await transport.entered.future;
      transport.completion.complete();
      await storage.entered.future;
      expect(tokens.token, 'token-b');
      expect(container.read(currentProfileProvider), userProfileName('a'));
      await expectLater(sync.downloadNow(), throwsA(isA<AuthException>()));
      storage.completion.complete();
      await signingIn;
      syncRequest = (_) async => response({'revision': 7});
      expect(await sync.uploadNow(), 7);
      expect(requests.single.headers['Authorization'], 'Bearer token-b');
      expect(requests.single.headers['X-Quadrille-Expected-Account'], 'b');
    },
  );

  for (final transition in [
    'guest',
    'b-a',
    'profile-b-a',
    'database',
    'dispose',
  ]) {
    test('a delayed download stays obsolete after $transition', () async {
      final entered = Completer<void>();
      final remote = Completer<http.Response>();
      syncRequest = (_) {
        entered.complete();
        return remote.future;
      };
      final pending = outcome(sync.downloadNow());
      await entered.future;
      switch (transition) {
        case 'guest':
          await container.read(authControllerProvider.notifier).logout();
        case 'b-a':
          await login('b');
          await login('a');
        case 'profile-b-a':
          container
              .read(currentProfileProvider.notifier)
              .set(userProfileName('b'));
          container
              .read(currentProfileProvider.notifier)
              .set(userProfileName('a'));
        case 'database':
          final replacement = QuadrilleDatabase.forTesting(
            NativeDatabase.memory(),
          );
          final original = db('a');
          databases[userProfileName('a')] = replacement;
          addTearDown(original.close);
          container.invalidate(databaseProvider);
        case 'dispose':
          container.invalidate(syncCoordinatorProvider);
      }
      remote.complete(response({'exists': false, 'revision': 0}));
      expect(await pending, isA<SyncSuperseded>());
      expect((await SettingsRepository(db('a')).read()).lastSyncedRevision, 0);
      expect((await SettingsRepository(db('b')).read()).lastSyncedRevision, 0);
    });
  }

  test(
    'commands retain invocation order and the final committed revision',
    () async {
      final first = Completer<http.Response>();
      final entered = Completer<void>();
      syncRequest = (request) async {
        if (requests.length == 1) {
          entered.complete();
          return first.future;
        }
        expect(
          (await SettingsRepository(db('a')).read()).lastSyncedRevision,
          11,
        );
        return response({'revision': 12});
      };
      final downloading = sync.downloadNow();
      await entered.future;
      final uploading = sync.uploadNow();
      await pumpEventQueue();
      expect(requests.map((r) => r.method), ['GET']);
      first.complete(
        response({
          'exists': true,
          'revision': 11,
          'payload': {'tables': {}},
        }),
      );
      expect(await downloading, isTrue);
      expect(await uploading, 12);
      expect(requests.map((r) => r.method), ['GET', 'PUT']);
      expect((await SettingsRepository(db('a')).read()).lastSyncedRevision, 12);
    },
  );

  test('a failed predecessor releases the next command', () async {
    final first = Completer<http.Response>();
    final entered = Completer<void>();
    syncRequest = (_) {
      if (requests.length == 1) {
        entered.complete();
        return first.future;
      }
      return Future.value(response({'revision': 8}));
    };
    final failing = outcome(sync.downloadNow());
    await entered.future;
    final next = sync.uploadNow();
    first.complete(http.Response('{"detail":"Try later"}', 503));
    expect(
      await failing,
      isA<AuthException>().having((e) => e.message, 'message', 'Try later'),
    );
    expect(await next, 8);
  });

  test(
    'a new owner progresses while old requests and queued work are stalled',
    () async {
      final first = Completer<http.Response>();
      final entered = Completer<void>();
      syncRequest = (request) {
        if (request.headers['X-Quadrille-Expected-Account'] == 'a') {
          entered.complete();
          return first.future;
        }
        return Future.value(response({'revision': 9}));
      };
      final old = outcome(sync.downloadNow());
      await entered.future;
      final queued = outcome(sync.uploadNow());
      await login('b');
      try {
        expect(await sync.uploadNow().timeout(const Duration(seconds: 2)), 9);
      } finally {
        first.complete(http.Response('{"detail":"Old account failure"}', 401));
      }
      expect(await old, isA<SyncSuperseded>());
      expect(await queued, isA<SyncSuperseded>());
      expect(requests.map((r) => r.headers['X-Quadrille-Expected-Account']), [
        'a',
        'b',
      ]);
      expect((await SettingsRepository(db('b')).read()).lastSyncedRevision, 9);
    },
  );

  test(
    'a delayed upload exports A rows and cannot record a revision in B',
    () async {
      await ExerciseRepository(db('a')).create(name: 'A lift');
      await ExerciseRepository(db('b')).create(name: 'B lift');
      final entered = Completer<void>();
      final remote = Completer<http.Response>();
      syncRequest = (_) {
        entered.complete();
        return remote.future;
      };
      final pending = outcome(sync.uploadNow());
      await entered.future;
      await login('b');
      remote.complete(response({'revision': 42}));
      expect(await pending, isA<SyncSuperseded>());
      final uploaded = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(
        (uploaded['payload']['tables']['exercises'] as List).map(
          (r) => (r as Map)['name'],
        ),
        ['A lift'],
      );
      expect(requests.single.headers['Authorization'], 'Bearer token-a');
      expect((await SettingsRepository(db('b')).read()).lastSyncedRevision, 0);
    },
  );

  test('a switch during export stops submission', () async {
    final gate = PendingCall();
    waits['a']!
      ..table = 'exercises'
      ..selecting = gate;
    final pending = outcome(sync.uploadNow());
    await gate.entered.future;
    await login('b');
    gate.completion.complete();
    expect(await pending, isA<SyncSuperseded>());
    expect(requests, isEmpty);
  });

  test(
    'a switch during merge allows only the original transaction to finish',
    () async {
      await ExerciseRepository(db('b')).create(name: 'Cloud lift');
      final payload = await BackupService(db('b')).exportSyncPayload();
      final gate = PendingCall();
      waits['a']!.committing = gate;
      syncRequest = (_) async =>
          response({'exists': true, 'revision': 42, 'payload': payload});
      final pending = outcome(sync.downloadNow());
      await gate.entered.future;
      await login('b');
      gate.completion.complete();
      expect(await pending, isA<SyncSuperseded>());
      expect(
        (await ExerciseRepository(db('a')).watchAll().first).single.name,
        'Cloud lift',
      );
      expect((await SettingsRepository(db('a')).read()).lastSyncedRevision, 0);
      expect((await SettingsRepository(db('b')).read()).lastSyncedRevision, 0);
    },
  );

  test(
    'sign-in groups pull merge push ahead of the next manual command',
    () async {
      await ExerciseRepository(db('a')).create(name: 'Local lift');
      await ExerciseRepository(db('b')).create(name: 'Remote lift');
      final payload = await BackupService(db('b')).exportSyncPayload();
      await SettingsRepository(db('a')).update(autoSync: false);
      final entered = Completer<void>();
      final remote = Completer<http.Response>();
      syncRequest = (request) async {
        if (requests.length == 1) {
          entered.complete();
          return remote.future;
        }
        return request.method == 'PUT'
            ? response({'revision': 5})
            : response({'exists': false, 'revision': 0});
      };
      final signingIn = sync.onSignIn();
      await entered.future;
      final manual = sync.downloadNow();
      remote.complete(
        response({'exists': true, 'revision': 4, 'payload': payload}),
      );
      await signingIn;
      expect(await manual, isFalse);
      expect(requests.map((r) => r.method), ['GET', 'PUT', 'GET']);
      final uploaded = jsonDecode(requests[1].body) as Map<String, dynamic>;
      expect(
        (uploaded['payload']['tables']['exercises'] as List).map(
          (r) => (r as Map)['name'],
        ),
        unorderedEquals(['Local lift', 'Remote lift']),
      );
      expect(
        (uploaded['payload']['tables'] as Map).keys,
        isNot(contains('appSettings')),
      );
      expect(
        (uploaded['payload']['tables'] as Map).keys,
        isNot(contains('activeTimers')),
      );
      expect((await SettingsRepository(db('a')).read()).autoSync, isFalse);
    },
  );

  test(
    'sign-in uploads to an empty cloud but stops after a failed pull',
    () async {
      syncRequest = (request) async => request.method == 'GET'
          ? response({'exists': false, 'revision': 0})
          : response({'revision': 1});
      await sync.onSignIn();
      expect(requests.map((r) => r.method), ['GET', 'PUT']);
      requests.clear();
      syncRequest = (_) async => http.Response('{"detail":"Offline"}', 503);
      await sync.onSignIn();
      expect(requests.map((r) => r.method), ['GET']);
    },
  );

  test(
    'manual intents ignore Auto-sync and preserve success and empty results',
    () async {
      await SettingsRepository(db('a')).update(autoSync: false);
      syncRequest = (request) async => request.method == 'PUT'
          ? response({'revision': 17})
          : response({'exists': false, 'revision': 0});
      expect(await sync.uploadNow(), 17);
      expect(await sync.downloadNow(), isFalse);
      final settings = await SettingsRepository(db('a')).read();
      expect(settings.lastSyncedRevision, 17);
      expect(settings.lastSyncAt, isNotNull);
      expect(requests.map((r) => r.method), ['PUT', 'GET']);
    },
  );

  for (final upload in [false, true]) {
    test(
      'automatic ${upload ? 'finish push' : 'launch pull'} respects policy and contains errors',
      () async {
        Future<void> automatic() =>
            upload ? sync.pushAfterFinish() : sync.pullOnLaunch();
        await SettingsRepository(db('a')).update(autoSync: false);
        await automatic();
        expect(requests, isEmpty);
        await SettingsRepository(db('a')).update(autoSync: true);
        syncRequest = (_) async =>
            upload ? response({'revision': 3}) : response({'exists': false});
        await automatic();
        expect(requests.single.method, upload ? 'PUT' : 'GET');
        syncRequest = (_) async => throw StateError('network unavailable');
        await automatic();
        await db('a').close();
        // Even policy-read failure must remain best effort.
        await automatic();
      },
    );

    test(
      'automatic ${upload ? 'push' : 'pull'} rechecks ownership after policy read',
      () async {
        await SettingsRepository(db('a')).update(autoSync: true);
        final gate = PendingCall();
        waits['a']!
          ..table = 'app_settings'
          ..selecting = gate;
        final pending = upload ? sync.pushAfterFinish() : sync.pullOnLaunch();
        await gate.entered.future;
        await login('b');
        gate.completion.complete();
        await pending;
        expect(requests, isEmpty);
      },
    );
  }

  for (final action in ['register', 'logout', 'refresh', 'restore']) {
    test(
      '$action closes eligibility before credential or transport waits',
      () async {
        final gate = PendingCall();
        final auth = container.read(authControllerProvider.notifier);
        late Future<void> changing;
        if (action == 'register') {
          final defaultAuth = authRequest;
          authRequest = (request) async {
            await gate.wait();
            return defaultAuth(request);
          };
          changing = auth.register('b', 'password');
        } else {
          tokens.reading = gate;
          if (action == 'logout') {
            changing = auth.logout();
          } else if (action == 'refresh') {
            changing = auth.refresh();
          } else {
            container.invalidate(authControllerProvider);
            changing = container
                .read(authControllerProvider.future)
                .then((_) {});
          }
        }
        await expectLater(sync.downloadNow(), throwsA(isA<AuthException>()));
        await gate.entered.future;
        await sync.pullOnLaunch();
        await sync.pushAfterFinish();
        await sync.onSignIn();
        expect(requests, isEmpty);
        gate.completion.complete();
        await changing;
      },
    );
  }

  test('failed auth stays ineligible until a successful validation', () async {
    authRequest = (_) async =>
        http.Response('{"detail":"Bad credentials"}', 401);
    await expectLater(login('b'), throwsA(isA<AuthException>()));
    await expectLater(sync.uploadNow(), throwsA(isA<AuthException>()));
    expect(requests, isEmpty);
    authRequest = (_) async => response({'user': user('a')});
    await container.read(authControllerProvider.notifier).refresh();
    expect(await sync.downloadNow(), isFalse);
  });

  test('unverified and mismatched refreshed accounts cannot sync', () async {
    for (final account in [user('a', verified: false), user('b')]) {
      authRequest = (_) async => response({'user': account});
      await container.read(authControllerProvider.notifier).refresh();
      await expectLater(sync.uploadNow(), throwsA(isA<AuthException>()));
      await expectLater(sync.downloadNow(), throwsA(isA<AuthException>()));
      await sync.onSignIn();
    }
    expect(requests, isEmpty);
  });

  test('a late superseded login cannot replace the latest owner', () async {
    final entered = Completer<void>();
    final oldResponse = Completer<http.Response>();
    final defaultAuth = authRequest;
    authRequest = (request) {
      if ((jsonDecode(request.body) as Map)['email'] == 'a') {
        entered.complete();
        return oldResponse.future;
      }
      return defaultAuth(request);
    };
    final obsolete = outcome(login('a').then((_) => true));
    await entered.future;
    await login('b');
    oldResponse.complete(
      response({'user': user('a'), 'token': 'obsolete-token'}),
    );
    expect(await obsolete, isA<AuthException>());
    expect(await sync.downloadNow(), isFalse);
    expect(container.read(currentProfileProvider), userProfileName('b'));
    expect(tokens.token, 'token-b');
    expect(requests.single.headers['Authorization'], 'Bearer token-b');
  });

  test(
    'sync never rereads credentials after the operation owner is captured',
    () async {
      tokens.reading = PendingCall();
      // A token-store read would stall forever; the validated context owns it.
      expect(
        await sync.downloadNow().timeout(const Duration(seconds: 2)),
        isFalse,
      );
      expect(requests.single.headers['Authorization'], 'Bearer token-a');
    },
  );

  test('guest carry-over completes before sync eligibility returns', () async {
    await container.read(authControllerProvider.notifier).logout();
    await ExerciseRepository(
      databases[localProfileName]!,
    ).create(name: 'Guest lift');
    final gate = PendingCall();
    waits['a']!.committing = gate;
    final signingIn = login('a');
    await gate.entered.future;
    expect(container.read(currentProfileProvider), userProfileName('a'));
    await expectLater(sync.downloadNow(), throwsA(isA<AuthException>()));
    gate.completion.complete();
    await signingIn;
    expect(
      (await ExerciseRepository(db('a')).watchAll().first).single.name,
      'Guest lift',
    );
    expect(
      await ExerciseRepository(databases[localProfileName]!).watchAll().first,
      isEmpty,
    );
    expect(await sync.downloadNow(), isFalse);
  });

  test(
    'superseded credential adoption cannot overwrite the latest credential',
    () async {
      final gate = PendingCall();
      tokens.writing = gate;
      final old = outcome(login('a').then((_) => true));
      await gate.entered.future;
      tokens.writing = null;
      final latest = login('b');
      await expectLater(sync.uploadNow(), throwsA(isA<AuthException>()));
      gate.completion.complete();
      expect(await old, isA<AuthException>());
      await latest;
      expect(await sync.downloadNow(), isFalse);
      expect(tokens.token, 'token-b');
      expect(requests.single.headers['Authorization'], 'Bearer token-b');
    },
  );

  test('late restoration cannot undo a newer sign-in', () async {
    final entered = Completer<void>();
    final remote = Completer<http.Response>();
    final defaultAuth = authRequest;
    authRequest = (request) {
      if (request.url.path == '/auth/me') {
        entered.complete();
        return remote.future;
      }
      return defaultAuth(request);
    };
    container.invalidate(authControllerProvider);
    final restoring = container.read(authControllerProvider.future);
    await entered.future;
    await login('b');
    remote.complete(response({'user': user('a')}));
    await restoring;
    await pumpEventQueue();
    expect(container.read(authControllerProvider).value?.user?.id, 'b');
    expect(await sync.downloadNow(), isFalse);
    expect(requests.single.headers['Authorization'], 'Bearer token-b');
  });

  for (final button in ['Upload', 'Download']) {
    for (final status in [200, 401]) {
      testWidgets('$button silently handles a superseded $status response', (
        tester,
      ) async {
        final entered = Completer<void>();
        final remote = Completer<http.Response>();
        syncRequest = (_) {
          entered.complete();
          return remote.future;
        };
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );
        await tester.runAsync(() async => pumpEventQueue());
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(button));
        await tester.pumpAndSettle();
        await tester.tap(find.text(button));
        await tester.runAsync(() async {
          await entered.future;
          await login('b');
          remote.complete(
            status == 200
                ? response(
                    button == 'Upload' ? {'revision': 42} : {'exists': false},
                  )
                : http.Response('{"detail":"Old account error"}', 401),
          );
          await pumpEventQueue();
        });
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Settings keeps current account errors visible', (tester) async {
    syncRequest = (_) async =>
        http.Response('{"detail":"Verify your email"}', 403);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.runAsync(() async => pumpEventQueue());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Upload'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upload'));
    await tester.runAsync(() async => pumpEventQueue());
    await tester.pumpAndSettle();
    expect(find.text('Verify your email'), findsOneWidget);
  });
}
