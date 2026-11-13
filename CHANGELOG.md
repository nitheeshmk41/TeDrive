# Changelog

## v3.1.0

### Wi-Fi transfer, rebuilt
- New full-screen page: QR code, address, a 6-digit access code, a "Device connected" indicator and a live list of every file sent and received, with progress.
- New page for the other device: thumbnails, search, photo and video preview, select many and download them as one zip, drag and drop to send, with speed and progress per file. Works with no internet.
- **Security fix:** before, anyone on the same Wi-Fi could fetch any file from the device. Now every request needs the access code, only the files offered can be fetched, and transfer stops when the page is closed.
- Large files are written to disk as they arrive instead of being held in memory, and downloads can resume.

### Downloads
- The download dialog and the photo viewer now say what is happening: bytes and speed, or plainly that Telegram has sent nothing for a number of seconds.

## v3.0.2

- **Open in Telegram:** every file (share menu, file menu, photo viewer and the download dialog) and every folder can be opened in the Telegram app, to view or download it there.
- Fixed: the app stuttered during uploads and downloads. Each progress tick re-sorted the whole file list and redrew the screen; progress now redraws at most 4 times a second and leaves the list alone.
- Fixed: Cancel on "Preparing…" and "Downloading…" now closes at once, whatever Telegram is doing.
- A stalled download now writes what Telegram reported to the error log.

## v3.0.1

- Fixed: opening the original of a large photo could close the app. Photos are now decoded at screen size instead of full resolution.
- Fixed: a download that Telegram paused for a moment was reported as stopped. Only Cancel stops a download now, and slow connections get about 3 minutes before an error.
- While you open, send or load a file, new uploads wait, so the download gets the whole connection.
- Previews that failed to load are tried again.
- **Account → Copy error log** copies recent errors, to report a problem. The log stays on the device.

## v3.0.0

### Changed
- **Public share links are gone.** They opened on t.me, which many networks block. Files that still have a link from an older version show **Remove old public link**.

### Added
- **Send to a Telegram chat:** pick a chat and the file is forwarded inside Telegram, with no download and no data used. Works for many selected files at once.
- **Send a smaller copy** of a photo (about 300 KB) on Android.
- **Zip a folder and send it** as one file (phone and desktop).
- **Wi-Fi transfer** is now in the share menu.

## v2.0.5

- Photo viewer: opening a photo shows its preview at once and downloads nothing. **Load original** fetches the full-quality file only when you ask.
- Share links now open a TeDrive page with an **Open in Telegram app** button, because the t.me website is blocked on some networks.
- Updates: a banner with an **Update** button stays on screen when a new version exists, and the check also works when GitHub cannot be reached.

## v2.0.4

- Fixed: full photos (and any download) could stay on "Loading…" forever, on the web and on phones. Downloads now follow Telegram's progress updates, restart a download that goes quiet, and show **Try again** if it still cannot finish.
- Fixed: sharing a file in the web app did nothing, because browsers only allow sharing right after a click. Once the file is ready, a **Share** button appears, with **Download** as a fallback. Sharing a public link in the web app copies it.
- Optional: each release can post the APK to a Telegram channel, for phones whose browser cannot download APKs (Brave).

## v2.0.3

- Fixed: opening a photo or file could wait behind every thumbnail in the gallery and look stuck on "Loading full image…". Files you open now download first.
- Data saver: on mobile data, photos show their preview and download in full only when you tap **Load full photo**. Photos either side are fetched ahead only on Wi-Fi.
- Up to 3 uploads now run at the same time.
- Downloading or sharing several selected files fetches 4 at a time behind one progress bar, and saves them all to one folder.
- Sharing: **Send the file** comes first and works for everyone. Public links explain that some networks block the t.me website, and that the link opens when pasted into the Telegram app.
- Android APKs download directly from tedrive.vercel.app/download/, avoiding the GitHub redirect some browsers leave stuck at 100%.
- Web app: Wi-Fi transfer and the vault, which need a real file system, are hidden or explained instead of failing.

## v2.0.2

- Fixed: sharing a file in the web app could stay on "Creating link…" forever.
- Photo viewer: a soft blurred preview instead of a pixelated one while the full image loads, a sharper full image, the next and previous photos load in advance, and arrow keys and buttons on computers.
- New documentation in `docs/` (install, user guide, building, architecture), `CONTRIBUTING.md` and a rewritten README. Removed outdated planning notes.

## v2.0.1

- Windows and macOS builds fixed (fingerprint unlock is now Android and Mac only; macOS builds with the current Xcode).

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
