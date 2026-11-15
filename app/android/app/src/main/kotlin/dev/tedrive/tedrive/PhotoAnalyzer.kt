package dev.tedrive.tedrive

import android.content.Context
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.label.ImageLabeling
import com.google.mlkit.vision.label.defaults.ImageLabelerOptions
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Works out what is in a photo, on the phone (Google ML Kit with its models
 * built into the app, so nothing is sent anywhere): labels such as "Beach"
 * or "Food", any printed text, and how many faces. Used for searching photos by content.
 */
object PhotoAnalyzer {
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
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                // Ignore tiny faces in the background.
                .setMinFaceSize(0.12f)
                .build(),
        )
    }

    /**
     * Blocks; never call on the main thread. Null if the image cannot be
     * read, or if nothing could look at it (so that it is tried again
     * rather than remembered as empty).
     */
    fun analyze(context: Context, path: String): Map<String, Any>? {
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
        val faceCount = try {
            Tasks.await(faces.process(image), 30, TimeUnit.SECONDS).size
        } catch (e: Throwable) {
            Log.w(TAG, "Faces failed", e)
            failed++
            0
        }
        if (failed == 3) return null
        return mapOf("labels" to labels, "text" to text, "faces" to faceCount)
    }

    private const val TAG = "TeDrivePhotos"
}
