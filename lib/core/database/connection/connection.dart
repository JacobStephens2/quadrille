// Resolves the right `openConnection` implementation per platform via
// conditional imports, so `dart:io` (FFI) never reaches the web build and
// the WASM backend never reaches native builds.
export 'unsupported.dart'
    if (dart.library.io) 'native.dart'
    if (dart.library.js_interop) 'web.dart';
