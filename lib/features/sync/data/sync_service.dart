import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../backup/data/backup_service.dart';

/// Whole-database cloud sync against the self-hosted backend.
///
/// Last-write-wins: [upload] pushes the full backup payload (bumping the server
/// revision); [download] pulls it and replaces local data. The user drives the
/// direction explicitly, so there's no silent overwrite.
class SyncService {
  SyncService(this._backup, {http.Client? client})
      : _client = client ?? http.Client();

  final BackupService _backup;
  final http.Client _client;

  Uri _stateUri(String endpoint) {
    final base = endpoint.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/v1/state');
  }

  Map<String, String> _authHeaders(String token) => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  /// Pushes the current database to the cloud; returns the new server revision.
  Future<int> upload({
    required String endpoint,
    required String token,
    required DateTime now,
  }) async {
    final payload =
        jsonDecode(await _backup.exportJson(now: now)) as Map<String, dynamic>;
    final resp = await _send(() => _client.put(
          _stateUri(endpoint),
          headers: _authHeaders(token),
          body: jsonEncode({'payload': payload}),
        ));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['revision'] as num).toInt();
  }

  /// Reads the cloud state (revision + payload) without importing — lets the
  /// caller decide whether to apply it.
  Future<RemoteState> fetchState({
    required String endpoint,
    required String token,
  }) async {
    final resp = await _send(() => _client.get(
          _stateUri(endpoint),
          headers: _authHeaders(token),
        ));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final exists = body['exists'] == true && body['payload'] != null;
    return RemoteState(
      exists: exists,
      revision: (body['revision'] as num?)?.toInt() ?? 0,
      payload: exists ? body['payload'] as Map<String, dynamic> : null,
    );
  }

  /// Replaces local data with a fetched payload.
  Future<ImportSummary> applyPayload(Map<String, dynamic> payload) {
    return _backup.importJson(jsonEncode(payload));
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    final http.Response resp;
    try {
      resp = await request();
    } catch (e) {
      throw const SyncException('Could not reach the sync server.');
    }
    if (resp.statusCode == 401) {
      throw const SyncException('Invalid sync token.');
    }
    if (resp.statusCode != 200) {
      throw SyncException('Sync failed (HTTP ${resp.statusCode}).');
    }
    return resp;
  }
}

/// A snapshot of the cloud state.
class RemoteState {
  const RemoteState({
    required this.exists,
    required this.revision,
    this.payload,
  });

  final bool exists;
  final int revision;
  final Map<String, dynamic>? payload;
}

class SyncException implements Exception {
  const SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}
