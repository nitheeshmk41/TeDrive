package dev.tedrive.tedrive

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import java.io.File
import kotlin.concurrent.thread

/**
 * Files that other apps shared into TeDrive and that the Flutter side has
 * not picked up yet. They wait here until the drive screen is ready, for
 * example while the user is still signing in.
 */
object IncomingShares {
    private val items = ArrayList<Map<String, Any?>>()

    /** Called on the main thread when new files have arrived. */
    @Volatile
    var onReady: (() -> Unit)? = null

    @Synchronized
    fun add(files: List<Map<String, Any?>>) {
        items.addAll(files)
    }

    @Synchronized
    fun take(): List<Map<String, Any?>> {
        val copy = ArrayList(items)
        items.clear()
        return copy
    }
}

/**
 * Receives "Share" from other apps: select photos in the gallery, tap
 * Share, choose TeDrive, and they are uploaded to the drive.
 *
 * This is a small screenless activity of its own, so sharing never starts
 * a second copy of the main app. It works out where each shared file is,
 * queues it, then brings TeDrive to the front.
 */
class ShareReceiverActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = sharedUris(intent)
        if (uris.isEmpty()) {
            Toast.makeText(this, "TeDrive can only add files, not text.", Toast.LENGTH_LONG).show()
            finish()
            return
        }
        Toast.makeText(
            this,
            if (uris.size == 1) "Adding 1 file to TeDrive…" else "Adding ${uris.size} files to TeDrive…",
            Toast.LENGTH_SHORT,
        ).show()
        // Reading the files needs the permission this activity was granted,
        // so finish only after they have been resolved or copied.
        thread {
            val files = uris.mapNotNull { uri ->
                try {
                    resolve(uri)
                } catch (e: Throwable) {
                    null
                }
            }
            runOnUiThread {
                if (files.isEmpty()) {
                    Toast.makeText(this, "TeDrive could not read those files.", Toast.LENGTH_LONG).show()
                } else {
                    IncomingShares.add(files)
                    IncomingShares.onReady?.invoke()
                    // Same intent as the launcher icon, so an already running
                    // TeDrive comes to the front instead of starting again.
                    packageManager.getLaunchIntentForPackage(packageName)?.let(::startActivity)
                }
                finish()
            }
        }
    }

    private fun sharedUris(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        @Suppress("DEPRECATION")
        return when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(
                if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else intent.getParcelableExtra(Intent.EXTRA_STREAM),
            )
            Intent.ACTION_SEND_MULTIPLE -> (
                if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                ) ?: emptyList()
            else -> emptyList()
        }
    }

    /**
     * Another app must not be able to make TeDrive upload its own private
     * files (the Telegram session, settings) by "sharing" a path to them.
     */
    private fun isOwnPrivateFile(file: File): Boolean = try {
        val path = file.canonicalPath
        val own = File(applicationInfo.dataDir).canonicalPath
        path == own || path.startsWith("$own/")
    } catch (e: Throwable) {
        true
    }

    /**
     * Describes one shared file for the Flutter side. A photo or video that
     * is readable in place is uploaded from where it is; anything else is
     * first copied into TeDrive's cache ("temp"), and removed after upload.
     */
    private fun resolve(uri: Uri): Map<String, Any?>? {
        if (uri.scheme == "file") {
            val file = File(uri.path ?: return null)
            return if (!isOwnPrivateFile(file) && file.canRead() && file.length() > 0) {
                describe(file, file.name, 0, temp = false)
            } else {
                null
            }
        }
        var name: String? = null
        var path: String? = null
        var time = 0L
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                fun text(column: String) = c.getColumnIndex(column).takeIf { it >= 0 && !c.isNull(it) }?.let(c::getString)
                fun number(column: String) = c.getColumnIndex(column).takeIf { it >= 0 && !c.isNull(it) }?.let(c::getLong)
                name = text("_display_name")
                path = text("_data")
                time = number("datetaken")?.div(1000) ?: number("date_modified") ?: 0L
            }
        }
        val original = path?.let(::File)
        if (original != null && !isOwnPrivateFile(original) && original.canRead() && original.length() > 0) {
            return describe(original, name ?: original.name, time, temp = false)
        }
        val dir = File(cacheDir, "incoming/${System.nanoTime()}").apply { mkdirs() }
        val safeName = (name ?: "shared_file").replace(Regex("[/\\\\\\u0000]"), "_").ifBlank { "shared_file" }
        val copy = File(dir, safeName)
        (contentResolver.openInputStream(uri) ?: return null).use { input ->
            copy.outputStream().use { input.copyTo(it) }
        }
        return if (copy.length() > 0) describe(copy, safeName, time, temp = true) else null
    }

    private fun describe(file: File, name: String, time: Long, temp: Boolean) = mapOf(
        "path" to file.path,
        "name" to name,
        "size" to file.length(),
        // Seconds since 1970 when the photo was taken, or 0 if unknown.
        "time" to time,
        "temp" to temp,
    )
}
