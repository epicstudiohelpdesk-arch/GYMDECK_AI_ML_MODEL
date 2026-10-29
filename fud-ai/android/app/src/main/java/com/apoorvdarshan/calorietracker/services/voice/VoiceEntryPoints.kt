package com.apoorvdarshan.calorietracker.services.voice

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.apoorvdarshan.calorietracker.MainActivity
import com.apoorvdarshan.calorietracker.R

/**
 * How the system opens the app straight into a listening session: the Quick Settings
 * tile, the launcher shortcut (res/xml/shortcuts.xml, on every launcher alias) and the
 * home-screen widget all send this intent to [MainActivity].
 */
object VoiceEntryPoints {
    /** Static shortcuts need an action; it must match res/xml/shortcuts.xml. */
    const val ACTION_TALK = "com.apoorvdarshan.calorietracker.TALK"
    const val EXTRA_START_VOICE = "start_voice_assistant"

    fun launchIntent(context: Context): Intent = Intent(context, MainActivity::class.java)
        .setAction(ACTION_TALK)
        .putExtra(EXTRA_START_VOICE, true)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    fun isVoiceLaunch(intent: Intent?): Boolean =
        intent != null && (intent.action == ACTION_TALK || intent.getBooleanExtra(EXTRA_START_VOICE, false))

    /** Clears the request so recreating the activity doesn't start another conversation. */
    fun consume(intent: Intent?) {
        intent ?: return
        if (intent.action == ACTION_TALK) intent.action = null
        intent.removeExtra(EXTRA_START_VOICE)
    }
}

/** Quick Settings tile: "Talk to Fud AI". */
class VoiceAssistantTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.apply {
            state = Tile.STATE_INACTIVE
            label = getString(R.string.voice_talk_to_fud_ai)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) subtitle = getString(R.string.app_name)
            updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { open() } else open()
    }

    private fun open() {
        val intent = VoiceEntryPoints.launchIntent(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pending = PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }
}
