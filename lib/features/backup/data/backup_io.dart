// Platform file helpers for backup: download a generated file and pick one to
// import. Web has real implementations; other platforms fall back to the
// clipboard / paste flow in the UI.
export 'backup_io_stub.dart' if (dart.library.js_interop) 'backup_io_web.dart';
