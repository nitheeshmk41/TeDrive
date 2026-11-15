package dev.tedrive.tedrive

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.view.View
import android.widget.RemoteViews
import java.io.File
import java.io.FileOutputStream

/**
 * The photo widget: one of the user's photos, a different one every half
 * hour or when its corner button is tapped. The app chooses which photos
 * (all, an album, people…) and leaves small copies here; the widget only
 * draws them, so it works while the app is closed.
 */
object PhotoWidgets {
    const val ACTION_NEXT = "dev.tedrive.tedrive.PHOTO_WIDGET_NEXT"
    private const val PREFS = "tedrive_photo_widget"

    // Small enough to hand to the home screen, sharp enough for a large widget.
    private const val MAX_SIDE = 640

    private fun dir(context: Context) = File(context.filesDir, "widget_photos")

    private fun photos(context: Context): List<File> =
        dir(context).listFiles { f -> f.name.endsWith(".jpg") }?.sortedBy { it.name } ?: emptyList()

    /**
     * Replaces the widget's photos with small copies of [paths]. Blocks.
     * Returns how many were saved. If none can be read, the old ones stay.
     */
    @Synchronized
    fun setPhotos(context: Context, paths: List<String>, captions: List<String>): Int {
        val dir = dir(context)
        val staging = File(context.filesDir, "widget_photos_new")
        staging.deleteRecursively()
        staging.mkdirs()
        val kept = ArrayList<String>()
        for ((i, path) in paths.withIndex()) {
            val bitmap = Images.decodeScaled(File(path), MAX_SIDE) ?: continue
            try {
                val name = "%03d.jpg".format(kept.size)
                FileOutputStream(File(staging, name)).use {
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it)
                }
                kept.add(captions.getOrNull(i) ?: "")
            } catch (e: Throwable) {
                // Skip this one.
            }
        }
        if (kept.isEmpty() && paths.isNotEmpty()) {
            staging.deleteRecursively()
            return 0
        }
        dir.deleteRecursively()
        staging.renameTo(dir)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("captions", kept.joinToString("\n") { it.replace('\n', ' ') })
            .putInt("shown", -1)
            .apply()
        refresh(context, advance = true)
        return kept.size
    }

    /** Redraws every photo widget; with [advance], with another photo. */
    @Synchronized
    fun refresh(context: Context, advance: Boolean) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, PhotoWidget::class.java))
        if (ids.isEmpty()) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val files = photos(context)
        var shown = prefs.getInt("shown", -1)
        if (files.isNotEmpty() && (advance || shown !in files.indices)) {
            // Any photo but the one showing.
            shown = files.indices.filter { it != shown || files.size == 1 }.random()
            prefs.edit().putInt("shown", shown).apply()
        }
        val bitmap = files.getOrNull(shown)?.let {
            try {
                BitmapFactory.decodeFile(it.path)
            } catch (e: Throwable) {
                null
            }
        }
        val caption = (prefs.getString("captions", "") ?: "").split("\n").getOrNull(shown) ?: ""
        val views = RemoteViews(context.packageName, R.layout.photo_widget)
        views.setOnClickPendingIntent(R.id.widget_root, BackupSchedule.openAppIntent(context, null, 5105))
        if (bitmap == null) {
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            views.setViewVisibility(R.id.widget_photo, View.GONE)
            views.setViewVisibility(R.id.widget_caption, View.GONE)
            views.setViewVisibility(R.id.widget_next, View.GONE)
        } else {
            views.setViewVisibility(R.id.widget_empty, View.GONE)
            views.setViewVisibility(R.id.widget_photo, View.VISIBLE)
            views.setImageViewBitmap(R.id.widget_photo, bitmap)
            views.setTextViewText(R.id.widget_caption, caption)
            views.setViewVisibility(R.id.widget_caption, if (caption.isEmpty()) View.GONE else View.VISIBLE)
            views.setViewVisibility(R.id.widget_next, if (files.size > 1) View.VISIBLE else View.GONE)
            views.setOnClickPendingIntent(
                R.id.widget_next,
                PendingIntent.getBroadcast(
                    context,
                    5106,
                    Intent(context, PhotoWidget::class.java).setAction(ACTION_NEXT),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        manager.updateAppWidget(ids, views)
    }
}

class PhotoWidget : AppWidgetProvider() {
    // Called when the widget is added, and every half hour after that.
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        PhotoWidgets.refresh(context, advance = true)

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == PhotoWidgets.ACTION_NEXT) {
            PhotoWidgets.refresh(context, advance = true)
        } else {
            super.onReceive(context, intent)
        }
    }
}
