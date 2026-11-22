import 'dart:async';

import 'package:drift/drift.dart' show QueryExecutor, QueryInterceptor;
import 'package:quadrille/core/notifications/notification_service.dart';
import 'package:quadrille/features/push/web_push_service.dart';
import 'package:quadrille/features/watch/watch_service.dart';
import 'package:quadrille/features/watch/watch_snapshot.dart';

typedef RestAlertRecord = ({DateTime endsAt, String title, String body});

class PendingCall {
  final entered = Completer<void>();
  final completion = Completer<void>();

  Future<void> wait() {
    if (!entered.isCompleted) entered.complete();
    return completion.future;
  }
}

class SettingsSelectGate extends QueryInterceptor {
  PendingCall? pending;
  int skip = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('app_settings') && pending != null) {
      if (skip > 0) {
        skip--;
      } else {
        final gate = pending!;
        pending = null;
        await gate.wait();
      }
    }
    return executor.runSelect(statement, args);
  }
}

class RecordingNotifications implements NotificationService {
  PendingCall? permission;
  PendingCall? scheduling;
  PendingCall? cancelling;
  RestAlertRecord? slot;
  final scheduled = <RestAlertRecord>[];
  int cancellations = 0;
  String? profileAtCancel;
  String Function()? readProfile;
  void Function(String)? recordEvent;

  @override
  Future<bool> ensurePermission() async {
    await permission?.wait();
    return true;
  }

  @override
  Future<void> scheduleRestComplete({
    required DateTime endsAt,
    required String title,
    required String body,
    bool voiceCuesEnabled = false,
  }) async {
    await scheduling?.wait();
    final record = (endsAt: endsAt, title: title, body: body);
    scheduled.add(record);
    slot = record;
  }

  @override
  Future<void> cancel({bool Function()? stillOwned}) async {
    await cancelling?.wait();
    if (stillOwned != null && !stillOwned()) return;
    cancellations++;
    profileAtCancel = readProfile?.call();
    recordEvent?.call('notifications.cancel');
    slot = null;
  }
}

class RecordingWatch implements WatchService {
  PendingCall? updating;
  PendingCall? clearing;
  final snapshots = <WatchSnapshot>[];
  int clears = 0;
  String? profileAtClear;
  String Function()? readProfile;
  void Function(String)? recordEvent;

  @override
  Future<void> updateSnapshot(WatchSnapshot snapshot) async {
    await updating?.wait();
    snapshots.add(snapshot);
  }

  @override
  Future<void> clear() async {
    await clearing?.wait();
    clears++;
    profileAtClear = readProfile?.call();
    recordEvent?.call('watch.clear');
  }
}

class RecordingPush implements WebPushService {
  PendingCall? scheduling;
  PendingCall? cancelling;
  final scheduled = <RestAlertRecord>[];
  int cancellations = 0;
  int removals = 0;
  String? profileAtCancel;
  String? sessionAtCancel;
  String? profileAtRemove;
  String? sessionAtRemove;
  String Function()? readProfile;
  String? Function()? readSession;
  void Function(String)? recordEvent;

  @override
  Future<void> scheduleRest({
    required String endpoint,
    required DateTime endsAt,
    required String title,
    required String body,
    bool Function()? stillOwned,
  }) async {
    if (stillOwned != null && !stillOwned()) return;
    await scheduling?.wait();
    if (stillOwned != null && !stillOwned()) return;
    scheduled.add((endsAt: endsAt, title: title, body: body));
  }

  @override
  Future<void> cancel({required String endpoint}) async {
    await cancelling?.wait();
    cancellations++;
    profileAtCancel = readProfile?.call();
    sessionAtCancel = readSession?.call();
    recordEvent?.call('push.cancel');
  }

  @override
  Future<void> removeSubscription({required String endpoint}) async {
    removals++;
    profileAtRemove = readProfile?.call();
    sessionAtRemove = readSession?.call();
    recordEvent?.call('push.remove');
  }
}
