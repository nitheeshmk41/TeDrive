package dev.tedrive.tedrive

import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Point
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException
import org.json.JSONObject

/**
 * Makes the drive appear in Android's file picker, next to Google Drive and
 * Downloads. That picker is what WhatsApp ("Document"), Gmail and most
 * other apps open when attaching a file, so files can be sent straight
 * from TeDrive.
 *
 * The list of files comes from a small catalogue file the app writes
 * whenever the drive changes. A file that is not on the phone yet is
 * downloaded when another app opens it. Everything is read-only.
 */
class TeDriveDocumentsProvider : DocumentsProvider() {
    private class Entry(
        val id: Long,
        val name: String,
        val size: Long,
        val time: Long,
        val folder: String?,
        val mime: String,
        val path: String?,
        val thumb: String?,
    )

    private var cached: List<Entry> = emptyList()
    private var cachedStamp = -1L

    private fun catalogueFile() = File(context!!.filesDir, CATALOGUE)

    @Synchronized
    private fun entries(): List<Entry> {
        val file = catalogueFile()
        if (!file.isFile) return emptyList()
        val stamp = file.lastModified()
        if (stamp == cachedStamp) return cached
        cached = try {
            val files = JSONObject(file.readText()).getJSONArray("files")
            List(files.length()) { i ->
                val o = files.getJSONObject(i)
                Entry(
                    id = o.getLong("id"),
                    name = o.getString("name"),
                    size = o.getLong("size"),
                    time = o.getLong("time"),
                    folder = if (o.isNull("folder")) null else o.getString("folder"),
                    mime = o.optString("mime", "application/octet-stream"),
                    path = if (o.isNull("path")) null else o.getString("path"),
                    thumb = if (o.isNull("thumb")) null else o.getString("thumb"),
                )
            }
        } catch (e: Throwable) {
            emptyList()
        }
        cachedStamp = stamp
        return cached
    }

    private fun entry(documentId: String): Entry {
        val id = documentId.removePrefix(FILE).toLongOrNull()
        return entries().firstOrNull { it.id == id } ?: throw FileNotFoundException(documentId)
    }

    override fun onCreate() = true

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: ROOT_COLUMNS)
        // Signed out or never opened: there is nothing to offer.
        if (!catalogueFile().isFile) return cursor
        cursor.newRow().apply {
            add(Root.COLUMN_ROOT_ID, "tedrive")
            add(Root.COLUMN_DOCUMENT_ID, ROOT)
            add(Root.COLUMN_TITLE, "TeDrive")
            add(Root.COLUMN_SUMMARY, "Your files in Telegram")
            add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
            add(Root.COLUMN_FLAGS, 0)
            add(Root.COLUMN_MIME_TYPES, "*/*")
        }
        return cursor
    }

    private fun addFolder(cursor: MatrixCursor, id: String, name: String) {
        cursor.newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, id)
            add(Document.COLUMN_DISPLAY_NAME, name)
            add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR)
            add(Document.COLUMN_FLAGS, 0)
            add(Document.COLUMN_SIZE, null)
            add(Document.COLUMN_LAST_MODIFIED, null)
        }
    }

    private fun addFile(cursor: MatrixCursor, e: Entry) {
        val hasThumb = e.thumb != null && File(e.thumb).isFile
        cursor.newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, FILE + e.id)
            add(Document.COLUMN_DISPLAY_NAME, e.name)
            add(Document.COLUMN_MIME_TYPE, e.mime)
            add(Document.COLUMN_FLAGS, if (hasThumb) Document.FLAG_SUPPORTS_THUMBNAIL else 0)
            add(Document.COLUMN_SIZE, e.size)
            add(Document.COLUMN_LAST_MODIFIED, e.time)
        }
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: DOCUMENT_COLUMNS)
        when {
            documentId == ROOT -> addFolder(cursor, ROOT, "TeDrive")
            documentId.startsWith(FOLDER) -> addFolder(cursor, documentId, documentId.removePrefix(FOLDER))
            else -> addFile(cursor, entry(documentId))
        }
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val cursor = MatrixCursor(projection ?: DOCUMENT_COLUMNS)
        val all = entries()
        if (parentDocumentId == ROOT) {
            all.mapNotNull { it.folder }.distinct().sortedBy { it.lowercase() }
                .forEach { addFolder(cursor, FOLDER + it, it) }
            all.filter { it.folder == null }.forEach { addFile(cursor, it) }
        } else if (parentDocumentId.startsWith(FOLDER)) {
            val folder = parentDocumentId.removePrefix(FOLDER)
            all.filter { it.folder == folder }.forEach { addFile(cursor, it) }
        }
        return cursor
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean = when {
        parentDocumentId == ROOT -> true
        parentDocumentId.startsWith(FOLDER) && documentId.startsWith(FILE) ->
            entries().any { FILE + it.id == documentId && FOLDER + it.folder == parentDocumentId }
        else -> false
    }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        if ("w" in mode) throw UnsupportedOperationException("TeDrive files are read-only here")
        val e = entry(documentId)
        val local = e.path?.let(::File)?.takeIf { it.isFile }
        // Not on the phone yet: have the app fetch it from Telegram.
        val file = local
            ?: TeDriveEngine.requestFile(context!!, e.id, signal)?.let(::File)?.takeIf { it.isFile }
            ?: throw FileNotFoundException("Could not download ${e.name}. Open TeDrive and try again.")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun openDocumentThumbnail(
        documentId: String,
        sizeHint: Point?,
        signal: CancellationSignal?,
    ): AssetFileDescriptor {
        val thumb = entry(documentId).thumb?.let(::File)?.takeIf { it.isFile }
            ?: throw FileNotFoundException("No preview")
        val descriptor = ParcelFileDescriptor.open(thumb, ParcelFileDescriptor.MODE_READ_ONLY)
        return AssetFileDescriptor(descriptor, 0, AssetFileDescriptor.UNKNOWN_LENGTH)
    }

    private companion object {
        const val CATALOGUE = "picker_catalogue.json"
        const val ROOT = "root"
        const val FOLDER = "folder:"
        const val FILE = "file:"

        val ROOT_COLUMNS = arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY,
            Root.COLUMN_ICON,
            Root.COLUMN_FLAGS,
            Root.COLUMN_MIME_TYPES,
        )
        val DOCUMENT_COLUMNS = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_FLAGS,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
        )
    }
}
