import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:flutter/foundation.dart';

/// Opens the browser SQLite database backed by `sqlite3.wasm` running in a
/// drift web worker, persisting through OPFS/IndexedDB.
///
/// Requires two assets served from `web/`: `sqlite3.wasm` and `drift_worker.js`
/// (fetched by `tool/fetch_web_db_assets.sh`).
QueryExecutor openConnection(String name) {
  return LazyDatabase(() async {
    final result = await WasmDatabase.open(
      databaseName: name,
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.js'),
    );
    if (result.missingFeatures.isNotEmpty) {
      // OPFS unavailable (e.g. no cross-origin isolation) → falls back to a
      // less durable store. Surface it during development.
      debugPrint('Drift web missing features: ${result.missingFeatures}');
    }
    return result.resolvedExecutor;
  });
}
