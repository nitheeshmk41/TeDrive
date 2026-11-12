// TeDrive: a personal cloud drive that stores files in the user's own
// Telegram account. This file holds app start-up, setup and sign-in.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'tedrive_service.dart';
import 'ui/drive_page.dart';

final service = TeDriveService();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await service.start();
  } catch (e) {
    service.lastError = '$e';
    service.authState.value = 'error';
  }
  runApp(const TeDriveApp());
}

class TeDriveApp extends StatelessWidget {
  const TeDriveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TeDrive',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2AABEE)),
      ),
      home: ValueListenableBuilder<String>(
        valueListenable: service.authState,
        builder: (context, state, _) => switch (state) {
          'ready' => DrivePage(service: service),
          'needCredentials' => const CredentialsPage(),
          'waitPhoneNumber' ||
          'waitCode' ||
          'waitPassword' => AuthPage(state: state, key: ValueKey(state)),
          'starting' => const _Message('Connecting to Telegram…'),
          'loggingOut' || 'closing' => const _Message('Please wait…'),
          'error' => _Message(
            'Could not start:\n${service.lastError}',
            action: TextButton(
              onPressed: service.clearCredentials,
              child: const Text('Re-enter API credentials'),
            ),
          ),
          _ => _Message('Login step not supported yet: $state'),
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- API setup

/// First-run screen: each user enters their own Telegram API credentials.
class CredentialsPage extends StatefulWidget {
  const CredentialsPage({super.key});

  @override
  State<CredentialsPage> createState() => _CredentialsPageState();
}

class _CredentialsPageState extends State<CredentialsPage> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _hash = TextEditingController();
  bool _busy = false;
  String? _error;

  static final _hashPattern = RegExp(r'^[0-9a-f]{32}$');

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await service.saveCredentials(
        int.parse(_id.text.trim()),
        _hash.text.trim().toLowerCase(),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Set up TeDrive')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'TeDrive connects straight to your own Telegram account. '
              'It needs your personal Telegram API ID and API hash. '
              'They are stored only on this phone.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  'How to get them (free, about 2 minutes):\n'
                  '1. Open https://my.telegram.org in a browser.\n'
                  '2. Enter your phone number with country code.\n'
                  '3. Type the code Telegram sends to your Telegram app.\n'
                  '4. Tap "API development tools".\n'
                  '5. Fill in any app title and short name, then create.\n'
                  '6. Copy "App api_id" and "App api_hash" into the boxes below.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _id,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'API ID',
                helperText: 'Numbers only',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                final id = int.tryParse((v ?? '').trim());
                return id == null || id <= 0
                    ? 'Enter the numeric API ID'
                    : null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _hash,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'API hash',
                helperText: '32 letters and digits',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  _hashPattern.hasMatch((v ?? '').trim().toLowerCase())
                  ? null
                  : 'The API hash is 32 characters: 0-9 and a-f',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Please wait…' : 'Continue'),
            ),
            if (kIsWeb) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.laptop_chromebook),
                label: const Text('Enter Web Demo Mode'),
                onPressed: _busy
                    ? null
                    : () {
                        _id.text = '123456';
                        _hash.text = '0123456789abcdef0123456789abcdef';
                        _save();
                      },
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Never share your API hash with anyone. '
              'No bot or bot token is needed.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _id.dispose();
    _hash.dispose();
    super.dispose();
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('TeDrive')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------- Login

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, required this.state});
  final String state;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _input = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    var value = _input.text.trim();
    if (value.isEmpty) {
      if (kIsWeb) {
        value = widget.state == 'waitPhoneNumber' ? '+1234567890' : '12345';
      } else {
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      switch (widget.state) {
        case 'waitPhoneNumber':
          await service.setPhoneNumber(value);
        case 'waitCode':
          await service.checkCode(value);
        case 'waitPassword':
          await service.checkPassword(value);
      }
    } catch (e) {
      final text = '$e';
      if (mounted) {
        setState(
          () => _error = text.contains('API_ID')
              ? 'Telegram rejected the API ID or hash. '
                    'Tap "Change API ID or hash" below and re-enter them.'
              : text,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (label, hint, keyboard) = switch (widget.state) {
      'waitPhoneNumber' => (
        'Phone number',
        'With country code, e.g. +91…',
        TextInputType.phone,
      ),
      'waitCode' => (
        'Login code',
        'Sent to your Telegram app or by SMS',
        TextInputType.number,
      ),
      _ => (
        'Two-step verification password',
        'Your Telegram cloud password',
        TextInputType.visiblePassword,
      ),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in to Telegram')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _input,
              autofocus: true,
              keyboardType: keyboard,
              obscureText: widget.state == 'waitPassword',
              decoration: InputDecoration(
                labelText: label,
                helperText: hint,
                errorText: _error,
                errorMaxLines: 3,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? 'Please wait…' : 'Continue'),
            ),
            if (widget.state == 'waitPhoneNumber')
              TextButton(
                onPressed: _busy ? null : service.clearCredentials,
                child: const Text('Change API ID or hash'),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }
}
