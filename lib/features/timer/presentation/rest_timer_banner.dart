import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../timer_providers.dart';
import 'package:countdown_ring/countdown_ring.dart';

/// A docked banner showing the live rest countdown with quick controls. Renders
/// nothing when no timer is active. Recomputes remaining time from the
/// persisted `endsAt` on every tick, so it stays correct across reloads.
class RestTimerBanner extends ConsumerWidget {
  const RestTimerBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timer = ref.watch(activeTimerProvider).value;
    if (timer == null) return const SizedBox.shrink();

    // Subscribe to the tick only while a timer is shown.
    ref.watch(timerTickProvider);

    final now = DateTime.now();
    final remaining = timer.endsAt.difference(now);
    final total = timer.durationSeconds == 0 ? 1 : timer.durationSeconds;
    final fraction = remaining.inMilliseconds / (total * 1000);
    final done = remaining <= Duration.zero;
    final theme = Theme.of(context);
    final controller = ref.read(restTimerControllerProvider);

    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              CountdownRing(remaining: remaining, fraction: fraction),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      done ? 'Rest complete' : 'Resting',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: done ? theme.colorScheme.primary : null,
                      ),
                    ),
                    if (timer.label != null)
                      Text(
                        done ? 'Next: ${timer.label}' : timer.label!,
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (!done) ...[
                _AdjustButton(
                  label: '-15',
                  onTap: () => controller.adjust(const Duration(seconds: -15)),
                ),
                _AdjustButton(
                  label: '+30',
                  onTap: () => controller.adjust(const Duration(seconds: 30)),
                ),
              ],
              TextButton(
                onPressed: controller.skip,
                child: Text(done ? 'Dismiss' : 'Skip'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdjustButton extends StatelessWidget {
  const _AdjustButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 36),
          visualDensity: VisualDensity.compact,
        ),
        onPressed: onTap,
        child: Text(label),
      ),
    );
  }
}

/// Convenience: the active timer row, exposed for screens that want to know if
/// a rest is in progress without rebuilding on every tick.
ActiveTimer? activeTimerOrNull(WidgetRef ref) =>
    ref.watch(activeTimerProvider).value;
