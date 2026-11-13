# Changelog

## v2.0.0

### Added
- **Check for updates** (Account page, plus a quiet check on launch). On Android it downloads the new APK and opens the system installer, which installs over the old version: sign-in, files and settings are kept. On desktop it opens the download page.
- Fingerprint or face unlock for App Lock.
- Real OpenStreetMap map of where photos were taken, on the Map view and in photo details.
- Drag and drop files onto the desktop window to upload them.
- Version number shown under About.

### Fixed
- Photo map and details never showed a location: GPS and camera model are now read from each photo's EXIF data at upload.
- The Wi-Fi transfer QR code was a decorative pattern no phone could scan. It is now a real QR code.
- App Lock re-locked every time the file picker or share sheet opened. It now locks after 30 seconds in the background.
- The macOS .dmg was never built (unsupported build flag). It is now part of the release.
- The vault description wrongly said AES; it is an HMAC-SHA256 stream cipher with encrypt-then-MAC.

## v2-beta

- Nested folders with breadcrumb navigation and recursive subfolder browsing.
- Photo details sheet with EXIF camera details, capture time, resolution, and interactive GPS map view.
- World photo map explorer for all geotagged photos.
- "On this day" memories in Photos.
- Encrypted document vault (client-side PBKDF2 + AES-256 CTR + HMAC-SHA256) for sensitive files (Aadhaar, PAN, Passport, Driving License, Certificates).
- Local phone-to-laptop Wi-Fi transfer with built-in HTTP portal and QR code.
- App Lock with secure 4-digit PIN (PBKDF2 hash) and auto-lock on app background.
- Persisted upload queue surviving app kills and phone restarts.
- Dedicated Offline section with local storage cache view.
- Album share links with one-tap clipboard copy.
- Modernized onboarding UI with popular country chips (+91, +1, +44, +971, +49, +65, +61) and dial code search.
- Responsive desktop layout with NavigationRail and keyboard shortcuts.
- Web UI theme toggle (Dark / Light) with immediate mode switching.
- Multi-select with bulk star, move, share, download and move to trash.
- Trash with Undo and restore; items are deleted for good after 30 days.
- macOS disk image (.dmg), Windows EXE, Linux tarball, Android APK release builds.

## Unreleased

### Fixed
- Share links pointed at the wrong post. The link is now made only after Telegram has stored the public copy and given it its permanent number.
- The public copy of a shared file no longer carries the private caption (album, device name, fingerprint); it shows only the file name.

### Added
- `ROADMAP.md`, `ARCHITECTURE.md` and this changelog.

## v1-beta

- Web app that signs in to Telegram in the browser (TDLib in WebAssembly).
- Public share links, rename, share from the gallery into TeDrive.
- Day-by-day gallery, account and storage page, automatic cache limit.
- Windows, Linux and macOS builds.
- Cross-device sync, device name on each file, in-app video and audio player.
- Phone backup, free up space, albums, thumbnails.
