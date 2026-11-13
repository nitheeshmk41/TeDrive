# Publishing TeDrive on Google Play

The release workflow builds a Google Play bundle, `TeDrive-…-android-play.aab`, next to the APKs. Publishing it needs a Google Play developer account, which only the owner can create.

## 1. Before anything: the signing key

The bundle is built only when the four signing secrets are set (see [building.md](building.md#android-signing)). Google Play needs the same upload key for every version, forever. Keep `signing/tedrive-release.jks` and its passwords backed up somewhere safe outside this PC.

## 2. Create the developer account

1. Go to [play.google.com/console](https://play.google.com/console) and sign up (one-time fee of 25 US dollars, plus identity verification).
2. New personal accounts must run a **closed test with at least 12 testers for 14 days** before the app can go to production.

## 3. Create the app

1. **Create app** → name `TeDrive`, app, free.
2. **App content** (all required):
   - **Privacy policy:** `https://github.com/nitheeshmk41/TeDrive/blob/main/docs/privacy.md`
   - **Ads:** no ads.
   - **App access:** explain that sign-in needs a Telegram account and a free API ID from my.telegram.org. Give reviewers a test Telegram account if you can.
   - **Content rating:** fill in the questionnaire (file storage, no user-to-user content inside the app).
   - **Data safety:** no data collected or shared by the developer; files go to the user's own Telegram account. Data is encrypted in transit.
   - **Photo and video permissions:** declare that backing up the photo library is the app's core function.
   - **Foreground service (data sync):** declare that it keeps uploads and backups running; Google may ask for a short screen recording.
3. **Store listing:** short description, full description, the app icon (512×512, from `app/web/icons/Icon-512.png`), a feature graphic (1024×500) and at least two phone screenshots.

## 4. Upload

1. **Testing → Closed testing → Create release.**
2. Upload `TeDrive-v…-android-play.aab` from the GitHub release.
3. Let Google manage the app signing key (the default). Your key becomes the upload key.
4. Add testers, roll out, and after the testing period apply for production.

For each new version: tag a release as usual, then upload the new `.aab`. The Play build has no in-app updater; Google Play updates it.

## Things Google may question

- The app talks to Telegram with the user's own API credentials; it is a Telegram client, like many on the store.
- It must not use the Telegram name or logo as its own branding.
