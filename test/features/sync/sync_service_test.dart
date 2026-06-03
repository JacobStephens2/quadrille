import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/features/backup/data/backup_service.dart';
import 'package:quadrille/features/exercises/data/exercise_repository.dart';
import 'package:quadrille/features/sync/data/sync_service.dart';

void main() {
  const endpoint = 'https://quadrille.app/api';
  const token = 'secret-token';

  test('upload PUTs the backup payload with bearer auth', () async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await ExerciseRepository(db).create(name: 'Bench Press');

    late http.Request captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response('{"revision": 5}', 200);
    });
    final sync = SyncService(BackupService(db), client: client);

    final revision =
        await sync.upload(endpoint: endpoint, token: token, now: DateTime(2026));

    expect(revision, 5);
    expect(captured.method, 'PUT');
    expect(captured.url.toString(), 'https://quadrille.app/api/v1/state');
    expect(captured.headers['Authorization'], 'Bearer $token');
    final sent = jsonDecode(captured.body) as Map<String, dynamic>;
    final payload = sent['payload'] as Map<String, dynamic>;
    expect(payload['format'], 'quadrille.backup');
    expect(payload['version'], 2);
    final tables = payload['tables'] as Map<String, dynamic>;
    expect((tables['exercises'] as List), hasLength(1));
  });

  test('fetchState + applyPayload imports the cloud data locally', () async {
    // Produce a real payload from one db...
    final source = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    await ExerciseRepository(source).create(name: 'Back Squat');
    final payload =
        jsonDecode(await BackupService(source).exportJson(now: DateTime(2026)));
    await source.close();

    // ...and import it into a fresh one.
    final target = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(target.close);
    final client = MockClient((req) async {
      expect(req.method, 'GET');
      return http.Response(
        jsonEncode({'exists': true, 'revision': 2, 'payload': payload}),
        200,
      );
    });
    final sync = SyncService(BackupService(target), client: client);

    final remote = await sync.fetchState(endpoint: endpoint, token: token);
    expect(remote.exists, isTrue);
    expect(remote.revision, 2);
    await sync.applyPayload(remote.payload!);
    final names =
        (await ExerciseRepository(target).watchAll().first).map((e) => e.name);
    expect(names, ['Back Squat']);
  });

  test('fetchState reports an empty cloud', () async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final client = MockClient((req) async =>
        http.Response('{"exists": false, "revision": 0, "payload": null}', 200));
    final sync = SyncService(BackupService(db), client: client);
    final remote = await sync.fetchState(endpoint: endpoint, token: token);
    expect(remote.exists, isFalse);
  });

  test('401 surfaces a friendly SyncException', () async {
    final db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final client = MockClient((req) async => http.Response('nope', 401));
    final sync = SyncService(BackupService(db), client: client);
    expect(
      () => sync.upload(endpoint: endpoint, token: token, now: DateTime(2026)),
      throwsA(isA<SyncException>()),
    );
  });
}
