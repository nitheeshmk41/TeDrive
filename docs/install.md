# Install and open TeDrive

TeDrive runs on Android, Windows, macOS, Linux and in the browser. Every version signs in to the same Telegram account, so your files are the same everywhere.

Downloads are on the [latest release page](https://github.com/nitheeshmk41/TeDrive/releases/latest).

## Before you start: get a Telegram API ID (once)

TeDrive talks to Telegram as your own app, so it needs an API ID and hash. They are free.

1. Open [my.telegram.org](https://my.telegram.org) and sign in with your Telegram phone number.
2. Choose **API development tools**.
3. Create an app. Any title works, for example `TeDrive`. Platform: Android.
4. Keep the page open: you will paste **App api_id** and **App api_hash** into TeDrive.

Never share the hash with anyone, including in bug reports.

## Android

1. On the phone, open **[tedrive.vercel.app/download/TeDrive-android-arm64.apk](https://tedrive.vercel.app/download/TeDrive-android-arm64.apk)** (most phones). Old 32-bit phones need [TeDrive-android-arm32.apk](https://tedrive.vercel.app/download/TeDrive-android-arm32.apk). These links always give the newest version.
2. Open the downloaded file and tap **Install**. If Android asks, allow your browser or file manager to **install unknown apps**.
3. Open TeDrive, paste the API ID and hash, enter your phone number and the code Telegram sends you.

### Download stuck at 100% (Brave and some other browsers)

Brave's Android download manager sometimes never finishes a download. The file on the server is fine; the browser is the problem. Any of these works:

- **Use Chrome or Firefox** for the one-time download. After that, TeDrive updates itself (see below), so the browser is never needed again.
- **Send it through Telegram:** on a computer, download the APK and send it to your own **Saved Messages** in Telegram. On the phone, open Saved Messages, tap the file, then tap it again to install.
- If the project's Telegram channel is set up, the newest APK is posted there automatically. Tap it in the Telegram app to install.
- If a download did get stuck, open your **Files** app → **Downloads**: the APK is sometimes already complete there.

### Updating

You never need to uninstall. In TeDrive open **Account → Check for updates** (TeDrive also checks when it starts). Tap **Download and install**; Android installs the new version over the old one and keeps your sign-in, files and settings.

Installing a newer APK by hand from the release page works the same way.

## Windows

1. Download `TeDrive-…-windows-x64.zip`.
2. Right-click it, **Extract All**, open the `TeDrive` folder and run `TeDrive.exe`.
3. If SmartScreen says "Windows protected your PC", choose **More info → Run anyway** (the app is not code-signed).

To update, extract the new zip over the old folder.

## macOS (Apple Silicon)

1. Download `TeDrive-…-macos-arm64.dmg`, open it and drag **TeDrive** to **Applications**.
2. The first time, right-click TeDrive in Applications and choose **Open** (the app is not notarised).

## Linux (x64)

```bash
tar -xzf TeDrive-*-linux-x64.tar.gz
./TeDrive/tedrive
```

It needs GTK 3, OpenSSL 3 and a keyring (GNOME Keyring or KWallet), which most desktops already have.

## Web

Open [tedrive.vercel.app](https://tedrive.vercel.app) in Chrome, Edge or Firefox. Nothing to install. Phone backup is an Android feature and is not available in the browser.

## Signing out and removing

**Account → Log out** ends the session on that device. Your files stay in your Telegram account in the private **TeDrive Storage** channel. Uninstalling the app does not delete them.
