# TeDrive roadmap

Status of every area in the product specification. Statuses: **Not started**, **In progress**, **Implemented** (built, compiles, logic unit-tested where possible), **Tested** (verified on a real device), **Blocked**.

Only items the owner has confirmed on a phone are marked Tested.

## Architecture decision

The specification suggests a FastAPI backend, PostgreSQL and a Telegram bot. TeDrive deliberately does not use them:

- **Zero budget.** A backend and database need hosting that stays up. The current design needs none.
- **File size.** A bot can upload 50 MB and download 20 MB. TeDrive signs in as the user through TDLib and handles 2 GB files.
- **Privacy.** With no server, nobody but the user and Telegram ever holds the files or the session.

So: every client talks to Telegram directly, and all metadata lives in message captions in the user's own channel. See [ARCHITECTURE.md](ARCHITECTURE.md).

Consequences, stated plainly:

- Features that need a server are **Blocked** under this design: password-protected or expiring links, access history, a bot inbox, email/password accounts, server-side OCR.
- "Users, sessions, devices, permissions" tables do not exist. The Telegram account is the account.

## Milestone 1: Foundation

| Feature | Status |
| :--- | :--- |
| Telegram sign-in (phone, code, two-step password) | Tested |
| Storage channel, found or created, same on every device | Tested (one device); multi-device Implemented |
| Upload, download, SHA-256 integrity | Tested |
| Catalogue rebuilt from channel history | Tested |
| Per-user API credentials entered in the app | Tested |

## Milestone 2: Drive

| Feature | Status |
| :--- | :--- |
| Multi-file upload queue, cancel, retry, duplicate skip | Tested |
| Open, download, rename, delete, file details | Implemented |
| Albums (flat folders), move between them | Implemented |
| Search by name, filter by type, sort | Implemented |
| List and grid views | Implemented |
| Nested folders, breadcrumbs, folder colours | Not started |
| Starred, Recent, Trash with restore | Not started |
| Multi-select and bulk actions | Not started |
| Copy / duplicate files | Not started |
| Drag-and-drop, right-click menus, keyboard shortcuts | Not started |
| File versions | Not started |

## Milestone 3: Photos and video

| Feature | Status |
| :--- | :--- |
| Timeline grouped by day, by date taken | Implemented |
| Thumbnails for photos and videos | Implemented |
| Fullscreen viewer with zoom and swipe | Implemented |
| Video and audio player, streaming on Android | Implemented |
| EXIF details (camera, lens, GPS) | Not started |
| Memories, photo map, slideshow | Not started |
| Photo editing (crop, rotate) | Not started |
| Similar-photo detection, face grouping | Not started |
| Playback speed, subtitles, picture-in-picture | Not started |

## Milestone 4: Reliability

| Feature | Status |
| :--- | :--- |
| Phone backup of chosen albums, Wi-Fi only option | Implemented |
| Background uploads (foreground service) | Implemented |
| Free up space after verified backup | Implemented |
| Share from gallery into TeDrive | Implemented |
| Cache kept under 1 GB | Implemented |
| Upload queue that survives an app restart | Not started |
| Backup that restarts after reboot | Not started |

## Milestone 5: Sharing

| Feature | Status |
| :--- | :--- |
| Send a file to any app (share sheet) | Implemented |
| TeDrive in Android's file picker | Implemented |
| Public link per file, copy, stop sharing | Implemented |
| QR code for a link | Not started |
| Share an album | Not started |
| Password / expiring links, access history | Blocked (needs a server) |
| Shared with me, collaborators, permissions | Blocked (needs a server) |

## Milestone 6: Intelligence

| Feature | Status |
| :--- | :--- |
| Storage breakdown by type and by device | Implemented |
| Duplicate detection (exact, by SHA-256) | Implemented at upload; no "find duplicates" screen |
| Largest / oldest files, cleanup suggestions | Not started |
| OCR, natural-language search | Not started |

## Milestone 7: Advanced

| Feature | Status |
| :--- | :--- |
| Offline pinning | Partly: "Keep on this device" exists; no Offline section |
| Personal vault (PIN, client-side encryption) | Not started |
| Nearby transfer | Not started |
| Cloud spaces | Not started |
| Telegram inbox via a bot | Blocked (needs a server). Workaround: forward files to the `TeDrive Storage` channel in Telegram; they appear in TeDrive. |

## Milestone 8: Production readiness

| Feature | Status |
| :--- | :--- |
| Android, Windows, Linux, macOS and web builds in CI | Implemented |
| Web app with real Telegram sign-in (TDLib in WebAssembly) | Implemented, not yet verified with a real sign-in |
| Desktop apps verified by a real sign-in | Not started |
| Android release signing key | Key generated locally; repository secrets not yet set |
| Unit tests (78, pure logic) | Implemented |
| Widget and integration tests | Not started |

## Known problems

- Share links created between the `a090c90` and this fix pointed at the wrong post. Use **Stop sharing**, then create the link again.
- A share link for a document opens a Telegram preview page; downloading the file from there needs Telegram. Photos and videos show directly only if a copy was on the device when the link was made.
- Integrity check cannot re-download a file whose original is still on the phone.
- TDLib is version 1.8.15 (2023) on every platform. Telegram may stop accepting it one day; the fix is to move `TDLIB_COMMIT` forward and retest.

## Next up

Milestone 2 gaps, in this order: multi-select with bulk delete/move/share, Starred, Trash with restore, nested folders.
