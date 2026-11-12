# TeDrive roadmap

TeDrive has no backend and never will. Every app talks to Telegram directly and keeps all metadata in message captions (see [ARCHITECTURE.md](ARCHITECTURE.md)). Only features that work that way are on this roadmap.

Statuses: **Not started**, **Implemented** (built, compiles, logic unit-tested where possible), **Tested** (verified on a real device by the owner).

## Out of scope (needs a server)

Removed for good: email/password accounts, password-protected or expiring links, link access history, "shared with me" and collaborators, a Telegram bot inbox, server-side OCR or AI search, notifications pushed from a server.

## Done

| Feature | Status |
| :--- | :--- |
| Telegram sign-in, one storage channel shared by all devices | Tested |
| Upload queue, cancel, retry, duplicate skip, SHA-256 check | Tested |
| Catalogue rebuilt from channel history | Tested |
| Gallery by day, thumbnails, fullscreen viewer | Implemented |
| Video and audio player (streams on Android) | Implemented |
| Albums, move, rename, delete, search, filter, sort | Implemented |
| Phone backup (Wi-Fi only option), background upload | Implemented |
| Free up space after verified backup | Implemented |
| Share from gallery into TeDrive, TeDrive in the file picker | Implemented |
| Public share link, copy, stop sharing | Implemented |
| Live sync between devices, uploading device shown | Implemented |
| Account page: storage by type and device, cache limit | Implemented |
| Android, Windows, Linux, macOS and web builds | Implemented |
| Web app with real Telegram sign-in | Implemented, not yet verified |

## Suggested next features

Ordered by how much a user would notice, all without a backend. Pick from the top.

| # | Feature | Why it helps | Effort |
| :--- | :--- | :--- | :--- |
| 1 | **Multi-select and bulk actions** (delete, move to album, share, download) | Cleaning up 200 photos one by one is unusable | Medium |
| 2 | **Trash with restore** (30 days) | Protects against deleting by mistake. Done by moving a file's message to a hidden "TeDrive Trash" channel and back. | Medium |
| 3 | **Starred / Favorites** | Quick access; one caption key (`star:1`) | Small |
| 4 | **Recent and Large files views** | Find what filled the phone; pure filtering of the list | Small |
| 5 | **Find duplicates** screen | Frees space; SHA-256 is already stored on every file | Small |
| 6 | **Nested folders** | Matches how people organise documents | Medium |
| 7 | **EXIF details** (camera, date, GPS) and **photo map** | Google Photos feel; read from the file on device | Medium |
| 8 | **Memories** ("On this day") | A reason to open the app; just date filtering | Small |
| 9 | **Upload queue that survives a restart**, backup restart after reboot | Reliability on phones that kill apps | Medium |
| 10 | **Offline section** (pinned files and albums) | Works without internet; extends "Keep on this device" | Small |
| 11 | **App lock** (PIN or fingerprint) | Privacy if the phone is handed over | Small |
| 12 | **Encrypted vault** (files encrypted on the device before upload) | Real privacy for Aadhaar, PAN, certificates; files unreadable even to Telegram. Needs a careful recovery design: lose the passphrase, lose the files. | Large |
| 13 | **Nearby transfer** (phone to laptop over Wi-Fi, QR pairing) | Move big files without uploading | Large |
| 14 | **Album share link** | Send a whole trip's photos as one link | Medium |
| 15 | **Slideshow, rotate, crop** | Polish | Small to medium |

My recommendation: 1 to 5 first. They fix the daily frustrations and are mostly small.

## Known problems

- Share links made before the fix pointed at the wrong post. Use Stop sharing, then create the link again.
- A share link for a document opens a Telegram preview page.
- The integrity check cannot re-download a file whose original is still on the phone.
- TDLib is version 1.8.15 on every platform. If Telegram stops accepting it, move `TDLIB_COMMIT` forward and retest.
- Desktop and web apps are first builds with little real-world testing.
