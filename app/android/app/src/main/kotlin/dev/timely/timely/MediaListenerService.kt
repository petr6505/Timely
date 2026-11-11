package dev.timely.timely

import android.content.ComponentName
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.service.notification.NotificationListenerService

/**
 * Bound by the system once the user grants notification access. We never read
 * notifications; the binding only lets us observe media sessions so background
 * playback (e.g. Spotify with the screen off) is recorded as listening time.
 */
class MediaListenerService : NotificationListenerService() {
    private var msm: MediaSessionManager? = null
    private val callbacks = HashMap<MediaController, MediaController.Callback>()

    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { list ->
        track(list ?: emptyList())
    }

    override fun onListenerConnected() {
        MediaStore.resetOngoing(this)
        MediaStore.serviceAlive = true
        val m = getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
        msm = m
        val cn = ComponentName(this, MediaListenerService::class.java)
        try {
            m.addOnActiveSessionsChangedListener(sessionsListener, cn)
            track(m.getActiveSessions(cn))
        } catch (_: SecurityException) {
        }
    }

    override fun onListenerDisconnected() {
        val now = System.currentTimeMillis()
        callbacks.keys.forEach { MediaStore.stop(this, it.packageName, now) }
        callbacks.forEach { (c, cb) -> c.unregisterCallback(cb) }
        callbacks.clear()
        msm?.removeOnActiveSessionsChangedListener(sessionsListener)
        MediaStore.serviceAlive = false
    }

    private fun track(list: List<MediaController>) {
        val now = System.currentTimeMillis()
        // drop controllers that went away
        val gone = callbacks.keys.filter { old -> list.none { it.sessionToken == old.sessionToken } }
        for (c in gone) {
            c.unregisterCallback(callbacks.remove(c)!!)
            MediaStore.stop(this, c.packageName, now)
        }
        for (c in list) {
            if (callbacks.keys.any { it.sessionToken == c.sessionToken }) continue
            val cb = object : MediaController.Callback() {
                override fun onPlaybackStateChanged(state: PlaybackState?) = update(c.packageName, state)
                override fun onSessionDestroyed() = MediaStore.stop(this@MediaListenerService, c.packageName, System.currentTimeMillis())
            }
            c.registerCallback(cb)
            callbacks[c] = cb
            update(c.packageName, c.playbackState)
        }
    }

    private fun update(pkg: String, state: PlaybackState?) {
        val now = System.currentTimeMillis()
        if (state?.state == PlaybackState.STATE_PLAYING) MediaStore.start(this, pkg, now)
        else MediaStore.stop(this, pkg, now)
    }
}
