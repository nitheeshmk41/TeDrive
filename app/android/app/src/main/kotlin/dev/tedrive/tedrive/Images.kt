package dev.tedrive.tedrive

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import java.io.File
import kotlin.math.max

/** Reading photos at a small size, upright, without loading the full image. */
object Images {
    /**
     * [file] no larger than about [maxSide] on its longer side, turned the
     * right way up. Null if it cannot be read. A 50-megapixel photo read
     * whole needs 200 MB; read this way it needs a few.
     */
    fun decodeScaled(file: File, maxSide: Int): Bitmap? {
        val bitmap = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                // Turns the photo upright and reads HEIC. Not ThumbnailUtils:
                // that returns the tiny preview stored inside a camera photo.
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                    val longest = max(info.size.width, info.size.height)
                    var sample = 1
                    while (longest / (sample * 2) >= maxSide) sample *= 2
                    decoder.setTargetSampleSize(sample)
                    // Plain memory, so the pixels can be read and saved.
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }
            } else {
                decodeLegacy(file, maxSide)
            }
        } catch (e: Throwable) {
            null
        } ?: return null
        return scaleDown(bitmap, maxSide)
    }

    private fun decodeLegacy(file: File, maxSide: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        val bitmap = BitmapFactory.decodeFile(
            file.path,
            BitmapFactory.Options().apply { inSampleSize = sample },
        ) ?: return null
        val degrees = try {
            when (ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 0)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (e: Throwable) {
            0f
        }
        if (degrees == 0f) return bitmap
        return Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height,
            Matrix().apply { postRotate(degrees) }, true,
        )
    }

    fun scaleDown(bitmap: Bitmap, maxSide: Int): Bitmap {
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
}
