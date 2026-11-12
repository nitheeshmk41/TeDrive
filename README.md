# TeDrive

> Your personal cloud, powered by Telegram.

TeDrive is an Android app that turns a private channel in your own Telegram account into a cloud drive. Files go straight from your phone to Telegram. There is no TeDrive server, no subscription, and nothing to host.

## What it does

- **Phone backup.** Backs up the photo and video albums you choose (Camera, WhatsApp Images, Screenshots and so on), on Wi-Fi only if you want, and keeps going in the background.
- **Free up space.** Removes photos and videos from the phone once Telegram confirms it holds a copy with the same SHA-256 fingerprint and size.
- **Photos, Albums and Files.** A gallery grouped by the date each photo was taken, albums, a file list with search, filters and sorting.
- **Preview without downloading.** Photos open in a zoomable viewer. Videos and audio stream from Telegram and start playing before the download finishes.
- **Share anywhere.** Send any file to WhatsApp or another app from the share sheet. TeDrive also appears in Android's file picker, so apps that attach documents can pick straight from the drive.
- **One drive on every device.** Sign in with the same Telegram account on several phones and they all use the same channel. A file added, moved or deleted on one device shows up on the others, and each file records which device uploaded it.
- **Large files.** Up to 2 GB per file (4 GB with Telegram Premium).

## How it works

TeDrive is a Telegram client built on [TDLib](https://core.telegram.org/tdlib), Telegram's official client library. It signs in as you, creates a private channel called `TeDrive Storage`, and stores each file as a message in it.

Everything TeDrive knows about a file is written in the message caption (SHA-256 fingerprint, album, original date, uploading device). The whole catalogue can therefore be rebuilt from the channel on any device, with no separate database.

Your Telegram API credentials and session stay on your device. The session database is encrypted with a key held in the Android Keystore.

## Getting started

You need an Android phone (Android 7.0 or newer), a Telegram account, and a free Telegram API ID and hash.

1. Install the APK from the [releases page](https://github.com/nitheeshmk41/TeDrive/releases).
2. Get your API ID and hash:
   1. Open [my.telegram.org](https://my.telegram.org) and sign in with your phone number.
   2. Choose **API development tools**.
   3. Create an app with any title and short name.
   4. Copy **App api_id** and **App api_hash**.
3. Open TeDrive, enter the two values, then sign in with your phone number.

Keep the API hash private.

## Things to know

- **Keep a second copy of anything irreplaceable.** Telegram is not a contracted storage service. Accounts can be limited and policies can change.
- **Files are not end-to-end encrypted.** They are stored like any other Telegram cloud message.
- **Automatic backup covers photos and videos.** Other file types are uploaded with the Upload button.
- **Backup runs while the app is open or in the background.** It does not start by itself after the phone restarts.
- **Release builds are signed with a development key** until a release key is set up.

## Platforms

| Platform | Status |
| :--- | :--- |
| Android | Supported. This is the real app. |
| Web | Demo only. It shows sample files and does not connect to Telegram. |
| Windows, Linux | Not supported yet. The app needs a build of TDLib (`tdjson`) for each platform, which is not included. |

## Development

The Flutter project is in [`app/`](app).

```bash
cd app
flutter pub get
flutter run                 # on a connected Android phone
dart test                   # unit tests
flutter build apk --release --split-per-abi
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

### Hosting the web demo on Vercel

`app/vercel.json` builds the demo on Vercel. Import the repository in Vercel and set **Root Directory** to `app`. No environment variables are needed.

## Licence

MIT.

TeDrive is an independent project. It uses the Telegram API and is not made or endorsed by Telegram.
