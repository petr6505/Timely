package dev.timely.timely

import android.app.AppOpsManager
import android.content.Context
import android.os.Process
import androidx.work.*
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.time.LocalDate
import java.time.LocalTime
import java.util.concurrent.TimeUnit

/**
 * Runs every 15 minutes regardless of connectivity. Captures recent days into
 * [DayCache], then uploads whatever is pending. When offline, a one-off flush job
 * with a network constraint picks the upload up as soon as a connection is back.
 */
class SyncWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {
    override fun doWork(): Result {
        val ctx = applicationContext
        val flushOnly = inputData.getBoolean(KEY_FLUSH, false)
        try {
            if (!flushOnly) capture(ctx)
        } catch (e: Exception) {
            Store.setLastSync(ctx, Store.lastSync(ctx), "capture: ${e.message}")
        }
        return when (val r = upload(ctx)) {
            UploadResult.Ok -> Result.success()
            UploadResult.Unauthorized -> Result.failure()
            UploadResult.Offline -> {
                scheduleFlush(ctx)
                // periodic work keeps its schedule; the flush job retries on reconnect
                if (flushOnly) Result.retry() else Result.success()
            }
        }
    }

    enum class UploadResult { Ok, Offline, Unauthorized }
    class Unauthorized : Exception("unauthorized")

    companion object {
        private const val NAME = "timely-sync"
        private const val FLUSH = "timely-flush"
        private const val KEY_FLUSH = "flush"
        private const val BACKFILL_DAYS = 7L
        private const val MAX_CATCHUP_DAYS = 10L // Android keeps raw usage events ~7-10 days

        fun schedule(ctx: Context) {
            // no network constraint: capture must run offline too
            val req = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES).build()
            WorkManager.getInstance(ctx).enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.UPDATE, req)
            WorkManager.getInstance(ctx).enqueue(OneTimeWorkRequestBuilder<SyncWorker>().build())
        }

        fun scheduleFlush(ctx: Context) {
            val req = OneTimeWorkRequestBuilder<SyncWorker>()
                .setInputData(workDataOf(KEY_FLUSH to true))
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
                .build()
            WorkManager.getInstance(ctx).enqueueUniqueWork(FLUSH, ExistingWorkPolicy.KEEP, req)
        }

        fun cancel(ctx: Context) {
            WorkManager.getInstance(ctx).cancelUniqueWork(NAME)
            WorkManager.getInstance(ctx).cancelUniqueWork(FLUSH)
        }

        fun hasUsageAccess(ctx: Context): Boolean {
            val ops = ctx.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            return ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName) ==
                AppOpsManager.MODE_ALLOWED
        }

        /** Rebuild every day that isn't complete yet and store it locally. */
        @Synchronized
        fun capture(ctx: Context) {
            if (Store.token(ctx) == null) return
            if (!hasUsageAccess(ctx)) throw IllegalStateException("usage access not granted")
            MediaStore.checkpoint(ctx, System.currentTimeMillis())
            val today = LocalDate.now()
            val lastComplete = Store.lastCompleteDay(ctx)?.let { LocalDate.parse(it) }
            var d = when {
                lastComplete == null -> today.minusDays(BACKFILL_DAYS)
                else -> maxOf(lastComplete.plusDays(1), today.minusDays(MAX_CATCHUP_DAYS))
            }
            val collector = UsageCollector(ctx)
            while (!d.isAfter(today)) {
                collector.buildDay(d)?.let { DayCache.put(ctx, d.toString(), UsageCollector.gzip(it)) }
                d = d.plusDays(1)
            }
            // yesterday is complete once captured a little after midnight
            if (LocalTime.now().isAfter(LocalTime.of(0, 20))) Store.setLastCompleteDay(ctx, today.minusDays(1).toString())
            DayCache.prune(ctx)
        }

        /** Upload all pending days, oldest first. */
        @Synchronized
        fun upload(ctx: Context): UploadResult {
            val server = Store.server(ctx) ?: return UploadResult.Ok
            val token = Store.token(ctx) ?: return UploadResult.Ok
            try {
                for (day in DayCache.pending(ctx)) {
                    val bytes = DayCache.get(ctx, day) ?: continue
                    put(server, token, day, bytes)
                    DayCache.markUploaded(ctx, day, bytes)
                }
                Store.setLastSync(ctx, System.currentTimeMillis(), null)
                return UploadResult.Ok
            } catch (e: Unauthorized) {
                Store.setLastSync(ctx, Store.lastSync(ctx), "signed out on server")
                return UploadResult.Unauthorized
            } catch (e: Exception) {
                val n = DayCache.pending(ctx).size
                Store.setLastSync(ctx, Store.lastSync(ctx), "offline · $n day${if (n == 1) "" else "s"} waiting")
                return UploadResult.Offline
            }
        }

        /** Used by the UI's sync button. Returns an error message or null. */
        fun syncNow(ctx: Context): String? {
            try { capture(ctx) } catch (e: Exception) { return e.message }
            return when (upload(ctx)) {
                UploadResult.Ok -> null
                UploadResult.Unauthorized -> "signed out on server"
                UploadResult.Offline -> { scheduleFlush(ctx); "offline, data saved and will upload when connected" }
            }
        }

        private fun put(server: String, token: String, day: String, body: ByteArray) {
            val c = URL("$server/v1/chunks/$day").openConnection() as HttpURLConnection
            try {
                c.requestMethod = "PUT"
                c.connectTimeout = 20_000
                c.readTimeout = 30_000
                c.doOutput = true
                c.setRequestProperty("authorization", "Bearer $token")
                c.setRequestProperty("content-type", "application/octet-stream")
                c.outputStream.use { it.write(body) }
                val code = c.responseCode
                if (code == 401) throw Unauthorized()
                if (code >= 400) throw IOException("upload failed: HTTP $code")
            } finally {
                c.disconnect()
            }
        }
    }
}
