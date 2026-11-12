# TeDrive

> Your personal cloud, powered by Telegram.

TeDrive turns a private channel in your own Telegram account into a cloud drive and photo library. Files go straight from your device to Telegram. There is no TeDrive server, no subscription, and nothing to host.

## What it does

- **Phone backup.** Backs up the photo and video albums you choose (Camera, WhatsApp Images, Screenshots and so on), on Wi-Fi only by default, and keeps going in the background.
- **Add from anywhere.** Select photos in your gallery, tap Share and choose TeDrive. Or use the Upload button for any file.
- **Free up space.** Removes photos and videos from the phone once Telegram confirms it holds a copy with the same SHA-256 fingerprint and size.
- **Photos, Albums and Files.** A gallery grouped day by day by when each photo was taken, albums, and a file list with search, filters and sorting.
- **Preview without downloading.** Photos open in a zoomable viewer. Videos and audio stream from Telegram and start playing before the download finishes.
- **Rename.** Give any file a new name. It shows on all your devices.
- **Share anywhere.** Send any file to WhatsApp or another app. TeDrive also appears in Android's file picker, so apps that attach documents can pick straight from the drive.
- **One drive on every device.** Sign in with the same Telegram account on several devices and they all use the same channel. A file added, renamed, moved or deleted on one shows up on the others, and each file records which device uploaded it.
- **Light on storage.** Files you open are cached, and the cache is kept under 1 GB automatically. The account page shows what the drive holds by type and by device.
- **Large files.** Up to 2 GB per file (4 GB with Telegram Premium).

## Platforms

| Platform | Status |
| :--- | :--- |
| Android | Supported and tested. |
| Windows, Linux, macOS | First builds. Browse, upload, download, rename and organise work through the same code as Android, but they have had little real-world testing. Phone backup, the system file picker and the built-in video player are Android-only; on desktop, videos open in your usual player. |
| Web | Demo only. It shows sample files and does not connect to Telegram. |

Downloads are on the [releases page](https://github.com/nitheeshmk41/TeDrive/releases).

## Getting started

You need a Telegram account and a free Telegram API ID and hash.

1. Install TeDrive from the releases page.
2. Get your API ID and hash:
   1. Open [my.telegram.org](https://my.telegram.org) and sign in with your phone number.
   2. Choose **API development tools**.
   3. Create an app with any title and short name.
   4. Copy **App api_id** and **App api_hash**.
3. Open TeDrive, enter the two values, then sign in with your phone number.

Keep the API hash private. Use the same phone number on every device to see the same files.

## How it works

TeDrive is a Telegram client built on [TDLib](https://core.telegram.org/tdlib), Telegram's official client library. It signs in as you, creates a private channel called `TeDrive Storage`, and stores each file as a message in it.

Everything TeDrive knows about a file is written in the message caption (SHA-256 fingerprint, album, original date, uploading device, custom name). The whole catalogue can therefore be rebuilt from the channel on any device, with no separate database.

Your Telegram API credentials and session stay on your device. On Android the session database is encrypted with a key held in the Android Keystore.

## Things to know

- **Keep a second copy of anything irreplaceable.** Telegram is not a contracted storage service. Accounts can be limited and policies can change.
- **Files are not end-to-end encrypted.** They are stored like any other Telegram cloud message.
- **Automatic backup covers photos and videos.** Other file types are added with Upload or Share.
- **Backup runs while the app is open or in the background.** It does not start by itself after the phone restarts.
- **The macOS app is not notarised.** Right-click it and choose Open the first time.
- **Linux** needs GTK 3, OpenSSL 3 and a keyring service (GNOME Keyring or KWallet).

## Development

The Flutter project is in [`app/`](app).

```bash
cd app
flutter pub get
flutter run                 # on a connected Android phone
dart test                   # unit tests
flutter build web --release --no-tree-shake-icons   # the web demo
```

Layout of `app/lib`:

| Path | What is in it |
| :--- | :--- |
| `td/` | The TDLib binding, and the sample-data backend used by the web demo |
| `tedrive_service.dart` | Sign-in, the storage channel, uploads, downloads |
| `drive_controller.dart` | The file list, upload queue and cross-device updates |
| `backup_controller.dart`, `backup_plan.dart` | Phone backup and free up space |
| `stored_file.dart` | The file model and caption format |
| `media_server.dart` | Local streaming for the video and audio player |
| `ui/` | Screens |

The Android-specific code (media library, background service, file picker integration, sharing) is in `app/android/app/src/main/kotlin`.

### Builds and releases

[`.github/workflows/release.yml`](.github/workflows/release.yml) builds every platform on each push to `main`. Pushing a tag such as `v1.0.0` also publishes the builds as a GitHub release.

The Android app includes a prebuilt TDLib 1.8.15. For Windows, Linux and macOS the workflow compiles the same TDLib version from source and caches it, so the first build takes much longer than later ones.

### Signing the Android app

Release APKs should be signed with one long-lived key, otherwise a new version cannot be installed over an old one. The workflow signs with your key when these repository secrets exist (Settings, Secrets and variables, Actions):

| Secret | Value |
| :--- | :--- |
| `ANDROID_KEYSTORE_BASE64` | The keystore file, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | The keystore password |
| `ANDROID_KEY_ALIAS` | The key alias |
| `ANDROID_KEY_PASSWORD` | The key password |

Without them the APK is signed with a throwaway debug key and the workflow prints a warning. Keep the keystore and its passwords backed up somewhere safe: if they are lost, existing installs can no longer be updated.

### Hosting the web demo on Vercel

`app/vercel.json` builds the demo on Vercel. Import the repository in Vercel and set **Root Directory** to `app`. No environment variables are needed.

## Licence

MIT.

TeDrive is an independent project. It uses the Telegram API and is not made or endorsed by Telegram.
