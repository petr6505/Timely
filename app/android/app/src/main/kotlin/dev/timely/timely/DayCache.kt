package dev.timely.timely

import android.content.Context
import java.io.File

/**
 * Local copy of every captured day (gzip chunk files) plus the queue of days
 * still waiting to be uploaded. Survives offline periods of any length.
 */
object DayCache {
    private val lock = Any()
    private fun dir(ctx: Context) = File(ctx.filesDir, "days").apply { mkdirs() }
    private fun prefs(ctx: Context) = ctx.getSharedPreferences("timely_cache", Context.MODE_PRIVATE)

    fun put(ctx: Context, day: String, gz: ByteArray) = synchronized(lock) {
        val f = File(dir(ctx), "$day.json.gz")
        val tmp = File(dir(ctx), "$day.json.gz.tmp")
        tmp.writeBytes(gz)
        tmp.renameTo(f)
        val p = prefs(ctx)
        p.edit().putStringSet("pending", (p.getStringSet("pending", emptySet())!! + day).toSet()).apply()
    }

    fun get(ctx: Context, day: String): ByteArray? = synchronized(lock) {
        File(dir(ctx), "$day.json.gz").takeIf { it.exists() }?.readBytes()
    }

    fun pending(ctx: Context): List<String> = synchronized(lock) {
        prefs(ctx).getStringSet("pending", emptySet())!!.sorted()
    }

    /** Only clears the flag if the file wasn't re-captured since [uploadedBytes] was read. */
    fun markUploaded(ctx: Context, day: String, uploadedBytes: ByteArray) = synchronized(lock) {
        val current = File(dir(ctx), "$day.json.gz").takeIf { it.exists() }?.readBytes()
        if (current != null && !current.contentEquals(uploadedBytes)) return
        val p = prefs(ctx)
        p.edit().putStringSet("pending", (p.getStringSet("pending", emptySet())!! - day).toSet()).apply()
    }

    /** day -> bytes for the last [days] days (own-device data for the dashboard). */
    fun recent(ctx: Context, days: Int): Map<String, ByteArray> = synchronized(lock) {
        val cutoff = java.time.LocalDate.now().minusDays(days.toLong()).toString()
        dir(ctx).listFiles { f -> f.name.endsWith(".json.gz") }!!
            .filter { it.name.substringBefore('.') >= cutoff }
            .associate { it.name.substringBefore('.') to it.readBytes() }
    }

    /** Drop uploaded days older than [keepDays]; pending days are never dropped. */
    fun prune(ctx: Context, keepDays: Int = 45) = synchronized(lock) {
        val cutoff = java.time.LocalDate.now().minusDays(keepDays.toLong()).toString()
        val pending = prefs(ctx).getStringSet("pending", emptySet())!!
        dir(ctx).listFiles()?.forEach { f ->
            val day = f.name.substringBefore('.')
            if (day < cutoff && day !in pending) f.delete()
        }
    }

    fun clear(ctx: Context) = synchronized(lock) {
        dir(ctx).deleteRecursively()
        prefs(ctx).edit().clear().apply()
    }
}
