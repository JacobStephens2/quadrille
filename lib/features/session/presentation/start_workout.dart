import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/presentation/presentation_opening.dart';
import '../session_starting.dart';

/// Use the invoking screen's context: persistence emissions can replace its
/// start controls before the accepted operation returns its identifier.
Future<void> startWorkout(
  BuildContext context,
  SessionStartingHandle starting,
) async {
  final opening = PresentationOpening.capture(context);
  if (!opening.isCurrent) return;
  final outcome = await starting.start();
  if (!context.mounted || !starting.isCurrent || !opening.isCurrent) return;
  switch (outcome.status) {
    case SessionStartingStatus.started:
      context.go('/session/${outcome.sessionId}');
    case SessionStartingStatus.failed:
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not start this workout. Please try again.'),
        ),
      );
    case SessionStartingStatus.superseded:
      break;
  }
}
