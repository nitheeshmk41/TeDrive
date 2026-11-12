<div align="center">

<img src="app/web/icons/Icon-512.png" alt="TeDrive logo" width="128" height="128">

# TeDrive

**Your personal cloud, powered by Telegram.**

A cloud drive and photo library that keeps your files in a private channel of your own Telegram account.<br>
No TeDrive server. No subscription. Nothing to host.

[**Download**](https://github.com/nitheeshmk41/TeDrive/releases) · [**Open in your browser**](https://tedrive.vercel.app) · [How it works](#how-it-works)

![Android](https://img.shields.io/badge/Android-ready-3DDC84?logo=android&logoColor=white)
![Web](https://img.shields.io/badge/Web-beta-1677F0?logo=googlechrome&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-beta-0078D4?logo=windows&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-beta-FCC624?logo=linux&logoColor=black)
![macOS](https://img.shields.io/badge/macOS-beta-000000?logo=apple&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

</div>

---

## Why TeDrive

Phones fill up. Cloud storage costs money every month. Telegram already stores files for free, up to 2 GB each, on every device you own.

TeDrive turns that into a proper drive: a gallery that looks like your phone's, albums, search, sharing, and automatic backup, with everything living in your own Telegram account.

## Features

| | |
| :--- | :--- |
| 📸 **Phone backup** | Backs up the albums you choose (Camera, WhatsApp Images, Screenshots and so on), on Wi-Fi only by default, in the background. |
| 🧹 **Free up space** | Removes photos and videos from the phone once Telegram confirms it holds an identical copy (same SHA-256 fingerprint and size). |
| 🖼️ **A real gallery** | Photos grouped day by day by when they were taken, albums, and a file list with search, filters and sorting. |
| ▶️ **Preview without downloading** | Photos open in a zoomable viewer. Videos and audio stream and start playing straight away. |
| 🔗 **Share links** | Create a public link for any file and send it to anyone, even people without Telegram. Stop sharing whenever you like. |
| 📤 **Share anywhere** | Send any file to WhatsApp or any other app. On Android, TeDrive also appears in the system file picker. |
| 📥 **Add from anywhere** | Select photos in your gallery, tap Share and choose TeDrive, or use Upload. |
| ✏️ **Rename and organise** | Rename files and move them between albums. Changes show on every device. |
| 💻 **One drive everywhere** | Sign in on your phones, your computer and the web with the same account and see the same files, live. Each file shows which device uploaded it. |
| 🪶 **Light on storage** | Files you open are cached and the cache is kept small automatically. The account page shows what your drive holds by type and by device. |

## Download

Get the latest version from the [**releases page**](https://github.com/nitheeshmk41/TeDrive/releases), or use it in the browser at [**tedrive.vercel.app**](https://tedrive.vercel.app).

| Platform | File | Status |
| :--- | :--- | :--- |
| Android | `android-arm64.apk` (most phones) or `android-arm32.apk` | Ready |
| Web | [tedrive.vercel.app](https://tedrive.vercel.app) | Beta |
| Windows 10 and 11 | `windows-x64.zip`, then run `TeDrive.exe` | Beta |
| Linux | `linux-x64.tar.gz`, then run `TeDrive/tedrive` | Beta |
| macOS (Apple Silicon) | `macos-arm64.zip` | Beta. Not notarised: right-click the app and choose **Open** the first time. |

Phone backup, free up space and the system file picker are Android features. Everything else works on every platform.

## Getting started

You need a Telegram account and a free Telegram API ID and hash. It takes about two minutes.

1. Open [my.telegram.org](https://my.telegram.org) and sign in with your phone number.
2. Choose **API development tools**.
3. Create an app with any title and short name (for example `TeDrive`).
4. Copy **App api_id** and **App api_hash**.
5. Open TeDrive, enter the two values, then sign in with your phone number and the code Telegram sends you.

Keep the API hash private. Use the same phone number on every device to see the same files.

## How it works

```
 Your phone ──┐
 Your laptop ─┼──►  Telegram  ──►  "TeDrive Storage"  (a private channel in your account)
 Your browser ┘                    "TeDrive Shared"   (public, only for files you share)
```

- **TeDrive is a Telegram client**, built on [TDLib](https://core.telegram.org/tdlib), Telegram's official client library. It signs in as you and talks to Telegram directly. In the browser, TDLib runs as WebAssembly.
- **Each file is a message** in a private channel called `TeDrive Storage`.
- **Everything TeDrive knows about a file is in the message caption**: fingerprint, album, original date, uploading device, custom name and share link. The whole drive can be rebuilt from the channel on any device, so there is no separate database to lose.
- **Share links** copy the file into a second, public channel (`TeDrive Shared`). The storage channel always stays private.
- **Your API credentials and session stay on your device.** On Android the session database is encrypted with a key held in the Android Keystore.

## Good to know

- **Keep a second copy of anything irreplaceable.** Telegram is not a contracted storage service, and accounts and policies can change.
- **Files are not end-to-end encrypted.** They are stored like any other Telegram cloud message.
- **Anyone with a share link can open that file.** Use Stop sharing to remove the public copy.
- **Automatic backup covers photos and videos**, while the app is open or in the background. It does not restart by itself after the phone reboots.
- **Linux** needs GTK 3 and a keyring service (GNOME Keyring or KWallet).

## Development

The Flutter app is in [`app/`](app).

```bash
cd app
flutter pub get
flutter run          # on a connected Android phone
dart test            # unit tests
```

| Path | What is in it |
| :--- | :--- |
| `app/lib/td/` | The TDLib binding: FFI on Android and desktop, tdweb in the browser |
| `app/lib/tedrive_service.dart` | Sign-in, channels, uploads, downloads, share links |
| `app/lib/drive_controller.dart` | The file list, upload queue and live updates from other devices |
| `app/lib/backup_controller.dart`, `backup_plan.dart` | Phone backup and free up space |
| `app/lib/stored_file.dart` | The file model and caption format |
| `app/lib/ui/` | Screens |
| `app/android/app/src/main/kotlin/` | Android: media library, background service, file picker, sharing |

**Builds.** [`release.yml`](.github/workflows/release.yml) builds Android, Windows, Linux, macOS and the web app on every push to `main`, compiling TDLib for desktop from source. Pushing a tag such as `v1.0.0` publishes a release. [`tdweb.yml`](.github/workflows/tdweb.yml) compiles TDLib to WebAssembly for the web app.

**Web hosting.** `app/vercel.json` builds and hosts the web app on Vercel. Import the repository and set **Root Directory** to `app`.

**Android signing.** Release APKs are signed with your key when the repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` are set; otherwise with a throwaway debug key. Keep the keystore backed up: without it, installed copies cannot be updated.

## Licence

[MIT](LICENSE).

TeDrive is an independent project. It uses the Telegram API and is not made or endorsed by Telegram.
