package com.example.chatgpt_flutter

import android.os.Bundle
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.devio.flutter.splashscreen.SplashScreen
import java.lang.ref.WeakReference
class MainActivity: FlutterActivity() {
    private var foreground = false
    private var permissionStart: Pair<MethodCall, MethodChannel.Result>? = null
    private var permissionGrantedWaiting = false
    private val handler = Handler(Looper.getMainLooper())
    private val permissionTimeout = Runnable { cancelPermissionStart("permissionTimeout") }

    override fun onCreate(savedInstanceState: Bundle?) {
        //SplashScreen.show(this)
        // or enable full screen
        SplashScreen.show(this, true)
        super.onCreate(savedInstanceState)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine? = AgentBackgroundBridge.retainedEngine()

    override fun shouldDestroyEngineWithHost(): Boolean = !AgentBackgroundBridge.shouldRetainEngine(flutterEngine)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val activity = WeakReference(this)
        AgentBackgroundBridge.attach(flutterEngine).setMethodCallHandler { call, result ->
            when (call.method) {
                "getCapabilities" -> result.success(mapOf("supported" to true, "mode" to AgentBackgroundBridge.MODE))
                "start" -> activity.get()?.startBackground(call, result)
                    ?: result.success(AgentBackgroundBridge.inactive("appNotForeground"))
                "update" -> {
                    val runId = call.argument<String>("runId")
                    if (runId != null && AgentBackgroundBridge.update(runId, number(call, "completed"), number(call, "total"), call.argument<String>("status") ?: "running")) result.success(null)
                    else result.error("task_inactive", "Agent background lease is no longer active", null)
                }
                "stop" -> {
                    val runId = call.argument<String>("runId")
                    if (runId != null) {
                        val host = activity.get()
                        val waiting = host?.permissionStart
                        if (waiting?.first?.argument<String>("runId") == runId) {
                            host.cancelPermissionStart("cancelled")
                        }
                        AgentBackgroundBridge.stop(runId)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        private fun number(call: MethodCall, key: String): Int = (call.argument<Number>(key)?.toLong() ?: 0L).coerceIn(0L, Int.MAX_VALUE.toLong()).toInt()
    }

    private fun startBackground(call: MethodCall, result: MethodChannel.Result) {
        val runId = call.argument<String>("runId")
        val cid = call.argument<Number>("cid")?.toLong()
        if (runId.isNullOrBlank() || runId.length > 256 || cid == null || cid <= 0L) {
            result.success(AgentBackgroundBridge.inactive("invalidArguments"))
            return
        }
        if (!foreground) {
            result.success(AgentBackgroundBridge.inactive("appNotForeground"))
            return
        }
        if (permissionStart != null) {
            result.success(AgentBackgroundBridge.inactive("permissionPending"))
            return
        }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            permissionStart = Pair(call, result)
            handler.postDelayed(permissionTimeout, 30_000L)
            try {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 9038)
            } catch (_: Exception) {
                cancelPermissionStart("notificationPermissionDenied")
            }
            return
        }
        if (!AgentBackgroundBridge.notificationsAllowed(this)) {
            result.success(AgentBackgroundBridge.inactive("notificationsDisabled"))
            return
        }
        AgentBackgroundBridge.start(applicationContext, runId, cid, number(call, "completed"), number(call, "total"), result)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 9038) return
        val waiting = permissionStart ?: return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            // 权限结果可能早于 onResume；只在可见 Activity 内启动前台服务。
            permissionGrantedWaiting = true
            finishPermissionStartIfResumed()
        } else cancelPermissionStart("notificationPermissionDenied")
    }

    private fun cancelPermissionStart(reason: String) {
        val waiting = permissionStart ?: return
        permissionStart = null
        permissionGrantedWaiting = false
        handler.removeCallbacks(permissionTimeout)
        waiting.second.success(AgentBackgroundBridge.inactive(reason))
    }

    private fun finishPermissionStartIfResumed() {
        if (!foreground || !permissionGrantedWaiting) return
        val waiting = permissionStart ?: return
        permissionStart = null
        permissionGrantedWaiting = false
        handler.removeCallbacks(permissionTimeout)
        startBackground(waiting.first, waiting.second)
    }

    override fun onResume() {
        super.onResume()
        foreground = true
        finishPermissionStartIfResumed()
    }

    override fun onPause() {
        foreground = false
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        cancelPermissionStart("activityDestroyed")
        AgentBackgroundBridge.detach(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
