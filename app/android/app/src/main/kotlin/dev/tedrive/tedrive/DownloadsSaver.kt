package dev.tedrive.tedrive

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

/** Copies a file into the phone's public Downloads folder. */
object DownloadsSaver {
    /**
     * Saves [source] as Downloads/[folder]/[name]. Returns where it went
     * (for showing to the user), or null on failure. Blocks.
     */
    fun save(context: Context, source: File, name: String, mime: String, folder: String): String? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$folder")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val resolver = context.contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
                try {
                    resolver.openOutputStream(uri)!!.use { out ->
                        source.inputStream().use { it.copyTo(out, 1 shl 20) }
                    }
                } catch (e: Throwable) {
                    resolver.delete(uri, null, null)
                    return null
                }
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } else {
                @Suppress("DEPRECATION")
                val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), folder)
                dir.mkdirs()
                source.copyTo(File(dir, name), overwrite = true)
            }
            "Downloads/$folder/$name"
        } catch (e: Throwable) {
            null
        }
    }
}
