package dev.tedrive.tedrive

import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import java.io.File

/**
 * Downloads a TeDrive update in the background with Android's own download
 * manager, so it carries on when the app is closed or the phone is
 * locked, and shows its progress in the notification bar. When it is
 * complete and signed with the same key as this app, a notification
 * offers to install it; the app, if open, offers the same.
 */
object AppUpdate {
    private const val PREFS = "tedrive_update"
    private const val CHANNEL_ID = "app_updates"
    private const val NOTIFICATION_ID = 4

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun dir(context: Context): File? =
        context.getExternalFilesDir(null)?.let { File(it, "updates") }

    /** Starts downloading [url] (version [tag]). False if it cannot. */
    fun start(context: Context, url: String, tag: String): Boolean {
        return try {
            val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            val old = prefs(context).getLong("id", -1)
            if (old >= 0) manager.remove(old)
            val dir = dir(context) ?: return false
            dir.deleteRecursively()
            dir.mkdirs()
            val target = File(dir, "TeDrive-$tag.apk")
            val id = manager.enqueue(
                DownloadManager.Request(Uri.parse(url))
                    .setTitle("TeDrive $tag")
                    .setDescription("Downloading the update")
                    .setMimeType("application/vnd.android.package-archive")
                    .setDestinationUri(Uri.fromFile(target))
                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE),
            )
            prefs(context).edit()
                .putLong("id", id)
                .putString("tag", tag)
                .putString("path", target.path)
                .apply()
            true
        } catch (e: Throwable) {
            false
        }
    }

    /**
     * Where the download is: state "none", "running", "failed", "conflict"
     * (signed with another key, so Android would refuse it) or "ready";
     * bytes done and total; the version and the file.
     */
    fun status(context: Context): Map<String, Any?> {
        val p = prefs(context)
        val id = p.getLong("id", -1)
        val tag = p.getString("tag", null)
        val path = p.getString("path", null)
        val none = mapOf<String, Any?>("state" to "none")
        if (id < 0 || tag == null || path == null) return none
        return try {
            val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            manager.query(DownloadManager.Query().setFilterById(id)).use { c ->
                if (!c.moveToFirst()) return none
                val status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                val done = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                val total = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                val state = when (status) {
                    DownloadManager.STATUS_SUCCESSFUL ->
                        if (!File(path).isFile) "failed"
                        else if (matchesInstalled(context, path) == false) "conflict"
                        else "ready"
                    DownloadManager.STATUS_FAILED -> "failed"
                    else -> "running"
                }
                mapOf("state" to state, "done" to done, "total" to total, "tag" to tag, "path" to path)
            }
        } catch (e: Throwable) {
            none
        }
    }

    /** Opens Android's installer for the downloaded update. */
    fun install(context: Context): Boolean {
        val path = prefs(context).getString("path", null) ?: return false
        return try {
            context.startActivity(installIntent(context, File(path)))
            true
        } catch (e: Throwable) {
            false
        }
    }

    private fun installIntent(context: Context, file: File): Intent {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        return Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            .also { it.clipData = ClipData.newRawUri(file.name, uri) }
    }

    /** Whether the APK at [path] has this app's signing key. Null if unknown. */
    fun matchesInstalled(context: Context, path: String): Boolean? {
        if (Build.VERSION.SDK_INT < 28) return null
        return try {
            fun keys(info: android.content.pm.PackageInfo?): Set<String>? =
                info?.signingInfo?.apkContentsSigners
                    ?.map { android.util.Base64.encodeToString(it.toByteArray(), android.util.Base64.NO_WRAP) }
                    ?.toSet()
                    ?.takeIf { it.isNotEmpty() }
            val flag = PackageManager.GET_SIGNING_CERTIFICATES
            val pm = context.packageManager
            val theirs = keys(pm.getPackageArchiveInfo(path, flag)) ?: return null
            val mine = keys(pm.getPackageInfo(context.packageName, flag)) ?: return null
            theirs == mine
        } catch (e: Throwable) {
            null
        }
    }

    /** The download finished: offer to install, in the app and as a notification. */
    fun onFinished(context: Context, id: Long) {
        if (id != prefs(context).getLong("id", -2)) return
        val status = status(context)
        // The app's channel may only be used from the main thread.
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            try {
                MainActivity.liveChannel?.invokeMethod("updateDownloaded", status["state"])
            } catch (e: Throwable) {
                // The app is not open.
            }
        }
        if (status["state"] != "ready") return
        try {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "App updates", NotificationManager.IMPORTANCE_DEFAULT),
                )
            }
            if (Build.VERSION.SDK_INT >= 33 &&
                context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val open = PendingIntent.getActivity(
                context,
                5108,
                installIntent(context, File(status["path"] as String)),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            manager.notify(
                NOTIFICATION_ID,
                builder
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentTitle("TeDrive ${status["tag"]} is ready")
                    .setContentText("Tap to install. Your sign-in, files and settings stay.")
                    .setContentIntent(open)
                    .setAutoCancel(true)
                    .build(),
            )
        } catch (e: Throwable) {
            // The app offers it too.
        }
    }
}

/** Android's download manager says a download has finished. */
class UpdateDownloadReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1)
        val pending = goAsync()
        Thread {
            try {
                AppUpdate.onFinished(context.applicationContext, id)
            } catch (e: Throwable) {
                // Nothing to do.
            } finally {
                pending.finish()
            }
        }.start()
    }
}
