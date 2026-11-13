package dev.tedrive.tedrive

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.media.ThumbnailUtils
import android.net.ConnectivityManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import kotlin.concurrent.thread
import kotlin.math.max

class MainActivity : FlutterFragmentActivity() {
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingDelete: MethodChannel.Result? = null
    private var pendingDeleteCount = 0

    // If the file picker already started the app's engine in the background,
    // show that same engine instead of starting a second Telegram session.
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(TeDriveEngine.ENGINE_ID)

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        super.cleanUpFlutterEngine(flutterEngine)
        TeDriveEngine.detach(flutterEngine)
        if (liveChannel != null && FlutterEngineCache.getInstance().get(TeDriveEngine.ENGINE_ID) !== flutterEngine) liveChannel = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        TeDriveEngine.attach(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "tedrive/thumbnails").setMethodCallHandler(::onThumbnailCall)
        val deviceChannel = MethodChannel(messenger, "tedrive/device")
        deviceChannel.setMethodCallHandler(::onDeviceCall)
        // Tell the Flutter side when another app shares files into TeDrive.
        IncomingShares.onReady = { deviceChannel.invokeMethod("sharedFilesReady", null) }
        liveChannel = deviceChannel
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        takeActionFrom(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        takeActionFrom(intent)
    }

    override fun onDestroy() {
        if (isFinishing) liveChannel = null
        super.onDestroy()
    }

    /** A widget button or reminder notification asked for something. */
    private fun takeActionFrom(intent: Intent?) {
        val action = intent?.getStringExtra(BackupSchedule.EXTRA_ACTION) ?: return
        intent.removeExtra(BackupSchedule.EXTRA_ACTION)
        pendingAction = action
        liveChannel?.invokeMethod("launchAction", action)
    }

    private var pendingAction: String? = null

    // ------------------------------------------------------------ Device

    private fun onDeviceCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasMediaPermission" -> result.success(hasMediaPermission())
            "requestMediaPermission" -> requestMediaPermission(result)
            "listMedia" -> thread {
                val items = try {
                    listMedia()
                } catch (e: Throwable) {
                    null
                }
                runOnUiThread {
                    if (items == null) result.error("media", "Could not read the phone's photos and videos", null)
                    else result.success(items)
                }
            }
            "deleteMedia" -> deleteMedia(call.argument<List<Map<String, Any>>>("items") ?: emptyList(), result)
            "deviceStatus" -> result.success(deviceStatus())
            "deviceName" -> result.success(deviceName())
            "takeLaunchAction" -> {
                result.success(pendingAction)
                pendingAction = null
            }
            "analyzeImage" -> {
                val path = call.argument<String>("path") ?: ""
                thread {
                    val found = PhotoAnalyzer.analyze(applicationContext, path)
                    runOnUiThread { result.success(found) }
                }
            }
            "saveToDownloads" -> {
                val path = call.argument<String>("path") ?: ""
                val name = call.argument<String>("name") ?: File(path).name
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                val folder = call.argument<String>("folder") ?: "TeDrive"
                thread {
                    val saved = DownloadsSaver.save(applicationContext, File(path), name, mime, folder)
                    runOnUiThread { result.success(saved) }
                }
            }
            "updateWidget" -> {
                BackupWidget.save(
                    applicationContext,
                    call.argument<String>("status") ?: "",
                    call.argument<String>("detail") ?: "",
                )
                result.success(null)
            }
            "setBackupSchedule" -> {
                BackupSchedule.save(
                    applicationContext,
                    call.argument<String>("mode") ?: "off",
                    call.argument<List<String>>("albums") ?: emptyList(),
                    (call.argument<Number>("lastRun") ?: 0).toLong(),
                )
                result.success(null)
            }
            "takeSharedFiles" -> result.success(IncomingShares.take())
            "share" -> viewOrShare(call, result, share = true)
            "open" -> viewOrShare(call, result, share = false)
            "openUrl" -> result.success(
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url"))))
                    true
                } catch (e: Throwable) {
                    false
                },
            )
            "startService" -> result.success(startService(call))
            "updateService" -> {
                BackupService.update(
                    this,
                    call.argument<String>("title") ?: "TeDrive",
                    call.argument<String>("text") ?: "",
                    call.argument<Int>("progress") ?: -1,
                )
                result.success(null)
            }
            "stopService" -> {
                stopService(Intent(this, BackupService::class.java))
                result.success(null)
            }
            "requestNotificationPermission" -> {
                if (Build.VERSION.SDK_INT >= 33 &&
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun mediaPermissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= 34 -> arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
            Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
        )
        Build.VERSION.SDK_INT >= 33 -> arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
        )
        Build.VERSION.SDK_INT >= 30 -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        // Android 10 and older also need write access to delete media.
        else -> arrayOf(
            Manifest.permission.READ_EXTERNAL_STORAGE,
            Manifest.permission.WRITE_EXTERNAL_STORAGE,
        )
    }

    /** "full", "partial" (Android 14 "selected photos only") or "none". */
    private fun hasMediaPermission(): String {
        fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
        return when {
            Build.VERSION.SDK_INT >= 33 -> when {
                granted(Manifest.permission.READ_MEDIA_IMAGES) &&
                    granted(Manifest.permission.READ_MEDIA_VIDEO) -> "full"
                Build.VERSION.SDK_INT >= 34 &&
                    granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> "partial"
                granted(Manifest.permission.READ_MEDIA_IMAGES) ||
                    granted(Manifest.permission.READ_MEDIA_VIDEO) -> "partial"
                else -> "none"
            }
            granted(Manifest.permission.READ_EXTERNAL_STORAGE) -> "full"
            else -> "none"
        }
    }

    private fun requestMediaPermission(result: MethodChannel.Result) {
        if (pendingPermission != null) {
            result.error("busy", "A permission request is already open", null)
            return
        }
        pendingPermission = result
        requestPermissions(mediaPermissions(), REQUEST_MEDIA)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_MEDIA) {
            pendingPermission?.success(hasMediaPermission())
            pendingPermission = null
        }
    }

    /** Every photo and video MediaStore knows about, with its real path. */
    private fun listMedia(): List<Map<String, Any?>> {
        val items = ArrayList<Map<String, Any?>>()
        for (video in listOf(false, true)) {
            val uri = if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            @Suppress("DEPRECATION")
            val projection = arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DATA,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATE_MODIFIED,
                "datetaken",
                "bucket_display_name",
            )
            contentResolver.query(uri, projection, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val path = c.getString(1) ?: continue
                    val size = c.getLong(3)
                    if (size <= 0) continue
                    val modified = c.getLong(4)
                    val taken = if (c.isNull(5)) 0L else c.getLong(5) / 1000
                    items.add(
                        mapOf(
                            "id" to c.getLong(0),
                            "path" to path,
                            "name" to (c.getString(2) ?: File(path).name),
                            "size" to size,
                            "modified" to modified,
                            // When the photo was taken, falling back to the file time.
                            "time" to (if (taken > 0) taken else modified),
                            "album" to (c.getString(6) ?: "Other"),
                            "video" to video,
                        ),
                    )
                }
            }
        }
        return items
    }

    private fun mediaUri(item: Map<String, Any>): Uri {
        val id = (item["id"] as Number).toLong()
        val base = if (item["video"] == true) MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        return ContentUris.withAppendedId(base, id)
    }

    /**
     * Deletes photos and videos from the phone. On Android 11+ the system
     * shows its own confirmation listing how many items will be removed.
     * Completes with the number deleted (0 if the user declined).
     */
    private fun deleteMedia(items: List<Map<String, Any>>, result: MethodChannel.Result) {
        if (items.isEmpty()) {
            result.success(0)
            return
        }
        if (pendingDelete != null) {
            result.error("busy", "A delete request is already open", null)
            return
        }
        val uris = items.map(::mediaUri)
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                val request = MediaStore.createDeleteRequest(contentResolver, uris)
                pendingDelete = result
                pendingDeleteCount = uris.size
                startIntentSenderForResult(request.intentSender, REQUEST_DELETE, null, 0, 0, 0)
            } catch (e: Throwable) {
                pendingDelete = null
                result.error("delete", e.message ?: "Could not ask to delete", null)
            }
            return
        }
        thread {
            var deleted = 0
            for (uri in uris) {
                try {
                    deleted += contentResolver.delete(uri, null, null)
                } catch (e: Throwable) {
                    // Skip items the system will not let us remove.
                }
            }
            runOnUiThread { result.success(deleted) }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_DELETE) {
            pendingDelete?.success(if (resultCode == Activity.RESULT_OK) pendingDeleteCount else 0)
            pendingDelete = null
        }
    }

    private fun deviceStatus(): Map<String, Boolean> {
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val online = connectivity.activeNetwork != null
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val plugged = battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        return mapOf(
            "online" to online,
            // Unmetered usually means Wi-Fi without a data cap.
            "unmetered" to (online && !connectivity.isActiveNetworkMetered),
            "charging" to (plugged != 0),
        )
    }

    /** Returns false if Android refuses (e.g. started from the background). */
    private fun startService(call: MethodCall): Boolean {
        val intent = Intent(this, BackupService::class.java)
            .putExtra(BackupService.EXTRA_TITLE, call.argument<String>("title") ?: "TeDrive")
            .putExtra(BackupService.EXTRA_TEXT, call.argument<String>("text") ?: "")
            .putExtra(BackupService.EXTRA_PROGRESS, call.argument<Int>("progress") ?: -1)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
            else startService(intent)
            true
        } catch (e: Throwable) {
            false
        }
    }

    private fun deviceName(): String {
        val maker = Build.MANUFACTURER.orEmpty().replaceFirstChar { it.uppercase() }
        val model = Build.MODEL.orEmpty()
        return if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model".trim()
    }

    /**
     * Hands a file to another app, either through the share sheet or to be
     * opened. The file is exposed as a content URI with its real MIME type
     * and a temporary read permission, which is what apps such as WhatsApp
     * require.
     */
    private fun viewOrShare(call: MethodCall, result: MethodChannel.Result, share: Boolean) {
        val path = call.argument<String>("path")
        val mime = call.argument<String>("mime") ?: "*/*"
        if (path == null || !File(path).isFile) {
            result.error("file", "The file is not on this phone", null)
            return
        }
        try {
            // A renamed file is handed over under its new name.
            val shown = aliasFor(File(path), call.argument<String>("name"))
            val uri = FileProvider.getUriForFile(this, "$packageName.files", shown)
            val intent = if (share) {
                Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, uri)
            } else {
                Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
            }
            intent.clipData = ClipData.newRawUri(shown.name, uri)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (share) {
                startActivity(Intent.createChooser(intent, null))
                result.success(true)
            } else {
                try {
                    startActivity(intent)
                    result.success(true)
                } catch (e: ActivityNotFoundException) {
                    result.success(false)
                }
            }
        } catch (e: Throwable) {
            result.error("share", e.message ?: "Could not hand the file to another app", null)
        }
    }

    /**
     * Returns a second name for the same file (a hard link in the cache, so
     * no bytes are copied), or the file itself if that is not possible, for
     * example when it lives on shared storage.
     */
    private fun aliasFor(source: File, name: String?): File {
        if (name.isNullOrBlank() || name == source.name) return source
        return try {
            val root = File(cacheDir, "renamed")
            // Old aliases are only names; removing them frees nothing but clutter.
            root.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 24 * 60 * 60 * 1000 }
                ?.forEach { it.deleteRecursively() }
            val dir = File(root, System.nanoTime().toString()).apply { mkdirs() }
            val alias = File(dir, name.replace(Regex("[/\\\\\\u0000]"), "_"))
            android.system.Os.link(source.path, alias.path)
            alias
        } catch (e: Throwable) {
            source
        }
    }

    // ------------------------------------------------------------ Thumbnails

    private fun onThumbnailCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "create") {
            result.notImplemented()
            return
        }
        val source = call.argument<String>("source")!!
        val target = call.argument<String>("target")!!
        val isVideo = call.argument<Boolean>("video") ?: false
        val maxSide = call.argument<Int>("maxSide") ?: 320
        // Decoding can take a while, so keep it off the UI thread.
        thread {
            val size = try {
                createThumbnail(File(source), File(target), isVideo, maxSide)
            } catch (e: Throwable) {
                null
            }
            runOnUiThread { result.success(size) }
        }
    }

    /** Writes a JPEG thumbnail and returns [width, height], or null if it cannot. */
    private fun createThumbnail(source: File, target: File, isVideo: Boolean, maxSide: Int): List<Int>? {
        val bitmap = decode(source, isVideo, maxSide) ?: return null
        val scaled = scaleDown(bitmap, maxSide)
        FileOutputStream(target).use { scaled.compress(Bitmap.CompressFormat.JPEG, 82, it) }
        return listOf(scaled.width, scaled.height)
    }

    private fun decode(source: File, isVideo: Boolean, maxSide: Int): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Handles EXIF rotation and HEIC for images.
            val box = Size(maxSide, maxSide)
            return if (isVideo) ThumbnailUtils.createVideoThumbnail(source, box, null)
            else ThumbnailUtils.createImageThumbnail(source, box, null)
        }
        if (isVideo) {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(source.path)
                return retriever.frameAtTime
            } finally {
                retriever.release()
            }
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.path, bounds)
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        return BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    private fun scaleDown(bitmap: Bitmap, maxSide: Int): Bitmap {
        val longest = max(bitmap.width, bitmap.height)
        if (longest <= maxSide) return bitmap
        val ratio = maxSide.toFloat() / longest
        return Bitmap.createScaledBitmap(
            bitmap,
            max(1, (bitmap.width * ratio).toInt()),
            max(1, (bitmap.height * ratio).toInt()),
            true,
        )
    }

    companion object {
        /** The app's device channel while its screen's engine is alive. */
        @Volatile
        var liveChannel: MethodChannel? = null

        private const val REQUEST_MEDIA = 4101
        const val REQUEST_NOTIFICATIONS = 4102
        const val REQUEST_DELETE = 4103
    }
}
