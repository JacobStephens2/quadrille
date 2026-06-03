import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth_controller.dart';
import '../data/auth_api.dart';

/// Landing page for the email-verification link (`/verify-email?token=...`).
class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key, required this.token});

  final String token;

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  String _status = 'verifying';

  @override
  void initState() {
    super.initState();
    _verify();
  }

  Future<void> _verify() async {
    try {
      await ref.read(authApiProvider).verifyEmail(widget.token);
      // Refresh auth so the verified flag (and sync) unlocks.
      try {
        await ref.read(authControllerProvider.notifier).refresh();
      } catch (_) {}
      if (mounted) setState(() => _status = 'done');
    } on AuthException catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verifying = _status == 'verifying';
    final done = _status == 'done';
    return Scaffold(
      appBar: AppBar(title: const Text('Verify email')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (verifying)
                const CircularProgressIndicator()
              else
                Icon(
                  done ? Icons.check_circle : Icons.error_outline,
                  size: 56,
                  color: done ? theme.colorScheme.primary : theme.colorScheme.error,
                ),
              const SizedBox(height: 16),
              Text(
                verifying
                    ? 'Verifying…'
                    : done
                        ? 'Email verified — cloud sync is enabled.'
                        : _status,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 20),
              if (!verifying)
                FilledButton(
                  onPressed: () => context.go('/'),
                  child: const Text('Go to Quadrille'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
