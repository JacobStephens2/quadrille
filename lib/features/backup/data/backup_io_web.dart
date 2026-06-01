import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

bool get supportsFileDownload => true;

/// Triggers a browser download of [content] as [filename].
Future<void> downloadText(String filename, String content) async {
  final blob = web.Blob(
    [content.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  anchor.click();
  web.URL.revokeObjectURL(url);
}

/// Opens a file picker and returns the chosen file's text, or null if
/// cancelled.
Future<String?> pickTextFile() {
  final completer = Completer<String?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.json,application/json';
  input.onchange = (web.Event _) {
    final files = input.files;
    if (files == null || files.length == 0) {
      completer.complete(null);
      return;
    }
    final reader = web.FileReader();
    reader.onload = (web.Event _) {
      final result = reader.result;
      completer.complete(result.isA<JSString>() ? (result as JSString).toDart : null);
    }.toJS;
    reader.onerror = (web.Event _) {
      completer.complete(null);
    }.toJS;
    reader.readAsText(files.item(0)!);
  }.toJS;
  input.click();
  return completer.future;
}
