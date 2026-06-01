import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'web_push_service.dart';

final webPushServiceProvider = Provider<WebPushService>((ref) {
  return createWebPushService();
});
