import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/notifications/notification_service_mobile.dart'
    as mobile;
import 'package:quadrille/core/notifications/notification_service_stub.dart'
    as noop_notifications;
import 'package:quadrille/features/watch/watch_service_io.dart' as watch;
import 'package:quadrille/features/watch/watch_service_stub.dart' as noop_watch;
import 'package:quadrille/features/watch/watch_snapshot.dart';

class _NativeCall {
  final entered = Completer<void>();
  final completion = Completer<void>();

  Future<void> wait() {
    entered.complete();
    return completion.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const notificationChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  const watchChannel = MethodChannel('app.quadrille/watch');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(AndroidFlutterLocalNotificationsPlugin.registerWith);

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(notificationChannel, null);
    messenger.setMockMethodCallHandler(watchChannel, null);
  });

  for (final immediate in [false, true]) {
    test(
      'mobile ${immediate ? 'immediate' : 'scheduled'} alert awaits initialization, cancellation and delivery submission',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final calls = <String>[];
        final init = _NativeCall();
        final cancel = _NativeCall();
        final delivery = _NativeCall();
        messenger.setMockMethodCallHandler(notificationChannel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'initialize':
              await init.wait();
              return true;
            case 'cancel':
              await cancel.wait();
            case 'zonedSchedule':
            case 'show':
              await delivery.wait();
          }
          return null;
        });
        var complete = false;
        final operation = mobile
            .createNotificationService()
            .scheduleRestComplete(
              endsAt: immediate ? DateTime(2000) : DateTime(2100),
              title: 'Rest complete',
              body: 'Next: Bench',
            )
            .then((_) => complete = true);
        await init.entered.future;
        expect(complete, isFalse);
        expect(calls, ['initialize']);
        init.completion.complete();
        await cancel.entered.future;
        expect(complete, isFalse);
        expect(calls, ['initialize', 'cancel']);
        cancel.completion.complete();
        await delivery.entered.future;
        expect(complete, isFalse);
        expect(calls, [
          'initialize',
          'cancel',
          immediate ? 'show' : 'zonedSchedule',
        ]);
        delivery.completion.complete();
        await operation;
        expect(complete, isTrue);
      },
    );
  }

  test(
    'mobile cancellation awaits initialization and native cancellation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final init = _NativeCall();
      final cancel = _NativeCall();
      messenger.setMockMethodCallHandler(notificationChannel, (call) async {
        if (call.method == 'initialize') {
          await init.wait();
          return true;
        }
        if (call.method == 'cancel') await cancel.wait();
        return null;
      });
      var complete = false;
      final operation = mobile.createNotificationService().cancel().then(
        (_) => complete = true,
      );
      await init.entered.future;
      expect(cancel.entered.isCompleted, isFalse);
      expect(complete, isFalse);
      init.completion.complete();
      await cancel.entered.future;
      expect(complete, isFalse);
      cancel.completion.complete();
      await operation;
      expect(complete, isTrue);
    },
  );

  for (final method in ['initialize', 'cancel', 'zonedSchedule', 'show']) {
    test('mobile $method failure reaches the scheduling caller', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(notificationChannel, (call) async {
        if (call.method == method) {
          throw PlatformException(code: 'native-failure');
        }
        return call.method == 'initialize' ? true : null;
      });
      await expectLater(
        mobile.createNotificationService().scheduleRestComplete(
          endsAt: method == 'show' ? DateTime(2000) : DateTime(2100),
          title: 'Rest complete',
          body: 'Next: Bench',
        ),
        throwsA(isA<PlatformException>()),
      );
    });
  }

  for (final clearing in [false, true]) {
    test(
      'watch ${clearing ? 'clear' : 'snapshot'} awaits native submission and keeps best-effort failures',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final native = _NativeCall();
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(watchChannel, (call) async {
          calls.add(call);
          await native.wait();
          throw PlatformException(code: 'watch-unavailable');
        });
        const snapshot = WatchSnapshot(
          exerciseName: 'Bench',
          restEndsAtMillis: 12345,
        );
        final service = watch.createWatchService();
        var complete = false;
        final operation =
            (clearing ? service.clear() : service.updateSnapshot(snapshot))
                .then((_) => complete = true);
        await native.entered.future;
        expect(complete, isFalse);
        expect(calls.single.method, clearing ? 'clear' : 'updateSnapshot');
        expect(calls.single.arguments, clearing ? isNull : snapshot.toMap());
        native.completion.complete();
        await operation;
        expect(complete, isTrue);
      },
    );
  }

  test(
    'no-op adapters and a missing watch bridge return settled Futures',
    () async {
      await noop_notifications.createNotificationService().cancel();
      await noop_notifications.createNotificationService().scheduleRestComplete(
        endsAt: DateTime(2100),
        title: 'Rest complete',
        body: 'Next: Bench',
      );
      const snapshot = WatchSnapshot(
        exerciseName: 'Bench',
        restEndsAtMillis: 12345,
      );
      await noop_watch.createWatchService().updateSnapshot(snapshot);
      await noop_watch.createWatchService().clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await watch.createWatchService().updateSnapshot(snapshot);
      await watch.createWatchService().clear();
    },
  );
}
