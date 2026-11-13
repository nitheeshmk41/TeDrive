<div align="center">

<img src="app/assets/icon/app_icon.png" alt="TeDrive logo" width="140" height="140">

# TeDrive

**A personal cloud drive and photo library that stores everything in your own Telegram account.**

No subscription. No TeDrive server. Your files stay in a private channel only you can see.

[**Download**](https://github.com/nitheeshmk41/TeDrive/releases/latest) · [**Open the web app**](https://tedrive.vercel.app) · [**Install guide**](docs/install.md) · [**User guide**](docs/user-guide.md)

<img src="https://img.shields.io/github/v/release/nitheeshmk41/TeDrive?style=for-the-badge&label=release" alt="Latest release" />
<img src="https://img.shields.io/badge/Android%20%C2%B7%20Windows%20%C2%B7%20macOS%20%C2%B7%20Linux%20%C2%B7%20Web-555?style=for-the-badge" alt="Platforms" />
<img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="MIT License" />

</div>

---

## Why TeDrive

Phones fill up, and cloud plans charge every month. Telegram already stores files up to 2 GB each for free. TeDrive turns that storage into a real drive: a photo timeline, folders, phone backup and sharing, on every device you own.

## Features

| | |
| :--- | :--- |
| 📸 **Photo library** | Day-by-day timeline, "On this day" memories, a map of where photos were taken, EXIF details |
| 📁 **Drive** | Nested folders, multi-select, starred, recent, large files, duplicates, Trash with 30-day restore |
| 🔄 **Phone backup** | Background backup of chosen albums (Wi-Fi or charging only), then **Free up space** safely |
| 📤 **Sharing** | Send files to any app, forward to a Telegram chat with no data used, send a smaller photo, or zip a whole folder |
| 🔐 **Vault** | Documents encrypted on your device before upload; even Telegram cannot read them |
| 🔒 **App lock** | PIN or fingerprint |
| 📶 **Wi-Fi transfer** | Phone to laptop over local Wi-Fi with a QR code |
| ⬆️ **Updates** | Check for updates in the app; new versions install over the old one |
| 💻 **Everywhere** | Android, Windows, macOS, Linux and the browser, all in sync |

## Download

| Platform | File |
| :--- | :--- |
| Android (most phones) | [**TeDrive-android-arm64.apk**](https://tedrive.vercel.app/download/TeDrive-android-arm64.apk) |
| Android (old 32-bit phones) | [TeDrive-android-arm32.apk](https://tedrive.vercel.app/download/TeDrive-android-arm32.apk) |
| Windows 10/11 | `TeDrive-…-windows-x64.zip` |
| macOS (Apple Silicon) | `TeDrive-…-macos-arm64.dmg` |
| Linux x64 | `TeDrive-…-linux-x64.tar.gz` |
| Browser | [tedrive.vercel.app](https://tedrive.vercel.app) |

The Android links always give the newest version. All files are also on the [latest release](https://github.com/nitheeshmk41/TeDrive/releases/latest). Step-by-step instructions, including what to do if a download stops at 100%, are in the [install guide](docs/install.md).

## Quick start

1. Get a free API ID and hash at [my.telegram.org](https://my.telegram.org) → **API development tools**.
2. Open TeDrive, paste them, and sign in with your phone number.
3. Sign in with the same number on your other devices to see the same files.

## How it works

```
Android · Windows · macOS · Linux · Web
                │
          TDLib (Telegram's official library)
                │
Telegram ──► "TeDrive Storage"  private channel, one message per file
```

File details (fingerprint, folder, date, location) are kept in each message's caption, so the whole drive rebuilds itself on any device. More in [docs/architecture.md](docs/architecture.md).

## Documentation

- [Install and update](docs/install.md)
- [User guide](docs/user-guide.md)
- [Building from source and releasing](docs/building.md)
- [Architecture](docs/architecture.md)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)

## License

[MIT](LICENSE). TeDrive is an independent project that uses the Telegram API. It is not affiliated with or endorsed by Telegram.

> Keep a second copy of anything irreplaceable. Telegram is not a contracted storage service.
