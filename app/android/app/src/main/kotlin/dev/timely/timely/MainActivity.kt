package dev.timely.timely

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingLink: String? = null
    private val io = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        pendingLink = intent?.data?.toString()
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "timely/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(mapOf(
                    "usageAccess" to SyncWorker.hasUsageAccess(this),
                    "mediaAccess" to hasNotificationAccess(),
                    "batteryUnrestricted" to (getSystemService(POWER_SERVICE) as PowerManager)
                        .isIgnoringBatteryOptimizations(packageName),
                    "lastSync" to Store.lastSync(this),
                    "lastError" to Store.lastError(this),
                    "pending" to DayCache.pending(this).size,
                ))
                "openUsageAccess" -> { startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)); result.success(null) }
                "openMediaAccess" -> {
                    startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)); result.success(null)
                }
                "openBattery" -> {
                    startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
                    result.success(null)
                }
                "configure" -> {
                    Store.configure(this, call.argument<String>("server")!!, call.argument<String>("token")!!,
                        call.argument<String>("deviceId")!!)
                    SyncWorker.schedule(this)
                    result.success(null)
                }
                "clear" -> { SyncWorker.cancel(this); Store.clear(this); DayCache.clear(this); result.success(null) }
                "syncNow" -> io.execute {
                    val err = try { SyncWorker.syncNow(this) } catch (e: Exception) { e.message ?: "sync failed" }
                    runOnUiThread { result.success(err) }
                }
                "localChunks" -> io.execute {
                    val days = call.argument<Int>("days") ?: 400
                    val m = DayCache.recent(this, days)
                    runOnUiThread { result.success(m) }
                }
                "deviceName" -> result.success(
                    Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL)
                "initialLink" -> { result.success(pendingLink); pendingLink = null }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.toString()?.let { channel?.invokeMethod("link", it) }
    }

    private fun hasNotificationAccess(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
        val me = ComponentName(this, MediaListenerService::class.java).flattenToString()
        return flat.split(':').any { it == me }
    }
}
