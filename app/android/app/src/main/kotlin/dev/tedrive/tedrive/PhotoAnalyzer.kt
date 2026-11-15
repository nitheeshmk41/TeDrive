package dev.tedrive.tedrive

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.imageembedder.ImageEmbedder
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.label.ImageLabeling
import com.google.mlkit.vision.label.defaults.ImageLabelerOptions
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min

/**
 * Works out what is in a photo, on the phone (models built into the app, so
 * nothing is sent anywhere): labels such as "Beach" or "Food", printed
 * text, the faces, and for each face a fingerprint that is close for faces
 * that look alike. Used for search, smart albums and the photo widget.
 */
object PhotoAnalyzer {
    private const val TAG = "TeDrivePhotos"

    private val labeler by lazy {
        ImageLabeling.getClient(
            ImageLabelerOptions.Builder().setConfidenceThreshold(0.5f).build(),
        )
    }
    private val recognizer by lazy {
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    }
    private val faces by lazy {
        FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                // Ignore tiny faces in the background.
                .setMinFaceSize(0.1f)
                .build(),
        )
    }

    private var embedder: ImageEmbedder? = null
    private var embedderFailed = false

    @Synchronized
    private fun embedder(context: Context): ImageEmbedder? {
        if (embedder == null && !embedderFailed) {
            embedder = try {
                ImageEmbedder.createFromOptions(
                    context,
                    ImageEmbedder.ImageEmbedderOptions.builder()
                        .setBaseOptions(BaseOptions.builder().setModelAssetPath("face_embedder.tflite").build())
                        .setRunningMode(RunningMode.IMAGE)
                        .setL2Normalize(true)
                        .setQuantize(true)
                        .build(),
                )
            } catch (e: Throwable) {
                // Face matching is a nicety: everything else still works.
                Log.w(TAG, "Face matching unavailable", e)
                try {
                    // Shown by Account → Copy error log.
                    File(context.filesDir, "errors.log").appendText(
                        "[face matching unavailable] ${e.javaClass.name}: ${e.message}\n",
                    )
                } catch (ignored: Throwable) {
                }
                embedderFailed = true
                null
            }
        }
        return embedder
    }

    /**
     * Blocks; never call on the main thread. Null if the image cannot be
     * read, or if nothing could look at it (so that it is tried again
     * rather than remembered as empty). Small pictures of the faces are
     * saved in [faceDir] as `<key>_<n>.jpg`.
     */
    @Synchronized
    fun analyze(context: Context, path: String, key: String?, faceDir: String?): Map<String, Any>? {
        val file = File(path)
        if (!file.exists()) return null
        // A reduced copy: much faster, and a huge photo cannot run out of memory.
        val bitmap = Images.decodeScaled(file, 1280)
        if (bitmap == null) {
            Log.w(TAG, "Cannot read ${file.name}")
            return null
        }
        val image = InputImage.fromBitmap(bitmap, 0)
        var failed = 0
        val labels = try {
            Tasks.await(labeler.process(image), 30, TimeUnit.SECONDS).map { it.text }
        } catch (e: Throwable) {
            Log.w(TAG, "Labels failed", e)
            failed++
            emptyList()
        }
        val text = try {
            Tasks.await(recognizer.process(image), 30, TimeUnit.SECONDS).text
        } catch (e: Throwable) {
            Log.w(TAG, "Text failed", e)
            failed++
            ""
        }
        val boxes = try {
            Tasks.await(faces.process(image), 30, TimeUnit.SECONDS).map { it.boundingBox }
        } catch (e: Throwable) {
            Log.w(TAG, "Faces failed", e)
            failed++
            null
        }
        if (failed == 3) return null
        val prints = ArrayList<ByteArray>()
        if (boxes != null && key != null && faceDir != null) {
            // The largest faces, those that matter in the photo.
            val big = boxes.sortedByDescending { it.width() * it.height() }.take(6)
            for (box in big) {
                val print = faceprint(context, bitmap, box, File(faceDir, "${key}_${prints.size}.jpg")) ?: continue
                prints.add(print)
            }
        }
        return mapOf(
            "labels" to labels,
            "text" to text,
            "faces" to (boxes?.size ?: 0),
            "prints" to prints,
        )
    }

    /** The fingerprint of the face in [box], and its picture saved to [save]. */
    private fun faceprint(context: Context, bitmap: Bitmap, box: Rect, save: File): ByteArray? {
        if (box.width() < 40 || box.height() < 40) return null
        return try {
            // A square around the face with a little room, inside the photo.
            val side = (max(box.width(), box.height()) * 1.25f).toInt()
            val size = min(side, min(bitmap.width, bitmap.height))
            val left = (box.centerX() - size / 2).coerceIn(0, bitmap.width - size)
            val top = (box.centerY() - size / 2).coerceIn(0, bitmap.height - size)
            val face = Bitmap.createBitmap(bitmap, left, top, size, size)
            val small = Bitmap.createScaledBitmap(face, 160, 160, true)
            save.parentFile?.mkdirs()
            FileOutputStream(save).use { small.compress(Bitmap.CompressFormat.JPEG, 85, it) }
            val result = embedder(context)?.embed(BitmapImageBuilder(small).build()) ?: return null
            result.embeddingResult().embeddings().firstOrNull()?.quantizedEmbedding()
        } catch (e: Throwable) {
            Log.w(TAG, "Face print failed", e)
            null
        }
    }
}
