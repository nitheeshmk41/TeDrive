package dev.tedrive.tedrive

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Writes the reason the app closed into the same on-device log as the
 * app's other errors (Account → Copy error log), so that a crash on a
 * phone can be reported. Nothing is sent anywhere.
 */
class CrashLog private constructor(
    private val context: Context,
    private val previous: Thread.UncaughtExceptionHandler?,
) : Thread.UncaughtExceptionHandler {
    override fun uncaughtException(thread: Thread, error: Throwable) {
        try {
            val when_ = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).format(Date())
            val trace = error.stackTraceToString().lines().take(25).joinToString("\n")
            File(context.filesDir, "errors.log").appendText(
                "$when_ [app closed, ${BuildConfig.VERSION_NAME}, thread ${thread.name}] $trace\n",
            )
        } catch (e: Throwable) {
            // Nothing more can be done.
        }
        previous?.uncaughtException(thread, error)
    }

    companion object {
        fun install(context: Context) {
            val current = Thread.getDefaultUncaughtExceptionHandler()
            if (current is CrashLog) return
            Thread.setDefaultUncaughtExceptionHandler(CrashLog(context.applicationContext, current))
        }
    }
}
