// TeDrive: a personal cloud drive that stores files in the user's own
// Telegram account.

import 'package:flutter/material.dart';

import 'provider_bridge.dart';
import 'td/td_client.dart' show TdLibraryMissing;
import 'tedrive_service.dart';
import 'ui/home_page.dart';
import 'ui/onboarding.dart';
import 'ui/theme.dart';

final service = TeDriveService();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lets Android's file picker fetch files even with no screen showing.
  registerProviderBridge(service);
  try {
    await service.start();
  } on TdLibraryMissing {
    service.authState.value = 'libraryMissing';
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
      debugShowCheckedModeBanner: false,
      theme: tedriveTheme(Brightness.light),
      darkTheme: tedriveTheme(Brightness.dark),
      home: ValueListenableBuilder<String>(
        valueListenable: service.authState,
        builder: (context, state, _) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: KeyedSubtree(key: ValueKey(state), child: _screenFor(state)),
        ),
      ),
    );
  }

  Widget _screenFor(String state) => switch (state) {
    'ready' => HomePage(service: service),
    'needCredentials' => SetupFlow(service: service),
    'waitPhoneNumber' ||
    'waitCode' ||
    'waitPassword' => SignInPage(service: service, state: state),
    'starting' => const SplashPage(text: 'Connecting to Telegram…'),
    'loggingOut' || 'closing' => const SplashPage(text: 'Please wait…'),
    'libraryMissing' => const ProblemPage(
      title: 'Telegram library not found',
      text:
          'This build of TeDrive does not include Telegram\'s library '
          '(tdjson), so it cannot connect. The Android app has it built in. '
          'Desktop builds need tdjson placed next to the program.',
    ),
    'error' => ProblemPage(
      title: 'TeDrive could not start',
      text: service.lastError ?? 'Unknown error',
      actionLabel: 'Re-enter API ID and hash',
      onAction: service.clearCredentials,
    ),
    _ => ProblemPage(
      title: 'This sign-in step is not supported yet',
      text:
          'Telegram asked for "$state". Finish signing in with the '
          'official Telegram app first, then try again.',
      actionLabel: 'Start over',
      onAction: service.logOut,
    ),
  };
}
