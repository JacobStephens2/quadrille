import 'package:drift/drift.dart';

/// Fallback for platforms with neither `dart:io` nor a JS interop runtime.
/// Quadrille only targets web/iOS/Android, so this should never be selected.
QueryExecutor openConnection(String name) {
  throw UnsupportedError(
    'No database backend available for this platform.',
  );
}
