import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth_controller.dart';
import '../data/auth_api.dart';

/// Landing page for the password-reset link (`/reset-password?token=...`).
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key, required this.token});

  final String token;

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authApiProvider).resetPassword(widget.token, _password.text);
      if (mounted) setState(() => _done = true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _done
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle,
                          size: 56, color: theme.colorScheme.primary),
                      const SizedBox(height: 16),
                      Text('Password updated. Sign in with your new password.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: () => context.go('/'),
                        child: const Text('Go to Quadrille'),
                      ),
                    ],
                  )
                : Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Choose a new password',
                            style: theme.textTheme.titleMedium,
                            textAlign: TextAlign.center),
                        const SizedBox(height: 20),
                        TextFormField(
                          controller: _password,
                          obscureText: true,
                          autofocus: true,
                          decoration: const InputDecoration(labelText: 'New password'),
                          onFieldSubmitted: (_) => _submit(),
                          validator: (v) =>
                              (v == null || v.length < 8) ? 'At least 8 characters' : null,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                        ],
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _busy ? null : _submit,
                          child: _busy
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Update password'),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
