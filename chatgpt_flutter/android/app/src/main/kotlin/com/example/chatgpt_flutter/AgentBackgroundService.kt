package com.example.chatgpt_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

/** 模型取数 / 本地文件任务的前台租约，执行仍在同一 FlutterEngine 内。 */
class AgentBackgroundService : Service() {
    companion object {
        internal const val NOTIFICATION_CHANNEL = "agent_tasks"
        internal const val ACTION_START = "com.example.chatgpt_flutter.AGENT_START"
        private const val ACTION_STOP = "com.example.chatgpt_flutter.AGENT_STOP"
        private const val NOTIFICATION_ID = 12041
        // 所有平台版本均有本地期限，不依赖 Android 15 的系统共享 6 小时上限。
        private const val MAX_RUN_MILLIS = 30L * 60L * 1000L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var runId: String? = null
    private var cid = 0L
    private var completed = 0
    private var total = 0
    private var status = "running"
    private var wakeLock: PowerManager.WakeLock? = null
    private val expiry = Runnable { finish("expired") }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val requestedRunId = intent?.getStringExtra("runId")
        if (intent?.action == ACTION_STOP) {
            if (requestedRunId != null && requestedRunId == runId) finish("userStopped")
            else if (runId == null) stopSelfResult(startId)
            return START_NOT_STICKY
        }
        if (intent?.action != ACTION_START || requestedRunId.isNullOrBlank() || !AgentBackgroundBridge.isPending(requestedRunId)) {
            if (runId == null) stopSelfResult(startId)
            return START_NOT_STICKY
        }
        if (runId != null && runId != requestedRunId) {
            AgentBackgroundBridge.foregroundFailed(requestedRunId)
            return START_NOT_STICKY
        }
        runId = requestedRunId
        cid = intent.getLongExtra("cid", 0L)
        completed = intent.getIntExtra("completed", 0).coerceAtLeast(0)
        total = intent.getIntExtra("total", 0).coerceAtLeast(0)
        try {
            createNotificationChannel()
            if (!AgentBackgroundBridge.notificationsAllowed(this)) throw SecurityException("Notifications disabled")
            val notification = buildNotification(requestedRunId)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else startForeground(NOTIFICATION_ID, notification)
            val power = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:agentTask").also {
                it.setReferenceCounted(false)
                it.acquire(MAX_RUN_MILLIS + 10_000L)
            }
            handler.postDelayed(expiry, MAX_RUN_MILLIS)
            // 只有 startForeground 与唤醒锁均成功才向 Dart 声明后台可执行。
            AgentBackgroundBridge.foregroundStarted(requestedRunId, this)
        } catch (_: Exception) {
            AgentBackgroundBridge.foregroundFailed(requestedRunId)
            finish(null)
        }
        return START_NOT_STICKY
    }

    internal fun updateRun(requestedRunId: String, newCompleted: Int, newTotal: Int, newStatus: String): Boolean {
        if (runId != requestedRunId) return false
        completed = newCompleted.coerceAtLeast(0)
        total = newTotal.coerceAtLeast(0)
        status = newStatus
        try {
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                finish("systemStopped")
                return false
            }
            if (!AgentBackgroundBridge.notificationsAllowed(this)) {
                finish("systemStopped")
                return false
            }
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIFICATION_ID, buildNotification(requestedRunId))
            return true
        } catch (_: Exception) {
            finish("systemStopped")
            return false
        }
    }

    internal fun stopRun(requestedRunId: String) {
        if (runId == requestedRunId) finish(null)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(NOTIFICATION_CHANNEL, "Agent 任务", NotificationManager.IMPORTANCE_LOW)
            channel.description = "显示用户发起的 Agent 任务执行进度，可随时停止"
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(currentRunId: String): Notification {
        val open = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra("agentConversationId", cid)
        val contentIntent = PendingIntent.getActivity(this, NOTIFICATION_ID, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        // runId 参与 PendingIntent identity；过期通知的停止动作不会命中新任务。
        val stop = Intent(this, AgentBackgroundService::class.java).setAction(ACTION_STOP)
            .setData(Uri.parse("agent-task://stop/${Uri.encode(currentRunId)}")).putExtra("runId", currentRunId)
        val stopIntent = PendingIntent.getService(this, NOTIFICATION_ID, stop, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stage = when (status) {
            "preparing" -> "准备输入"
            "reading" -> "读取文件"
            "tool", "executing" -> "执行工具"
            "verifying" -> "验收成果"
            "waitingConfirmation" -> "等待确认"
            else -> "正在执行"
        }
        val progress = if (total > 0) "清单 ${completed.coerceAtMost(total)}/$total" else "处理中"
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, NOTIFICATION_CHANNEL) else Notification.Builder(this)
        return builder.setSmallIcon(R.drawable.ic_agent_background)
            .setContentTitle("Agent 任务").setContentText("$stage · $progress")
            .setContentIntent(contentIntent).setOngoing(true).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setProgress(total, completed.coerceAtMost(total), total <= 0)
            .addAction(Notification.Action.Builder(null, "停止任务", stopIntent).build())
            .build()
    }

    private fun finish(reason: String?) {
        val stoppedRunId = runId ?: return
        runId = null
        handler.removeCallbacks(expiry)
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        // 先立刻释放系统资源，再通知 Dart 保存断点。
        stopSelf()
        AgentBackgroundBridge.serviceEnded(stoppedRunId, reason)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        finish("expired")
        // 空运行同样立即停止，满足系统超时回调时限。
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        finish("systemStopped")
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        finish("systemStopped")
        super.onDestroy()
    }
}
