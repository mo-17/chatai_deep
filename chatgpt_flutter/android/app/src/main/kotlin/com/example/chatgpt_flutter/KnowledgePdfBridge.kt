package com.example.chatgpt_flutter

import android.content.Context
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

object KnowledgePdfBridge {
    fun attach(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, "aipu/knowledge-pdf").setMethodCallHandler { call, result ->
            if (call.method != "render") { result.notImplemented(); return@setMethodCallHandler }
            val path = call.argument<String>("path") ?: ""
            val index = call.argument<Int>("page") ?: -1
            Thread {
                try {
                    val file = File(path).canonicalFile
                    val root = File(app.applicationInfo.dataDir).canonicalPath + File.separator
                    require(file.path.startsWith(root) && file.name.matches(Regex("[a-f0-9]{64}\\.pdf")))
                    require(index >= 0 && file.length() <= 64L * 1024 * 1024)
                    val bytes = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                        PdfRenderer(fd).use { renderer ->
                            require(index < renderer.pageCount)
                            renderer.openPage(index).use { page ->
                                require(page.width > 0 && page.height > 0)
                                val scale = minOf(1200.0 / page.width, 2000.0 / page.height)
                                val bitmap = Bitmap.createBitmap((page.width * scale).toInt().coerceIn(1,1200), (page.height * scale).toInt().coerceIn(1,2000), Bitmap.Config.ARGB_8888)
                                try {
                                    bitmap.eraseColor(android.graphics.Color.WHITE)
                                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                    ByteArrayOutputStream().use { out -> bitmap.compress(Bitmap.CompressFormat.PNG, 100, out); out.toByteArray() }
                                } finally { bitmap.recycle() }
                            }
                        }
                    }
                    Handler(Looper.getMainLooper()).post { result.success(bytes) }
                } catch (_: Exception) {
                    Handler(Looper.getMainLooper()).post { result.error("pdf_unavailable", "PDF原件不可用", null) }
                }
            }.start()
        }
    }
}
