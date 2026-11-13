package dev.tedrive.tedrive

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.MediaStore
import android.widget.RemoteViews
import java.util.Calendar

/**
 * Daily or weekly backup. The upload itself needs the Telegram session,
 * which lives in the app, so at the chosen time:
 *  - if TeDrive is running (even in the background) it is told to back up;
 *  - otherwise, if the phone has new photos or videos in the chosen albums,
 *    a notification offers to back them up with one tap.
 */
object BackupSchedule {
    private const val PREFS = "tedrive_schedule"
    private const val HOUR = 21 // in the evening, when phones are usually on Wi-Fi
    private const val REQUEST_ALARM = 5101
    private const val CHANNEL_ID = "backup_reminders"
    private const val NOTIFICATION_ID = 2
    const val ACTION_BACKUP = "backup"
    const val EXTRA_ACTION = "tedrive_action"

    /** [mode] is "off", "instant", "daily" or "weekly". */
    fun save(context: Context, mode: String, albums: List<String>, lastRun: Long) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("mode", mode)
            .putStringSet("albums", albums.toSet())
            .putLong("lastRun", lastRun)
            .apply()
        schedule(context)
    }

    fun schedule(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val mode = prefs.getString("mode", "off") ?: "off"
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pending = PendingIntent.getBroadcast(
            context,
            REQUEST_ALARM,
            Intent(context, BackupAlarmReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        alarms.cancel(pending)
        if (mode == "off") return
        val interval = if (mode == "weekly") 7 * AlarmManager.INTERVAL_DAY else AlarmManager.INTERVAL_DAY
        val first = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, HOUR)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            if (timeInMillis <= System.currentTimeMillis()) add(Calendar.DAY_OF_YEAR, 1)
        }.timeInMillis
        // Inexact: Android may shift it a little to save battery.
        alarms.setInexactRepeating(AlarmManager.RTC_WAKEUP, first, interval, pending)
    }

    /** Photos and videos added to the chosen albums since the last backup. */
    fun newMediaCount(context: Context): Int {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val albums = prefs.getStringSet("albums", emptySet()) ?: emptySet()
        val since = prefs.getLong("lastRun", 0)
        if (albums.isEmpty()) return 0
        val permission = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES
        else Manifest.permission.READ_EXTERNAL_STORAGE
        if (context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) return 0
        var count = 0
        for (uri in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
        )) {
            try {
                context.contentResolver.query(
                    uri,
                    arrayOf(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME),
                    "${MediaStore.MediaColumns.DATE_ADDED} > ?",
                    arrayOf(since.toString()),
                    null,
                )?.use { c ->
                    while (c.moveToNext()) {
                        if (c.getString(0) in albums) count++
                    }
                }
            } catch (e: Throwable) {
                // Count what could be read.
            }
        }
        return count
    }

    fun openAppIntent(context: Context, action: String?, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (action != null) intent.putExtra(EXTRA_ACTION, action)
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun notifyDue(context: Context, count: Int) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Backup reminders", NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val what = if (count == 1) "1 new photo or video" else "$count new photos and videos"
        manager.notify(
            NOTIFICATION_ID,
            builder
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle("Time for your TeDrive backup")
                .setContentText("$what to back up. Tap to back up now.")
                .setContentIntent(openAppIntent(context, ACTION_BACKUP, 5102))
                .setAutoCancel(true)
                .build(),
        )
    }
}

/** Fires at the scheduled time, and after a restart or an app update. */
class BackupAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                BackupSchedule.schedule(context)
                return
            }
        }
        val live = MainActivity.liveChannel
        if (live != null) {
            live.invokeMethod("launchAction", "scheduledBackup")
            return
        }
        val pending = goAsync()
        Thread {
            try {
                val count = BackupSchedule.newMediaCount(context)
                if (count > 0) BackupSchedule.notifyDue(context, count)
            } finally {
                pending.finish()
            }
        }.start()
    }
}

/** The home-screen widget: backup status and a "Back up" button. */
class BackupWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        render(context, manager, ids)
    }

    companion object {
        private const val PREFS = "tedrive_widget"

        fun save(context: Context, status: String, detail: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("status", status)
                .putString("detail", detail)
                .apply()
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, BackupWidget::class.java))
            if (ids.isNotEmpty()) render(context, manager, ids)
        }

        private fun render(context: Context, manager: AppWidgetManager, ids: IntArray) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val views = RemoteViews(context.packageName, R.layout.backup_widget).apply {
                setTextViewText(R.id.widget_status, prefs.getString("status", null) ?: "Open TeDrive to start")
                setTextViewText(R.id.widget_detail, prefs.getString("detail", null) ?: "Backup status shows here")
                setOnClickPendingIntent(R.id.widget_root, BackupSchedule.openAppIntent(context, null, 5103))
                setOnClickPendingIntent(
                    R.id.widget_button,
                    BackupSchedule.openAppIntent(context, BackupSchedule.ACTION_BACKUP, 5104),
                )
            }
            manager.updateAppWidget(ids, views)
        }
    }
}
