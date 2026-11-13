# TeDrive privacy policy

*Last updated: 13 November 2026*

TeDrive is a client for your own Telegram account. It has no server of its own.

## What TeDrive handles

- **Your Telegram sign-in.** You sign in with your phone number and Telegram's login code. The session is stored on your device only.
- **Your Telegram API ID and hash**, which you create at my.telegram.org. Stored on your device only.
- **Your files.** Files you add, and photos and videos you choose to back up, are uploaded to a private channel in your own Telegram account. They go directly from your device to Telegram.
- **Photo details.** The location and camera model inside a photo's EXIF data are read on your device and saved with the file in your Telegram channel, so the photo map works.
- **What is in your photos.** On Android, TeDrive looks at your photos on the device (Google ML Kit, with its models built into the app) to find things, printed text and faces, so that search and smart albums work. The results are kept in a file on your device only. Nothing is uploaded, and faces are only counted, not identified.
- **Vault files** are encrypted on your device with your passphrase before upload. The passphrase never leaves your device.

## What TeDrive does not do

- It does not send your data, files, contacts or usage to the TeDrive developer or to anyone other than Telegram.
- It has no analytics, advertising or tracking.
- It does not sell or share data.

## Permissions

| Permission | Why |
| :--- | :--- |
| Photos and videos | To show and back up the photos and videos you choose |
| Notifications | To show backup progress |
| Run in the background (foreground service) | So a backup or upload finishes when the app is not on screen |
| Fingerprint | Optional app lock |
| Internet and network state | To talk to Telegram, and to back up on Wi-Fi only |

## Third parties

Your files are stored by [Telegram](https://telegram.org/privacy) under Telegram's own privacy policy. Map tiles in the photo map are loaded from [OpenStreetMap](https://wiki.osmfoundation.org/wiki/Privacy_Policy), which sees the map area being shown. The update check (outside Google Play) asks GitHub for the latest version number.

## Deleting your data

Delete files in TeDrive, or delete the **TeDrive Storage** channel in Telegram. Uninstalling TeDrive removes everything it kept on the device.

## Contact

Open an issue at https://github.com/nitheeshmk41/TeDrive/issues.
