import 'package:countdown_ring/countdown_ring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../primer_controller.dart';
import '../session_starting.dart';

final primerNowProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class PrimerDialog extends ConsumerStatefulWidget {
  const PrimerDialog({super.key, required this.starting});

  final SessionStartingHandle starting;

  @override
  ConsumerState<PrimerDialog> createState() => _PrimerDialogState();
}

class _PrimerDialogState extends ConsumerState<PrimerDialog> {
  late final PrimerController _primer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _primer = PrimerController(now: ref.read(primerNowProvider));
    _primer.addListener(_onProgress);
  }

  void _onProgress() {
    if (_primer.isComplete && widget.starting.isCurrent) _close();
  }

  void _close() {
    if (_closing || ModalRoute.of(context)?.isCurrent != true) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _primer.removeListener(_onProgress);
    _primer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-evaluate the captured start owner after a profile/database transition.
    ref.watch(localProfileGenerationProvider);
    final theme = Theme.of(context);
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('4-minute pre-workout'),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListenableBuilder(
                  listenable: _primer,
                  builder: (context, _) {
                    if (!widget.starting.isCurrent) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'This workout belongs to a previous profile.',
                          ),
                          TextButton(
                            onPressed: _close,
                            child: const Text('Close primer'),
                          ),
                        ],
                      );
                    }
                    if (_primer.isComplete) {
                      return FilledButton(
                        onPressed: _close,
                        child: const Text('Continue to workout'),
                      );
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!_primer.hasStarted) ...[
                          Text(
                            'Somatic Fluidity & Open Posture Primer',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Four movements, one minute each, before your workout.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          FilledButton.icon(
                            onPressed: _primer.start,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Start primer'),
                          ),
                        ] else ...[
                          Text(
                            'Step ${_primer.stepNumber} of 4',
                            style: theme.textTheme.labelLarge,
                          ),
                          const SizedBox(height: 16),
                          CountdownRing(
                            remaining: _primer.remaining,
                            fraction:
                                _primer.remaining.inMilliseconds /
                                PrimerController.stepDuration.inMilliseconds,
                            size: 160,
                          ),
                          const SizedBox(height: 24),
                          Text(
                            _primer.step.name,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _primer.step.cue,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 24),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            alignment: WrapAlignment.center,
                            children: [
                              FilledButton.icon(
                                onPressed: _primer.isPaused
                                    ? _primer.resume
                                    : _primer.pause,
                                icon: Icon(
                                  _primer.isPaused
                                      ? Icons.play_arrow
                                      : Icons.pause,
                                ),
                                label: Text(
                                  _primer.isPaused ? 'Resume' : 'Pause',
                                ),
                              ),
                              OutlinedButton(
                                onPressed: _primer.skipStep,
                                child: const Text('Skip step'),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: _close,
                          child: const Text('Skip primer'),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
