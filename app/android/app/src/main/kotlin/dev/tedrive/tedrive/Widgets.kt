package dev.tedrive.tedrive

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.view.View
import android.widget.RemoteViews

/**
 * The home-screen widgets. The app writes what they show (backup status and
 * how much is in the drive) whenever it changes; the widgets only draw it.
 */
object Widgets {
    private const val PREFS = "tedrive_widget"
    private val KEYS = listOf("status", "detail", "size", "count", "files", "media", "waiting")

    fun save(context: Context, values: Map<String, Any?>) {
        val edit = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        for (key in KEYS) edit.putString(key, values[key] as? String)
        edit.putInt("progress", (values["progress"] as? Number)?.toInt() ?: -1)
        edit.apply()
        refreshAll(context)
    }

    fun refreshAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        for (kind in listOf(BackupWidget::class.java, StorageWidget::class.java, OverviewWidget::class.java)) {
            val ids = manager.getAppWidgetIds(ComponentName(context, kind))
            if (ids.isNotEmpty()) render(context, manager, ids, layoutOf(kind))
        }
    }

    fun layoutOf(kind: Class<*>): Int = when (kind) {
        StorageWidget::class.java -> R.layout.storage_widget
        OverviewWidget::class.java -> R.layout.overview_widget
        else -> R.layout.backup_widget
    }

    fun render(context: Context, manager: AppWidgetManager, ids: IntArray, layout: Int) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        fun text(key: String, fallback: String) = prefs.getString(key, null)?.takeIf { it.isNotEmpty() } ?: fallback
        val progress = prefs.getInt("progress", -1)
        val views = RemoteViews(context.packageName, layout)
        views.setOnClickPendingIntent(R.id.widget_root, BackupSchedule.openAppIntent(context, null, 5103))
        if (layout != R.layout.storage_widget) {
            views.setTextViewText(R.id.widget_status, text("status", "Open TeDrive to start"))
            views.setTextViewText(R.id.widget_detail, text("detail", "Backup status shows here"))
            views.setViewVisibility(R.id.widget_progress, if (progress in 0..100) View.VISIBLE else View.GONE)
            if (progress in 0..100) views.setProgressBar(R.id.widget_progress, 100, progress, false)
            views.setOnClickPendingIntent(
                R.id.widget_button,
                BackupSchedule.openAppIntent(context, BackupSchedule.ACTION_BACKUP, 5104),
            )
        }
        when (layout) {
            R.layout.backup_widget -> {
                val files = text("files", "")
                views.setTextViewText(
                    R.id.widget_stats,
                    if (files.isEmpty()) "" else "${text("size", "")} backed up · $files",
                )
                views.setViewVisibility(R.id.widget_stats, if (files.isEmpty()) View.GONE else View.VISIBLE)
            }
            R.layout.storage_widget -> {
                views.setTextViewText(R.id.widget_size, text("size", "0 GB"))
                views.setTextViewText(R.id.widget_files, text("files", "Open TeDrive to start"))
                views.setTextViewText(R.id.widget_media, text("media", ""))
            }
            R.layout.overview_widget -> {
                views.setTextViewText(R.id.widget_size, text("size", "0 GB"))
                views.setTextViewText(R.id.widget_count, text("count", "0"))
                views.setTextViewText(R.id.widget_waiting, text("waiting", "0"))
            }
        }
        manager.updateAppWidget(ids, views)
    }
}

/** Backup status in one row, with a "Back up" button. */
class BackupWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        Widgets.render(context, manager, ids, Widgets.layoutOf(javaClass))
}

/** A small square: how much is backed up. */
class StorageWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        Widgets.render(context, manager, ids, Widgets.layoutOf(javaClass))
}

/** The large one: size, files, what is waiting, status and a button. */
class OverviewWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        Widgets.render(context, manager, ids, Widgets.layoutOf(javaClass))
}
