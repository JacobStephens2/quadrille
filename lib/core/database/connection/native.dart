import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Opens the on-device SQLite file (iOS/Android/desktop) via FFI.
///
/// Uses [LazyDatabase] so the (async) path lookup and file open are deferred
/// until the first query, and `createInBackground` so the SQLite work runs off
/// the UI isolate.
QueryExecutor openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'quadrille.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
