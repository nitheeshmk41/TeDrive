import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../countries.dart';
import '../tedrive_service.dart';
import 'theme.dart';

/// Shared layout of the setup and sign-in screens: logo, step dots, a
/// title and one form, centred and capped in width so it also looks right
/// on a tablet or desktop window.
class _StepScaffold extends StatelessWidget {
  const _StepScaffold({
    required this.step,
    required this.title,
    required this.subtitle,
    required this.children,
    this.onBack,
  });

  /// 1 to 3, or 0 to hide the step dots.
  final int step;
  final String title;
  final String subtitle;
  final List<Widget> children;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: onBack == null
            ? null
            : IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: onBack,
              ),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: AppLogo(size: 72)),
                  const SizedBox(height: 20),
                  if (step > 0) ...[
                    _StepDots(current: step),
                    const SizedBox(height: 20),
                  ],
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepDots extends StatelessWidget {
  const _StepDots({required this.current});
  final int current;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Step $current of 3',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 1; i <= 3; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == current ? 28 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i <= current ? scheme.primary : scheme.outlineVariant,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
    );
  }
}

/// Turns Telegram's error codes into plain words.
String friendlyAuthError(Object error) {
  final text = '$error';
  const known = {
    'PHONE_NUMBER_INVALID':
        'That phone number does not look right. Include the country code, '
        'for example +91 98765 43210.',
    'PHONE_CODE_INVALID': 'That code is not correct. Check it and try again.',
    'PHONE_CODE_EXPIRED':
        'That code has expired. Go back and request a new one.',
    'PASSWORD_HASH_INVALID': 'That password is not correct.',
    'API_ID_INVALID':
        'Telegram did not accept the API ID or hash. Go back to step 1 and '
        're-enter them.',
    'API_ID_PUBLISHED_FLOOD':
        'Telegram did not accept the API ID or hash. Go back to step 1 and '
        're-enter them.',
    'PHONE_NUMBER_BANNED': 'Telegram has blocked this phone number.',
    'PHONE_NUMBER_FLOOD':
        'Too many attempts with this number. Please try again later.',
  };
  for (final entry in known.entries) {
    if (text.contains(entry.key)) return entry.value;
  }
  final wait = RegExp(r'FLOOD_WAIT_(\d+)|retry after (\d+)').firstMatch(text);
  if (wait != null) {
    final seconds = int.parse(wait.group(1) ?? wait.group(2)!);
    final minutes = (seconds / 60).ceil();
    return 'Too many attempts. Please wait '
        '${minutes <= 1 ? 'a minute' : '$minutes minutes'} and try again.';
  }
  return text;
}

// ------------------------------------------------------------ Welcome

/// First screen of a fresh install: what TeDrive is, then the API setup.
class SetupFlow extends StatefulWidget {
  const SetupFlow({super.key, required this.service});
  final TeDriveService service;

  @override
  State<SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends State<SetupFlow> {
  bool _started = false;

  @override
  Widget build(BuildContext context) => _started
      ? CredentialsPage(
          service: widget.service,
          onBack: () => setState(() => _started = false),
        )
      : _WelcomePage(onStart: () => setState(() => _started = true));
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: AppLogo(size: 112)),
                  const SizedBox(height: 24),
                  Text(
                    'TeDrive',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your personal cloud, powered by Telegram.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 36),
                  const _Feature(
                    icon: Icons.photo_library_outlined,
                    title: 'Back up photos and videos',
                    text: 'Free up your phone without losing a thing.',
                  ),
                  const _Feature(
                    icon: Icons.devices_outlined,
                    title: 'One drive on every device',
                    text: 'Sign in anywhere and see the same files.',
                  ),
                  const _Feature(
                    icon: Icons.lock_outline,
                    title: 'Stored in your own account',
                    text:
                        'Files go straight to a private channel in your '
                        'Telegram. There is no TeDrive server.',
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: onStart,
                    child: const Text('Get started'),
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

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ Step 1

/// Step 1: each user enters their own Telegram API credentials.
class CredentialsPage extends StatefulWidget {
  const CredentialsPage({super.key, required this.service, this.onBack});
  final TeDriveService service;
  final VoidCallback? onBack;

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

  @override
  void dispose() {
    _id.dispose();
    _hash.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.saveCredentials(
        int.parse(_id.text.trim()),
        _hash.text.trim().toLowerCase(),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = friendlyAuthError(e);
        });
      }
    }
  }

  void _showHelp() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => const _ApiHelpSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StepScaffold(
      step: 1,
      onBack: widget.onBack,
      title: 'Connect your Telegram API',
      subtitle:
          'TeDrive talks to Telegram directly, using an API ID that '
          'belongs to you. It is free and takes about two minutes.',
      children: [
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _id,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'API ID',
                  hintText: 'For example 1234567',
                  prefixIcon: Icon(Icons.tag),
                ),
                validator: (v) {
                  final id = int.tryParse((v ?? '').trim());
                  return id == null || id <= 0
                      ? 'Enter the API ID (numbers only)'
                      : null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _hash,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'API hash',
                  hintText: '32 letters and digits',
                  prefixIcon: Icon(Icons.key_outlined),
                ),
                validator: (v) =>
                    _hashPattern.hasMatch((v ?? '').trim().toLowerCase())
                    ? null
                    : 'The API hash has 32 characters: 0-9 and a-f',
                onFieldSubmitted: (_) => _save(),
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy ? const _ButtonSpinner() : const Text('Continue'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _showHelp,
          icon: const Icon(Icons.help_outline),
          label: const Text('Where do I find these?'),
        ),
        const SizedBox(height: 8),
        Text(
          'Both values are stored only on this device. '
          'Never share your API hash with anyone.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ApiHelpSheet extends StatelessWidget {
  const _ApiHelpSheet();

  static const _steps = [
    'Open my.telegram.org in a browser.',
    'Enter your phone number with the country code.',
    'Type the login code Telegram sends to your Telegram app.',
    'Choose "API development tools".',
    'Enter any app title and short name (for example TeDrive), then create.',
    'Copy "App api_id" and "App api_hash" into TeDrive.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Getting your API ID and hash',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            for (final (i, step) in _steps.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 13,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(step),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(
                  const ClipboardData(text: 'https://my.telegram.org'),
                );
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Address copied')));
                Navigator.pop(context);
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy my.telegram.org'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 22,
    child: CircularProgressIndicator(strokeWidth: 2.5),
  );
}

// ------------------------------------------------------------ Steps 2 and 3

/// Step 2 (phone number) and step 3 (login code, then the two-step
/// verification password if the account has one).
class SignInPage extends StatefulWidget {
  const SignInPage({super.key, required this.service, required this.state});
  final TeDriveService service;

  /// waitPhoneNumber, waitCode or waitPassword.
  final String state;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _input = TextEditingController();

  /// Starts on the country this device is set to.
  Country _country = countryForIso(
    WidgetsBinding.instance.platformDispatcher.locale.countryCode,
  );

  Future<void> _pickCountry() async {
    final picked = await showModalBottomSheet<Country>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _CountrySheet(),
    );
    if (picked != null) setState(() => _country = picked);
  }

  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  TeDriveService get _service => widget.service;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _input.text.trim();
    if (value.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      switch (widget.state) {
        case 'waitPhoneNumber':
          // Telegram wants digits with a leading +.
          await _service.setPhoneNumber(fullPhoneNumber(_country, value));
        case 'waitCode':
          await _service.checkCode(value.replaceAll(RegExp(r'\s'), ''));
        case 'waitPassword':
          await _service.checkPassword(_input.text);
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyAuthError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.state;
    final (title, subtitle) = switch (state) {
      'waitPhoneNumber' => (
        'Sign in to Telegram',
        'Enter the phone number of your Telegram account. Use the same '
            'number on every device to see the same files.',
      ),
      'waitCode' => (
        'Enter the login code',
        'Telegram sent a code as '
            '${_service.codeDestination ?? 'a message'}.',
      ),
      _ => (
        'Two-step verification',
        'Your account is protected with a password. Enter it to finish '
            'signing in.',
      ),
    };
    final field = switch (state) {
      'waitPhoneNumber' => TextField(
        controller: _input,
        autofocus: true,
        keyboardType: TextInputType.phone,
        autofillHints: const [AutofillHints.telephoneNumber],
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s\-()]')),
        ],
        decoration: InputDecoration(
          labelText: 'Phone number',
          hintText: '98765 43210',
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 6, right: 2),
            child: TextButton(
              onPressed: _pickCountry,
              child: Text(
                '${_country.flag}  +${_country.code}',
                style: theme.textTheme.titleMedium,
              ),
            ),
          ),
          errorText: _error,
          errorMaxLines: 4,
        ),
        onSubmitted: (_) => _submit(),
      ),
      'waitCode' => TextField(
        controller: _input,
        autofocus: true,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        autofillHints: const [AutofillHints.oneTimeCode],
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(8),
        ],
        style: theme.textTheme.headlineMedium?.copyWith(
          letterSpacing: 10,
          fontWeight: FontWeight.w600,
        ),
        decoration: InputDecoration(
          hintText: '•••••',
          errorText: _error,
          errorMaxLines: 4,
        ),
        onSubmitted: (_) => _submit(),
      ),
      _ => TextField(
        controller: _input,
        autofocus: true,
        obscureText: !_showPassword,
        keyboardType: TextInputType.visiblePassword,
        autofillHints: const [AutofillHints.password],
        decoration: InputDecoration(
          labelText: 'Password',
          helperText: _service.passwordHint == null
              ? null
              : 'Hint: ${_service.passwordHint}',
          prefixIcon: const Icon(Icons.lock_outline),
          suffixIcon: IconButton(
            tooltip: _showPassword ? 'Hide password' : 'Show password',
            icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showPassword = !_showPassword),
          ),
          errorText: _error,
          errorMaxLines: 4,
        ),
        onSubmitted: (_) => _submit(),
      ),
    };
    return _StepScaffold(
      step: state == 'waitPhoneNumber' ? 2 : 3,
      title: title,
      subtitle: subtitle,
      children: [
        field,
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const _ButtonSpinner()
              : Text(state == 'waitPhoneNumber' ? 'Send code' : 'Continue'),
        ),
        const SizedBox(height: 8),
        if (state == 'waitPhoneNumber')
          TextButton(
            onPressed: _busy ? null : _service.clearCredentials,
            child: const Text('Change API ID or hash'),
          )
        else
          TextButton(
            onPressed: _busy ? null : _service.logOut,
            child: const Text('Use a different phone number'),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------ Status

/// Full-screen logo with a spinner and a line of text.
class SplashPage extends StatelessWidget {
  const SplashPage({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppLogo(size: 96),
          const SizedBox(height: 28),
          const SizedBox.square(
            dimension: 26,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 16),
          Text(text),
        ],
      ),
    ),
  );
}

/// A problem the user has to do something about.
class ProblemPage extends StatelessWidget {
  const ProblemPage({
    super.key,
    required this.title,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 56,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(text, textAlign: TextAlign.center),
                  if (actionLabel != null) ...[
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: onAction,
                      child: Text(actionLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Searchable list of countries and their calling codes.
class _CountrySheet extends StatefulWidget {
  const _CountrySheet();

  @override
  State<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<_CountrySheet> {
  final _searchController = TextEditingController();
  String _query = '';

  static const _popularIsos = ['IN', 'US', 'GB', 'AE', 'CA', 'DE', 'SG', 'AU'];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = searchCountries(_query);
    final popular = [for (final iso in _popularIsos) countryForIso(iso)];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                Text(
                  'Select Country',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  '${shown.length} countries',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search country name, ISO or code (e.g. +91, IN)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (_query.isEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Text(
                'POPULAR',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                  color: scheme.primary,
                ),
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: popular.length,
                itemBuilder: (context, i) {
                  final c = popular[i];
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      avatar: Text(
                        c.flag,
                        style: const TextStyle(fontSize: 16),
                      ),
                      label: Text('${c.iso} +${c.code}'),
                      onPressed: () => Navigator.pop(context, c),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 16),
          ],
          Expanded(
            child: ListView.builder(
              controller: scroll,
              itemCount: shown.length,
              itemBuilder: (context, i) {
                final c = shown[i];
                return ListTile(
                  leading: Text(c.flag, style: const TextStyle(fontSize: 26)),
                  title: Text(
                    c.name,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  subtitle: Text(
                    c.iso,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '+${c.code}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  onTap: () => Navigator.pop(context, c),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
