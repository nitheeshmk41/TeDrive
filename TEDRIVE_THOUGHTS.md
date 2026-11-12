# TeDrive: Review, Feasibility and Recommended Path

> Verdict: **Feasible and worth building, but not with the architecture in the summary.**
> The Bot API plus Cloudflare Worker design cannot meet your real goal (backing up videos and photos from a 64 GB phone). A small change to the architecture fixes that and also makes the project simpler.

---

## 1. Your real goal

You want to:

1. Free up a 64 GB phone by moving photos, videos, WhatsApp media and downloads to the cloud.
2. Browse them like a gallery.
3. Pick a photo from the cloud and send it to someone.
4. Pay nothing.

Every decision below is judged against that list, not against the feature list in the summary.

---

## 2. The biggest problem: the 20 MB limit

The plan uses the **Telegram Bot API** through a Cloudflare Worker. The Bot API limits are:

| Operation | Limit |
|---|---|
| Upload | 50 MB |
| Download | **20 MB** |

The summary proposes a 20 MB cap for the first version. For your use case that is not a small cap, it is a failure:

- A phone video is usually 50 MB to 2 GB.
- WhatsApp videos and downloads are often over 20 MB.
- Many 4K or 12 MP+ photos are large.

With the Bot API you could back up photos but not most of the videos, which are the files that fill the phone. Splitting files into chunks is a workaround, but it gets complicated and fragile.

**Conclusion: the Bot API plus Worker design is wrong for your main goal.**

---

## 3. Recommended architecture: talk to Telegram directly from the phone

Telegram has two ways to be used by programs:

| | Bot API (current plan) | **MTProto / TDLib (recommended)** |
|---|---|---|
| Logs in as | A bot | **Your own Telegram account** |
| Max file size | 50 MB up / 20 MB down | **2 GB per file** (4 GB with Telegram Premium) |
| List old files | No | **Yes, you can read the channel history** |
| Needs a server | Yes (the Worker) | **No** |
| Works inside Flutter | Via HTTP | Via TDLib native library |

TDLib is Telegram's official client library. The Telegram app itself uses the same protocol.

### What this changes

```
Phone (Flutter + TDLib)  ──────►  Telegram  (private channel or Saved Messages)
        │
        └── local cache + thumbnails (SQLite)
```

- **No Cloudflare Worker.** There is no backend, so there is nothing to host, secure or pay for.
- **No secret to leak.** Your login lives only on your phone, so there is no bot token or shared API key problem.
- **The catalogue is recoverable.** Because a user account can read the channel history, you can rebuild your file list on a new phone by logging in again. This removes the "biggest architectural risk" in the summary.
- **Files up to 2 GB**, which covers almost all phone videos.

### Trade-offs to know about

- You need a free `api_id` and `api_hash` from <https://my.telegram.org>. This is normal and allowed.
- TDLib integration in Flutter is harder than writing `dio.post()`. There are community Dart bindings for TDLib, but their quality varies, so **verify one works before committing** (see Phase 0).
- The binary adds roughly 20 to 40 MB to the app.
- Automating many uploads with a user account can hit Telegram flood limits. Upload sequentially and respect wait times.
- The web viewer is harder: it would need its own TDLib/MTProto login, which is awkward in a browser. Defer it. Telegram Web already shows the channel, which is a decent stand-in.

### Fallback if TDLib in Flutter turns out to be painful

Keep Flutter for the UI and write a thin native Kotlin layer around TDLib (Android is your only target). Flutter talks to it through a platform channel. More work, but proven.

---

## 4. Is it reliable?

**Reasonably, with caveats. Treat it as a very good second home for your files, not the only one.**

| Risk | Honest assessment | Mitigation |
|---|---|---|
| Telegram bans the account or removes the channel | Low for personal use, but not zero. Heavy automated uploads from a new account look suspicious. | Use your real, established account. Upload at a gentle pace. Keep a second backup of irreplaceable photos. |
| Telegram changes policy or limits | Possible over time. It is not a contractual storage service. | Keep export ability: store files with readable names and dates so you can bulk-download them. |
| Terms of Service | Using Telegram as personal storage is widely done and tolerated. Using it at large scale for others, or as a public service, is riskier. | Keep TeDrive personal-use. Be careful if you ever make it a multi-user service. |
| Data loss on your side | Deleting local copies before verifying the upload. | **Never delete from the phone until the upload is confirmed** (see section 6). |
| No end-to-end encryption | Regular Telegram cloud chats are not end-to-end encrypted. | Optionally encrypt files on the phone before upload (later phase). |

Rule of thumb: photos and videos you could not bear to lose should exist in two places.

---

## 5. Can we complete it? Can we extend it?

**Complete:** yes. A solo developer can build a useful version in stages. The upload, browse and download core is small. The hard parts are background uploads and the gallery experience, and both are well-understood on Android.

**Extend (later, optional):**

- Read-only web viewer, once the metadata strategy is settled.
- Encryption before upload.
- Duplicate detection by SHA-256.
- Smart "free up space" with a safe delete flow.
- Share to any app via the Android share sheet.
- Multi-device access (a second phone logs in with the same account and sees the same channel).

---

## 6. Features that matter for *your* goal

These are not in the original summary, but they decide whether the app is actually useful.

### Free up space safely
Backup alone does not free the phone. The app needs a "Free up space" action that deletes local copies only after verifying each file (size and checksum match what Telegram has). On Android 11+ deleting media requires a system confirmation dialog, so expect that prompt.

### Gallery feel needs thumbnails
Downloading a 2 GB video just to see it in a grid is unusable. When uploading, also upload or store a small thumbnail (a few KB) so the gallery loads instantly, and cache it locally. Full files download only on open.

### WhatsApp media
Android restricts access to other apps' folders. The WhatsApp media folder (`Android/media/com.whatsapp/WhatsApp/Media`) must be accessed through the Storage Access Framework, where you grant folder access once. Be careful about chat history: WhatsApp's own chat backup file is encrypted and tied to WhatsApp, so it is better to back up the **media** and use WhatsApp's own export for chat text if you need it.

### Sending a photo from TeDrive
Two levels:

1. **Easy (MVP):** open a photo in TeDrive, tap Share, and the Android share sheet sends it to WhatsApp or anywhere.
2. **Advanced:** appear in other apps' file pickers (WhatsApp's attach menu) by implementing an Android `DocumentsProvider`. This is native Kotlin work and should wait until later.

---

## 7. Stack recommendation

| Layer | Choice | Why |
|---|---|---|
| Mobile app | **Flutter** (Android first) | Your preference; fine for this UI |
| Telegram access | **TDLib** (via Dart binding, or a native Kotlin bridge) | 2 GB files, history, no server |
| Local database | **SQLite** (`drift` or `sqflite`) | Catalogue, upload queue, thumbnails index |
| State management | **Riverpod** | Simple and testable |
| Background uploads | **WorkManager** (`workmanager` package) | Survives app close |
| Media scanning | `photo_manager` | Reads the device gallery efficiently |
| Backend | **None** | Nothing to host or pay for |
| Cost | **0** | Telegram, Flutter, TDLib are all free |

Cloudflare Worker, Appwrite and Next.js are **not needed for the first versions**. Drop them for now. They only come back if you decide on a web viewer or multi-user features.

---

## 8. Step-by-step development plan

Each phase ends with something you can test on your own phone. Do not start a phase until the previous one passes.

### Phase 0: Prove it works (the spike, 1 to 3 days)
Goal: de-risk the one thing that could sink the project.
- Create a Telegram `api_id` / `api_hash`.
- Make a private channel named `TeDrive Storage`.
- In a minimal Flutter app: log in with phone number and code, send one **100 MB video** to the channel, then download it back.
- Compare SHA-256 of original and downloaded file.

**Pass:** a 100 MB file round-trips intact. If the Dart TDLib binding fails here, switch to the Kotlin bridge before going further.

### Phase 1: Manual upload and browse
- Pick files and upload with progress.
- Store each upload in SQLite (name, size, date, Telegram message ID).
- File list screen, open, download, share.

### Phase 2: Gallery experience
- Thumbnails generated on upload and cached.
- Grid view by date, folder organization.
- Image and video preview, search by name.

### Phase 3: Automatic backup
- Scan camera folder, WhatsApp media and Downloads for new files.
- Background upload queue with retry, Wi-Fi-only and charging-only options.
- Pause and resume.
- Duplicate detection by hash.

### Phase 4: Free up space
- Verify each uploaded file, then offer to delete the local copy.
- Clear status: backed up, pending, failed.

### Phase 5: Polish and recovery
- Rebuild the catalogue from the channel history on a new phone.
- Export and import metadata.
- Optional encryption.

### Phase 6 (optional): Web viewer and open-source release
- Decide the web approach only after the app works.
- Licence, README, setup guide.

---

## 9. Second opinion: points added after review

An independent review of this plan agreed with the TDLib direction. These points from it are worth keeping:

- **Session security.** TDLib logs in as your real Telegram account. A leaked TDLib session database exposes your whole account, not just TeDrive files. Keep the database in app-private storage, set a TDLib database encryption key, and keep that key in Android Keystore (`flutter_secure_storage`). Never include the session in backups or logs.
- **API terms.** TeDrive is a custom Telegram client. Use your own `api_id`, don't reuse someone else's, and follow Telegram's API terms (<https://core.telegram.org/api/terms>).
- **Recovery has limits.** Rebuilding the catalogue from channel history only works while the channel and messages still exist and the account can reach them. Deleted messages are gone.
- **Web viewer.** The website cannot reuse the phone's session. It would need its own login, for example TDLib compiled to WebAssembly. Postpone it.
- **Platform.** Android first. The Dart `tdlib` package is Android-focused, so don't promise iOS until it is tested.
- **Local cache.** TDLib has its own internal database and can serve channel history from it. Start with that and add a separate SQLite table only for what TDLib doesn't give you: thumbnails index, upload queue, backup state.
- **Download source of truth.** TDLib reports file sizes and local paths, so SHA-256 checks should be done on the downloaded file against a hash computed before upload. Store that hash in the message caption (for example `sha256:<hex>`) so it survives a catalogue rebuild.

Phase 0 should therefore prove four things on a real Android phone: login (including two-step password), reading channel history, a 100 MB round trip with matching SHA-256, and a session that survives an app restart.

---

## 10. What I would do first

1. Make the Telegram account items from your checklist (`api_id`, private channel). Skip the bot and Cloudflare account for now.
2. Install Flutter and Android Studio, and plug in your phone with USB debugging.
3. Run **Phase 0**. Everything else depends on its result.

I am ready to start Phase 0 whenever you are.
