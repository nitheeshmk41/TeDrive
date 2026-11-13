package dev.tedrive.tedrive

import android.content.Context
import android.net.Uri
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.label.ImageLabeling
import com.google.mlkit.vision.label.defaults.ImageLabelerOptions
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Works out what is in a photo, on the phone (Google ML Kit with its models
 * built into the app, so nothing is sent anywhere): labels such as "Beach"
 * or "Food", and any printed text. Used for searching photos by content.
 */
object PhotoAnalyzer {
    private val labeler by lazy {
        ImageLabeling.getClient(
            ImageLabelerOptions.Builder().setConfidenceThreshold(0.6f).build(),
        )
    }
    private val recognizer by lazy {
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    }

    /** Blocks; never call on the main thread. Null if the image cannot be read. */
    fun analyze(context: Context, path: String): Map<String, Any>? {
        val file = File(path)
        if (!file.exists()) return null
        val image = try {
            InputImage.fromFilePath(context, Uri.fromFile(file))
        } catch (e: Throwable) {
            return null
        }
        val labels = try {
            Tasks.await(labeler.process(image), 30, TimeUnit.SECONDS).map { it.text }
        } catch (e: Throwable) {
            emptyList()
        }
        val text = try {
            Tasks.await(recognizer.process(image), 30, TimeUnit.SECONDS).text
        } catch (e: Throwable) {
            ""
        }
        return mapOf("labels" to labels, "text" to text)
    }
}
