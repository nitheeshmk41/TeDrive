# TeDrive architecture

## One sentence

Every TeDrive app is a Telegram client that stores files as messages in the user's own private channel and keeps all metadata in the message captions. There is no TeDrive server.

## Components

```
Flutter UI (app/lib/ui)
      │
DriveController / BackupController        state, upload queue, live updates
      │
TeDriveService                            sign-in, channels, upload, download, share links
      │
TdClient ──► TDLib                        FFI (Android, Windows, Linux, macOS)
                                          tdweb / WebAssembly (browser)
      │
Telegram ──► "TeDrive Storage" (private channel)   one message per file
             "TeDrive Shared"  (public channel)    copies of files the user shared
```

Android-only native code (`app/android/app/src/main/kotlin`): media library access, the foreground service that keeps uploads alive, the documents provider for the system file picker, the share receiver, and sharing out.

## The caption is the database

Each file's message caption holds one `key:value` per line:

| Key | Meaning |
| :--- | :--- |
| `sha256` | Fingerprint of the file's bytes |
| `folder` | Album name |
| `time` | When the photo or video was taken (seconds since 1970) |
| `device` | Device that uploaded it |
| `name` | Custom name after a rename |
| `share` | Public link, if shared |

Reading the channel history rebuilds the whole drive on any device. Changes made on one device reach the others as Telegram updates. Parsing lives in `app/lib/stored_file.dart` and is unit-tested.

## Decisions and why

| Decision | Reason |
| :--- | :--- |
| TDLib as the user, not a bot | 2 GB files instead of 20 MB; can list history; no server holding a token |
| No backend, no database | Zero hosting cost; nothing to breach; survives the author walking away |
| Metadata in captions | The drive is self-describing and recoverable with no extra store |
| Each user brings their own API ID | Telegram's terms for third-party clients; no shared secret in the app |
| TDLib pinned to one version on all platforms | Identical behaviour everywhere |
| Share links via a separate public channel | The storage channel never becomes public |
| Uploads from backup read the original in place | No second copy on a full phone; TeDrive never deletes outside its own cache |

## Limits that follow from the design

- No server-side features: link passwords, expiry, access logs, bot inbox, accounts other than Telegram.
- Files are not end-to-end encrypted (ordinary Telegram cloud messages).
- Telegram is not a contracted storage service.

## Builds

`.github/workflows/release.yml` builds all platforms and compiles TDLib from source for desktop. `tdweb.yml` compiles TDLib to WebAssembly once and publishes it as a release asset, which the web build downloads (`app/tool/fetch_tdweb.sh`).
