import 'web_push_service.dart';

WebPushService createWebPushService() => _NoopWebPushService();

class _NoopWebPushService implements WebPushService {
  @override
  Future<void> scheduleRest({
    required String endpoint,
    required String token,
    required DateTime endsAt,
    required String title,
    required String body,
  }) async {}

  @override
  Future<void> cancel({required String endpoint, required String token}) async {}
}
