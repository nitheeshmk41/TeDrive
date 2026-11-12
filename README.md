# TeDrive 🚀

> Your personal unlimited cloud drive powered by your own Telegram account.

TeDrive turns your Telegram account into an unlimited, personal cloud storage system. Files are stored directly in your own private Telegram channel with no intermediate servers, no monthly subscriptions, and no file size limits up to 2 GB per file (4 GB with Telegram Premium).

---

## ✨ Features

- **Direct Telegram MTProto (TDLib)**: Connects directly from your device to Telegram's official client library via native FFI. No third-party servers, Cloudflare workers, or bot limits.
- **Large File Support**: Back up photos, documents, and videos up to 2 GB per file.
- **Automated Phone Backup**: Background sync for photos, videos, and selected device albums (Camera, WhatsApp, Downloads).
- **Gallery & Media Viewer**: Built-in photo viewer, video streaming, categorization, and search.
- **Secure & Private**: Your Telegram API credentials and session keys stay strictly on your device.
- **Cross-Platform Ready**: Targeted for Android with Web preview simulation mode.

---

## 📱 Getting Started

### 1. Requirements
- Android 8.0+ (ARM64 recommended)
- Telegram account
- Telegram API ID & API Hash (free from [my.telegram.org](https://my.telegram.org))

### 2. Setup API Credentials
1. Visit [my.telegram.org](https://my.telegram.org) and sign in with your phone number.
2. Select **API development tools**.
3. Create a new app (enter any app title and short name).
4. Copy your `api_id` and `api_hash` into TeDrive during first launch.

---

## 🛠️ Development & Building

```powershell
# Run on Android
cd app
flutter run

# Run on Web Preview
flutter run -d chrome

# Build Android APK
flutter build apk --target-platform android-arm64
```

---

## 📄 License
MIT License.
