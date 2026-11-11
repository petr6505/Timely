package dev.timely.timely

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.pm.PackageManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.time.LocalDate
import java.time.ZoneId
import java.util.zip.GZIPOutputStream

/**
 * Builds a Timely day chunk (see packages/timely_core/lib/src/chunk.dart for the format)
 * from Android's UsageStats event log plus recorded media playback.
 */
class UsageCollector(private val ctx: Context) {
    private val usm = ctx.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
    private val pm = ctx.packageManager
    private val labels = HashMap<String, String>()

    private fun label(pkg: String): String = labels.getOrPut(pkg) {
        try {
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (_: PackageManager.NameNotFoundException) {
            pkg.substringAfterLast('.').replaceFirstChar { it.uppercase() }
        }
    }

    private data class Sess(val app: Int, val start: Int, var dur: Int)

    fun buildDay(day: LocalDate): JSONObject? {
        val zone = ZoneId.systemDefault()
        val dayStart = day.atStartOfDay(zone).toInstant().toEpochMilli()
        val dayEnd = day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        val now = System.currentTimeMillis()
        if (dayStart > now) return null
        val end = minOf(dayEnd, now)

        val apps = ArrayList<Pair<String, String>>()
        val index = HashMap<String, Int>()
        fun appIdx(pkg: String) = index.getOrPut(pkg) { apps.add(pkg to label(pkg)); apps.size - 1 }

        val focused = ArrayList<Sess>()
        fun addFocus(pkg: String, a: Long, b: Long) {
            val s = maxOf(a, dayStart)
            val e = minOf(b, end)
            if (e - s < 1000) return
            val idx = appIdx(pkg)
            val start = ((s - dayStart) / 1000).toInt()
            val dur = ((e - s) / 1000).toInt()
            val last = focused.lastOrNull()
            if (last != null && last.app == idx && start <= last.start + last.dur + 5) {
                last.dur = maxOf(last.dur, start + dur - last.start)
            } else focused.add(Sess(idx, start, dur))
        }

        // Replay the event log; start 3h early to learn which app was in front at midnight.
        val events = usm.queryEvents(dayStart - 3 * 3600_000L, end)
        val ev = UsageEvents.Event()
        var cur: String? = null
        var curSince = 0L
        var unlocks = 0
        var any = false
        while (events.hasNextEvent()) {
            events.getNextEvent(ev)
            val t = ev.timeStamp
            when (ev.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> {
                    val pkg = ev.packageName
                    if (cur != pkg) {
                        cur?.let { addFocus(it, curSince, t) }
                        cur = pkg
                        curSince = t
                    }
                }
                UsageEvents.Event.ACTIVITY_PAUSED, UsageEvents.Event.ACTIVITY_STOPPED -> {
                    if (ev.packageName == cur) {
                        addFocus(cur!!, curSince, t)
                        cur = null
                    }
                }
                UsageEvents.Event.SCREEN_NON_INTERACTIVE, UsageEvents.Event.KEYGUARD_SHOWN,
                UsageEvents.Event.DEVICE_SHUTDOWN -> {
                    cur?.let { addFocus(it, curSince, t) }
                    cur = null
                }
                UsageEvents.Event.KEYGUARD_HIDDEN -> if (t >= dayStart) unlocks++
            }
            if (t >= dayStart) any = true
        }
        cur?.let { addFocus(it, curSince, end) }

        val media = ArrayList<Sess>()
        for ((pkg, a, b) in MediaStore.intervals(ctx, dayStart, end, now).sortedBy { it.second }) {
            val start = ((a - dayStart) / 1000).toInt()
            val dur = ((b - a) / 1000).toInt()
            if (dur <= 0) continue
            val idx = appIdx(pkg)
            val last = media.lastOrNull { it.app == idx }
            if (last != null && start <= last.start + last.dur + 5) {
                last.dur = maxOf(last.dur, start + dur - last.start)
            } else media.add(Sess(idx, start, dur))
        }

        if (!any && focused.isEmpty() && media.isEmpty()) return null
        fun flat(list: List<Sess>): JSONArray {
            val arr = JSONArray()
            var prev = 0
            for (s in list.sortedBy { it.start }) {
                arr.put(s.app); arr.put(s.start - prev); arr.put(s.dur)
                prev = s.start
            }
            return arr
        }
        return JSONObject().apply {
            put("v", 1)
            put("d", day.toString())
            put("z", zone.rules.getOffset(java.time.Instant.ofEpochMilli(dayStart)).totalSeconds / 60)
            put("a", JSONArray().apply { apps.forEach { put(JSONArray().put(it.first).put(it.second)) } })
            put("f", flat(focused))
            if (media.isNotEmpty()) put("m", flat(media))
            if (unlocks > 0) put("u", unlocks)
        }
    }

    companion object {
        fun gzip(json: JSONObject): ByteArray {
            val bos = ByteArrayOutputStream()
            GZIPOutputStream(bos).use { it.write(json.toString().toByteArray(Charsets.UTF_8)) }
            return bos.toByteArray()
        }
    }
}
