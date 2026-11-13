# TeDrive architecture

## One sentence

Every TeDrive app is a Telegram client that stores files as messages in the user's own private channel and keeps all metadata in the message captions. There is no TeDrive server.

## Components

```
Flutter UI (app/lib/ui)
      │
DriveController / BackupController        state, upload queue, live updates
      │
TeDriveService                            sign-in, channels, upload, download, forwarding
      │
TdClient ──► TDLib                        FFI (Android, Windows, Linux, macOS)
                                          tdweb / WebAssembly (browser)
      │
Telegram ──► "TeDrive Storage" (private channel)   one message per file
             "TeDrive Shared"  (public channel)    only from versions before 3.0, which made public links
```

Android-only native code (`app/android/app/src/main/kotlin`): media library access, the foreground service that keeps uploads alive, the documents provider for the system file picker, the share receiver, and sharing out.

## The caption is the database

Each file's message caption holds one `key:value` per line:

| Key | Meaning |
| :--- | :--- |
| `sha256` | Fingerprint of the file's bytes |
| `folder` | Folder or album path, `/` separated for nested folders |
| `time` | When the photo or video was taken (seconds since 1970) |
| `device` | Device that uploaded it |
| `name` | Custom name after a rename |
| `share` | Public link, if shared |
| `albumshare` | Public link for a whole album |
| `star` | Starred |
| `trash` | When it was moved to Trash (deleted for good after 30 days) |
| `geo` | Where a photo was taken (from its EXIF data) |
| `camera` | Camera model (from EXIF) |
| `vault` | The file is encrypted on the device before upload |

Reading the channel history rebuilds the whole drive on any device. Changes made on one device reach the others as Telegram updates. Parsing lives in `app/lib/stored_file.dart` and is unit-tested.

## Decisions and why

| Decision | Reason |
| :--- | :--- |
| TDLib as the user, not a bot | 2 GB files instead of 20 MB; can list history; no server holding a token |
| No backend, no database | Zero hosting cost; nothing to breach; survives the author walking away |
| Metadata in captions | The drive is self-describing and recoverable with no extra store |
| Each user brings their own API ID | Telegram's terms for third-party clients; no shared secret in the app |
| TDLib pinned to one version on all platforms | Identical behaviour everywhere |
| No public links (removed in 3.0) | t.me is blocked on many networks; files are sent directly or forwarded inside Telegram |
| Uploads from backup read the original in place | No second copy on a full phone; TeDrive never deletes outside its own cache |

## Limits that follow from the design

- No server means no accounts other than Telegram, no link passwords or expiry, no access logs and no bot inbox. These are out of scope, not postponed.
- Ordinary files are Telegram cloud messages, not end-to-end encrypted. Files in the Vault are encrypted on the device with a passphrase that never leaves it; forget it and they cannot be recovered.
- Telegram is not a contracted storage service.

## Builds

`.github/workflows/release.yml` builds all platforms on every push to `main`, and publishes a GitHub release when a `v*` tag is pushed. It compiles TDLib from source for desktop. `tdweb.yml` compiles TDLib to WebAssembly once and publishes it as a release asset, which the web build downloads (`app/tool/fetch_tdweb.sh`).

## Updates

The app asks the GitHub API for the latest release (`app/lib/updater.dart`). On Android it downloads the APK for the phone's processor and opens the system installer. Because every release APK is signed with the same key, it installs over the old version and keeps all data. A release built without the signing secrets would not install over an existing copy, so the workflow warns when they are missing.
