package dev.timely.timely

import android.content.Context
import java.io.File

/** Media playback intervals recorded by [MediaListenerService]. */
object MediaStore {
    @Volatile var serviceAlive = false
    private val lock = Any()

    private fun log(ctx: Context) = File(ctx.filesDir, "media.log")
    private fun ongoingPrefs(ctx: Context) = ctx.getSharedPreferences("timely_media", Context.MODE_PRIVATE)

    fun start(ctx: Context, pkg: String, now: Long) = synchronized(lock) {
        val p = ongoingPrefs(ctx)
        if (!p.contains(pkg)) p.edit().putLong(pkg, now).apply()
    }

    fun stop(ctx: Context, pkg: String, now: Long) = synchronized(lock) {
        val p = ongoingPrefs(ctx)
        val since = p.getLong(pkg, -1)
        if (since > 0 && now > since) append(ctx, pkg, since, now)
        p.edit().remove(pkg).apply()
    }

    /** Drop ongoing entries left over from a dead process. */
    fun resetOngoing(ctx: Context) = synchronized(lock) { ongoingPrefs(ctx).edit().clear().apply() }

    /** Persist ongoing playback up to now so a process kill loses at most one interval. */
    fun checkpoint(ctx: Context, now: Long) = synchronized(lock) {
        if (!serviceAlive) return
        val p = ongoingPrefs(ctx)
        val e = p.edit()
        for ((pkg, v) in p.all) {
            val since = (v as? Long) ?: continue
            if (now > since) append(ctx, pkg, since, now)
            e.putLong(pkg, now)
        }
        e.apply()
    }

    private fun append(ctx: Context, pkg: String, a: Long, b: Long) {
        val f = log(ctx)
        f.appendText("$pkg,$a,$b\n")
        if (f.length() > 512 * 1024) prune(ctx)
    }

    private fun prune(ctx: Context) {
        val cutoff = System.currentTimeMillis() - 10L * 86400_000
        val f = log(ctx)
        val keep = f.readLines().filter { (it.split(',').getOrNull(2)?.toLongOrNull() ?: 0) > cutoff }
        f.writeText(keep.joinToString("\n", postfix = if (keep.isEmpty()) "" else "\n"))
    }

    /** All intervals (pkg, startMs, endMs) overlapping [from, to), including live ones. */
    fun intervals(ctx: Context, from: Long, to: Long, now: Long): List<Triple<String, Long, Long>> = synchronized(lock) {
        val out = ArrayList<Triple<String, Long, Long>>()
        val f = log(ctx)
        if (f.exists()) f.forEachLine { line ->
            val p = line.split(',')
            if (p.size == 3) {
                val a = p[1].toLongOrNull() ?: return@forEachLine
                val b = p[2].toLongOrNull() ?: return@forEachLine
                if (b > from && a < to) out.add(Triple(p[0], maxOf(a, from), minOf(b, to)))
            }
        }
        if (serviceAlive) for ((pkg, v) in ongoingPrefs(ctx).all) {
            val since = (v as? Long) ?: continue
            if (now > from && since < to) out.add(Triple(pkg, maxOf(since, from), minOf(now, to)))
        }
        out
    }
}
