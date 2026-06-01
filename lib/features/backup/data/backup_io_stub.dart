/// Non-web fallback: no browser file APIs. The Settings UI uses the clipboard
/// (export) and a paste dialog (import) on these platforms.
bool get supportsFileDownload => false;

Future<void> downloadText(String filename, String content) async {
  throw UnsupportedError('File download is only available on web.');
}

Future<String?> pickTextFile() async => null;
