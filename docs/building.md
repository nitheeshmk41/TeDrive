# Building TeDrive

## Requirements

- Flutter 3.47.7 (the version CI uses)
- Android: JDK 17 and the Android SDK
- Desktop: TDLib 1.8.15 built as a shared library (`tdjson`). CI builds it from source; see `.github/workflows/release.yml` for the exact steps per platform.

## Run

```bash
cd app
flutter pub get
flutter run                 # a connected Android phone, or -d windows / linux / macos
flutter run -d chrome       # web; needs tdweb, see below
```

The web build loads TDLib compiled to WebAssembly. `app/tool/fetch_tdweb.sh build/web` downloads it from the `tdweb-1.8.15` release (built once by `.github/workflows/tdweb.yml`).

## Test

```bash
cd app
flutter analyze
dart test
```

The unit tests are pure Dart (`dart test`), so they run without a device.

## Release

1. Set `version:` in `app/pubspec.yaml` and `appVersion` in `app/lib/config.dart` to the same number (a test checks this). Raise the build number after `+` every release, or Android refuses the update.
2. Add a section to `CHANGELOG.md`.
3. Commit, then tag and push:

   ```bash
   git tag -a v2.1.0 -m "TeDrive v2.1.0"
   git push origin main v2.1.0
   ```

CI builds every platform and publishes the GitHub release. The in-app updater finds it automatically.

### Android signing

Release APKs must always be signed with the same key, or phones cannot update in place. CI reads it from these repository secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Keep a backup of the keystore outside the repository; `signing/` is git-ignored.
