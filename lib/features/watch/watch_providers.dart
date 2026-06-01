import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'watch_service.dart';

final watchServiceProvider = Provider<WatchService>((ref) {
  return createWatchService();
});
