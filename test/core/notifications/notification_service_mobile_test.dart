import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/notifications/notification_service_mobile.dart'
    as mobile;

class _MethodGate {
  final entered = Completer<void>();
  final completion = Completer<void>();

  Future<void> wait() {
    if (!entered.isCompleted) entered.complete();
    return completion.future;
  }
}

class _NotificationChannelHarness {
  static const _channel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );

  final calls = <MethodCall>[];
  final _gates = <String, _MethodGate>{};

  void attach() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  void detach() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }

  _MethodGate pauseNext(String method) {
    final gate = _MethodGate();
    _gates[method] = gate;
    return gate;
  }

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final gate = _gates.remove(call.method);
    if (gate != null) await gate.wait();
    return call.method == 'initialize' ? true : null;
  }
}

Future<void> _expectSuperseded(
  _NotificationChannelHarness channel, {
  required String boundary,
  required Future<void> Function() runStale,
  required Future<void> Function() supersede,
}) async {
  final gate = channel.pauseNext(boundary);
  final stale = runStale();
  await gate.entered.future;

  await supersede();
  channel.calls.clear();

  gate.completion.complete();
  await stale;

  expect(channel.calls, isEmpty);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _NotificationChannelHarness channel;

  setUp(() {
    channel = _NotificationChannelHarness()..attach();
  });

  tearDown(() {
    channel.detach();
  });

  for (final immediate in [false, true]) {
    for (final boundary in ['initialize', 'cancel']) {
      test(
        '${immediate ? 'immediate' : 'scheduled'} scheduleRestComplete superseded during $boundary skips subsequent platform work',
        () async {
          final service = mobile.createNotificationService();
          await _expectSuperseded(
            channel,
            boundary: boundary,
            runStale: () => service.scheduleRestComplete(
              endsAt: immediate ? DateTime(2000) : DateTime(2100),
              title: 'Rest complete',
              body: 'Next: Stale',
            ),
            supersede: () => service.scheduleRestComplete(
              endsAt: DateTime(2100),
              title: 'Rest complete',
              body: 'Next: Current',
            ),
          );
        },
      );
    }
  }

  for (final stillOwnedNull in [true, false]) {
    final ownedLabel = stillOwnedNull
        ? 'omitted stillOwned'
        : 'stillOwned true';
    bool Function()? ownedCallback() => stillOwnedNull ? null : () => true;

    for (final boundary in ['initialize', 'cancel']) {
      test(
        'scheduleRestComplete superseded by cancel ($ownedLabel) during $boundary skips subsequent platform work',
        () async {
          final service = mobile.createNotificationService();
          await _expectSuperseded(
            channel,
            boundary: boundary,
            runStale: () => service.scheduleRestComplete(
              endsAt: DateTime(2100),
              title: 'Rest complete',
              body: 'Next: Stale',
            ),
            supersede: () => service.cancel(stillOwned: ownedCallback()),
          );
        },
      );
    }

    test(
      'cancel ($ownedLabel) superseded during initialize by scheduleRestComplete skips plugin cancel',
      () async {
        final service = mobile.createNotificationService();
        await _expectSuperseded(
          channel,
          boundary: 'initialize',
          runStale: () => service.cancel(stillOwned: ownedCallback()),
          supersede: () => service.scheduleRestComplete(
            endsAt: DateTime(2100),
            title: 'Rest complete',
            body: 'Next: Current',
          ),
        );
      },
    );

    test(
      'cancel ($ownedLabel) superseded during initialize by cancel skips plugin cancel',
      () async {
        final service = mobile.createNotificationService();
        await _expectSuperseded(
          channel,
          boundary: 'initialize',
          runStale: () => service.cancel(stillOwned: ownedCallback()),
          supersede: () => service.cancel(stillOwned: ownedCallback()),
        );
      },
    );
  }

  for (final boundary in ['initialize', 'cancel']) {
    test(
      'cancel with stillOwned false does not initialize, cancel, or supersede in-flight scheduleRestComplete at $boundary',
      () async {
        final service = mobile.createNotificationService();
        final gate = channel.pauseNext(boundary);

        final active = service.scheduleRestComplete(
          endsAt: DateTime(2100),
          title: 'Rest complete',
          body: 'Next: Active',
        );
        await gate.entered.future;
        final callsBefore = channel.calls.length;

        await service.cancel(stillOwned: () => false);
        expect(channel.calls, hasLength(callsBefore));

        gate.completion.complete();
        await active;

        expect(channel.calls.map((c) => c.method), [
          'initialize',
          'cancel',
          'zonedSchedule',
        ]);
      },
    );
  }

  test(
    'cancel with stillOwned false does not supersede an in-flight cancel',
    () async {
      final service = mobile.createNotificationService();
      final gate = channel.pauseNext('initialize');

      final active = service.cancel(stillOwned: () => true);
      await gate.entered.future;
      final callsBefore = channel.calls.length;

      await service.cancel(stillOwned: () => false);
      expect(channel.calls, hasLength(callsBefore));

      gate.completion.complete();
      await active;

      expect(channel.calls.map((c) => c.method), ['initialize', 'cancel']);
    },
  );

  test(
    'cancel returns early after initialization when stillOwned becomes false',
    () async {
      final service = mobile.createNotificationService();
      final initGate = channel.pauseNext('initialize');
      var owned = true;

      final cancelling = service.cancel(stillOwned: () => owned);
      await initGate.entered.future;

      owned = false;
      initGate.completion.complete();
      await cancelling;

      expect(channel.calls.map((c) => c.method), ['initialize']);
    },
  );
}
