# Notes for AI coding agents

TeDrive is a Flutter app that uses the user's own Telegram account (via TDLib) as file storage. There is no backend. Read [docs/architecture.md](docs/architecture.md) first.

## Layout

| Path | What |
| :--- | :--- |
| `app/lib/td/` | TDLib client: FFI on Android/desktop, tdweb (WebAssembly) bridge on web |
| `app/lib/tedrive_service.dart` | Sign-in, channels, upload, download, forwarding to chats |
| `app/lib/drive_controller.dart` | App state, upload queue (persisted), downloads |
| `app/lib/backup_controller.dart`, `backup_plan.dart` | Android phone backup |
| `app/lib/stored_file.dart` | File model; caption metadata parse/serialise |
| `app/lib/vault_service.dart` | Vault encryption |
| `app/lib/app_lock.dart` | PIN and fingerprint lock |
| `app/lib/updater.dart`, `version.dart` | Check for updates |
| `app/lib/photo_metadata.dart` | EXIF GPS and camera |
| `app/lib/wifi_transfer.dart` | Local HTTP server for phone-to-laptop transfer |
| `app/lib/ui/` | Screens; `home_page.dart` is the main one |
| `app/android/app/src/main/kotlin/` | Media access, foreground service, documents provider, share receiver |
| `.github/workflows/release.yml` | Builds all platforms; a `v*` tag publishes a release |

## Rules

- Check with `cd app && flutter analyze && dart test`. Tests are pure Dart; do not import Flutter in code they cover.
- New caption keys go in `stored_file.dart` with a test.
- `appVersion` in `app/lib/config.dart` must equal `version:` in `app/pubspec.yaml`; bump the `+build` number every release.
- `signing/` holds the release keystore and is git-ignored. Never commit it, and never print secrets.
- Code in `app/lib` must compile for web too: guard `dart:io` use with `kIsWeb`, and never import `dart:ffi` outside `app/lib/td/`.
- `local_auth` is used through `local_auth_android` and `local_auth_darwin` only: its Windows plugin does not build with current Visual Studio.
- On web, TDLib updates can arrive before the reply to the request that caused them. Code that waits for an update must not assume the reply came first.

## Local machine notes

On the maintainer's Windows PC, Smart App Control blocks release builds and `flutter test`. Use `dart test`, and `flutter build apk --debug --target-platform android-arm64` to check Android compiles. Release builds come from CI.
