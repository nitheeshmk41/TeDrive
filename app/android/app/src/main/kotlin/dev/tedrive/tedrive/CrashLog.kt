package dev.tedrive.tedrive

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Writes the reason the app closed into the same on-device log as the
 * app's other errors (Account → Copy error log), so that a crash on a
 * phone can be reported. Nothing is sent anywhere. Also counts recent
 * crashes, so the app can start without its newer extras (safe mode)
 * instead of closing again and again.
 */
class CrashLog private constructor(
    private val context: Context,
    private val previous: Thread.UncaughtExceptionHandler?,
) : Thread.UncaughtExceptionHandler {
    override fun uncaughtException(thread: Thread, error: Throwable) {
        try {
            val now = System.currentTimeMillis()
            val stamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).format(Date(now))
            val trace = error.stackTraceToString().lines().take(25).joinToString("\n")
            File(context.filesDir, "errors.log").appendText(
                "$stamp [app closed, ${BuildConfig.VERSION_NAME}, thread ${thread.name}] $trace\n",
            )
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val times = (prefs.getString("times", "") ?: "").split(",").filter { it.isNotEmpty() }
            prefs.edit().putString("times", (times.takeLast(9) + "$now").joinToString(",")).commit()
        } catch (e: Throwable) {
            // Nothing more can be done.
        }
        previous?.uncaughtException(thread, error)
    }

    companion object {
        private const val PREFS = "tedrive_crashes"

        fun install(context: Context) {
            val current = Thread.getDefaultUncaughtExceptionHandler()
            if (current is CrashLog) return
            Thread.setDefaultUncaughtExceptionHandler(CrashLog(context.applicationContext, current))
        }

        /** How many times the app closed unexpectedly in the last [minutes]. */
        fun recent(context: Context, minutes: Int): Int {
            val since = System.currentTimeMillis() - minutes * 60_000L
            val times = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("times", "") ?: ""
            return times.split(",").mapNotNull { it.toLongOrNull() }.count { it >= since }
        }

        fun clear(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        }
    }
}
