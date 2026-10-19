package com.example.chatgpt_flutter
import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 耳机隔离回放与麦克风；外放不同时收音，避免把播报当成新提问。 */
class VoiceAudioBridge(private val activity: Activity, engine: FlutterEngine) {
    private val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "aipu/voice-audio")
    private var oldMode: Int? = null
    private var pending: MethodChannel.Result? = null
    init { channel.setMethodCallHandler { call, result ->
        when (call.method) {
            "prepareHeadset" -> {
                if (Build.VERSION.SDK_INT >= 31 && activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                    if (pending != null) result.error("permission_pending", "请先完成系统权限选择", null)
                    else { pending = result; activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 9142) }
                } else prepare(result)
            }
            "headsetConnected" -> result.success(connected())
            "release" -> { release(); result.success(null) }
            else -> result.notImplemented()
        }
    } }
    private fun headset(d: AudioDeviceInfo) = d.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
        d.type == AudioDeviceInfo.TYPE_USB_HEADSET || d.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
        (Build.VERSION.SDK_INT >= 31 && d.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
    private fun connected(): Boolean = try {
        if (Build.VERSION.SDK_INT >= 31) audio.availableCommunicationDevices.any(::headset)
        else audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any(::headset)
    } catch (_: SecurityException) { false }
    private fun prepare(result: MethodChannel.Result) {
        try {
            if (!connected()) { result.success(mapOf("safeDuplex" to false)); return }
            if (oldMode == null) oldMode = audio.mode
            audio.mode = AudioManager.MODE_IN_COMMUNICATION
            val ready = if (Build.VERSION.SDK_INT >= 31) {
                val d = audio.availableCommunicationDevices.firstOrNull(::headset)
                d != null && audio.setCommunicationDevice(d)
            } else {
                // 旧系统没有可确认的通信设备选择 API，保守只开放有线耳机。
                audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
                    it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET || it.type == AudioDeviceInfo.TYPE_USB_HEADSET
                }
            }
            if (!ready) release()
            result.success(mapOf("safeDuplex" to ready))
        } catch (_: Exception) { release(); result.success(mapOf("safeDuplex" to false)) }
    }
    fun permissionResult(code: Int, results: IntArray): Boolean {
        if (code != 9142) return false
        val result = pending; pending = null
        if (result != null) {
            if (results.firstOrNull() == PackageManager.PERMISSION_GRANTED) prepare(result)
            else result.success(mapOf("safeDuplex" to false))
        }
        return true
    }
    private fun release() {
        if (oldMode == null) return
        try {
            if (Build.VERSION.SDK_INT >= 31) audio.clearCommunicationDevice()
            else { @Suppress("DEPRECATION") audio.stopBluetoothSco() }
            audio.mode = oldMode!!
        } finally { oldMode = null }
    }
    fun close() {
        pending?.success(mapOf("safeDuplex" to false)); pending = null
        release(); channel.setMethodCallHandler(null)
    }
}
