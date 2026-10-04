package com.example.chatgpt_flutter

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 同一进程只托管一个已由用户发起的 Agent；所有操作都在主线程执行。 */
internal object AgentBackgroundBridge {
    const val CHANNEL = "com.example.chatgpt_flutter/agent_background"
    const val MODE = "androidForeground"
    private val handler = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var hostAttached = false
    private var retainUntil = 0L
    private var pendingRunId: String? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingTimeout: Runnable? = null
    private var activeRunId: String? = null
    private var service: AgentBackgroundService? = null

    fun attach(flutterEngine: FlutterEngine): MethodChannel {
        engine = flutterEngine
        hostAttached = true
        retainUntil = 0L
        return MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            channel = it
        }
    }

    fun retainedEngine(): FlutterEngine? = if (isRunning() || retainUntil > SystemClock.elapsedRealtime()) engine else null

    fun isRunning(): Boolean = activeRunId != null || pendingRunId != null

    fun shouldRetainEngine(flutterEngine: FlutterEngine?): Boolean =
        engine === flutterEngine && retainedEngine() != null

    fun detach(flutterEngine: FlutterEngine) {
        if (engine !== flutterEngine) return
        hostAttached = false
        // 活动 Service 保留 Dart VM；普通 Activity 销毁仍由 Flutter 清理引擎。
        if (retainedEngine() == null) {
            channel = null
            engine = null
        }
    }

    fun inactive(reason: String): Map<String, Any> = mapOf("active" to false, "mode" to MODE, "reason" to reason)

    fun notificationsAllowed(context: Context): Boolean {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26) {
            val existing = manager.getNotificationChannel(AgentBackgroundService.NOTIFICATION_CHANNEL)
            if (existing?.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        return true
    }

    fun start(context: Context, runId: String, cid: Long, completed: Int, total: Int, result: MethodChannel.Result) {
        if (activeRunId == runId && service != null) {
            result.success(mapOf("active" to true, "mode" to MODE))
            return
        }
        if (isRunning()) {
            result.success(inactive("anotherRunActive"))
            return
        }
        pendingRunId = runId
        pendingResult = result
        pendingTimeout = Runnable {
            if (pendingRunId == runId) {
                finishStart(runId, false, "serviceStartTimeout")
                service?.stopRun(runId)
            }
        }.also { handler.postDelayed(it, 4_000L) }
        val intent = Intent(context, AgentBackgroundService::class.java)
            .setAction(AgentBackgroundService.ACTION_START)
            .putExtra("runId", runId).putExtra("cid", cid)
            .putExtra("completed", completed).putExtra("total", total)
        try {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        } catch (_: Exception) {
            finishStart(runId, false, "serviceStartRejected")
        }
    }

    fun isPending(runId: String): Boolean = pendingRunId == runId

    fun foregroundStarted(runId: String, foregroundService: AgentBackgroundService) {
        if (!isPending(runId)) {
            foregroundService.stopRun(runId)
            return
        }
        service = foregroundService
        activeRunId = runId
        finishStart(runId, true)
    }

    fun foregroundFailed(runId: String) = finishStart(runId, false, "serviceStartRejected")

    private fun finishStart(runId: String, active: Boolean, reason: String? = null) {
        if (pendingRunId != runId) return
        pendingTimeout?.let { handler.removeCallbacks(it) }
        pendingTimeout = null
        val result = pendingResult
        pendingRunId = null
        pendingResult = null
        result?.success(if (active) mapOf("active" to true, "mode" to MODE) else inactive(reason ?: "serviceStartRejected"))
    }

    fun update(runId: String, completed: Int, total: Int, status: String): Boolean =
        activeRunId == runId && service?.updateRun(runId, completed, total, status) == true

    fun stop(runId: String) {
        if (pendingRunId == runId) finishStart(runId, false, "cancelled")
        if (activeRunId == runId) service?.stopRun(runId)
    }

    fun serviceEnded(runId: String, reason: String?) {
        if (activeRunId != runId && pendingRunId != runId) return
        if (pendingRunId == runId) finishStart(runId, false, reason ?: "systemStopped")
        activeRunId = null
        service = null
        // 中断后给 Dart 留出持久化窗口；没有 Activity 时最多保留 15 秒。
        retainUntil = SystemClock.elapsedRealtime() + 15_000L
        if (reason != null) channel?.invokeMethod("onInterrupted", mapOf("runId" to runId, "reason" to reason))
        handler.postDelayed({
            if (!hostAttached && !isRunning() && retainUntil <= SystemClock.elapsedRealtime()) {
                channel?.setMethodCallHandler(null)
                channel = null
                val oldEngine = engine
                engine = null
                oldEngine?.destroy()
            }
        }, 15_100L)
    }
}
