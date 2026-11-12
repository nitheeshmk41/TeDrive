package dev.tedrive.tedrive

import android.content.Context
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The one Flutter engine of the app process, and the way native code asks
 * the Dart side (which owns the Telegram session) to download a file.
 *
 * Normally the engine belongs to MainActivity. When another app opens a
 * TeDrive file through the system file picker while TeDrive is not running,
 * an engine is started here without any screen; if the user then opens
 * TeDrive, MainActivity shows that same engine. Either way there is only
 * ever one engine, and so only one Telegram session.
 */
object TeDriveEngine {
    const val ENGINE_ID = "tedrive_main"
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var channel: MethodChannel? = null
    private var attached: FlutterEngine? = null

    fun attach(engine: FlutterEngine) {
        attached = engine
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "tedrive/provider")
    }

    /** Called when MainActivity destroys an engine it owned. */
    fun detach(engine: FlutterEngine) {
        if (attached === engine && FlutterEngineCache.getInstance().get(ENGINE_ID) !== engine) {
            attached = null
            channel = null
        }
    }

    private fun ensureEngine(context: Context) {
        if (channel != null) return
        val engine = FlutterEngine(context.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        attach(engine)
    }

    /**
     * Asks Dart to download the file of [messageId] and returns its local
     * path, or null if that failed. Blocks, so never call it on the main
     * thread.
     */
    fun requestFile(context: Context, messageId: Long, signal: CancellationSignal?): String? {
        check(Looper.myLooper() != Looper.getMainLooper()) { "must not block the main thread" }
        val done = CountDownLatch(1)
        var path: String? = null
        main.post {
            try {
                ensureEngine(context)
                channel!!.invokeMethod(
                    "download",
                    mapOf("id" to messageId),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            path = result as? String
                            done.countDown()
                        }

                        override fun error(code: String, message: String?, details: Any?) = done.countDown()

                        override fun notImplemented() = done.countDown()
                    },
                )
            } catch (e: Throwable) {
                done.countDown()
            }
        }
        // Large files take a while; give up after 15 minutes or on cancel.
        val deadline = System.currentTimeMillis() + 15 * 60 * 1000
        while (!done.await(500, TimeUnit.MILLISECONDS)) {
            if (signal?.isCanceled == true || System.currentTimeMillis() > deadline) return null
        }
        return path
    }
}
