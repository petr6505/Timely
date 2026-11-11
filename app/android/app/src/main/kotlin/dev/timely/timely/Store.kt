package dev.timely.timely

import android.content.Context
import android.content.SharedPreferences

/** Credentials + sync bookkeeping (app-private storage). */
object Store {
    private fun prefs(ctx: Context): SharedPreferences =
        ctx.getSharedPreferences("timely_native", Context.MODE_PRIVATE)

    fun configure(ctx: Context, server: String, token: String, deviceId: String) {
        prefs(ctx).edit().putString("server", server).putString("token", token).putString("deviceId", deviceId).apply()
    }

    fun clear(ctx: Context) = prefs(ctx).edit().clear().apply()

    fun server(ctx: Context) = prefs(ctx).getString("server", null)
    fun token(ctx: Context) = prefs(ctx).getString("token", null)

    /** Last local day whose capture is complete (captured after it ended). */
    fun lastCompleteDay(ctx: Context) = prefs(ctx).getString("lastCompleteDay", null)
    fun setLastCompleteDay(ctx: Context, day: String) = prefs(ctx).edit().putString("lastCompleteDay", day).apply()
    fun setLastSync(ctx: Context, ms: Long, error: String?) =
        prefs(ctx).edit().putLong("lastSync", ms).putString("lastError", error).apply()
    fun lastSync(ctx: Context) = prefs(ctx).getLong("lastSync", 0)
    fun lastError(ctx: Context) = prefs(ctx).getString("lastError", null)
}
