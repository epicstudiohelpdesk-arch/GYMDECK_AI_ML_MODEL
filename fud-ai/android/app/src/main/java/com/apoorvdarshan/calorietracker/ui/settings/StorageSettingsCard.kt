package com.apoorvdarshan.calorietracker.ui.settings

import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Cached
import androidx.compose.material.icons.outlined.Compress
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.apoorvdarshan.calorietracker.R
import com.apoorvdarshan.calorietracker.services.StorageMaintenance
import com.apoorvdarshan.calorietracker.ui.components.FudGlassDialog
import com.apoorvdarshan.calorietracker.ui.components.FudGlassDialogActions
import com.apoorvdarshan.calorietracker.ui.components.FudIconBubble
import com.apoorvdarshan.calorietracker.ui.theme.AppColors

/**
 * Settings › Data Management › Storage (mirrors iOS StorageSettingsSection): space used by
 * photos, regenerable caches and on-device models, plus Compress Photos (confirmed, never
 * automatic) and Clear Cache (thumbnails and workout frames only).
 */
@Composable
internal fun StorageSettingsCard(storage: StorageMaintenance) {
    val state by storage.ui.collectAsState()
    val context = LocalContext.current
    var showCompressConfirm by remember { mutableStateOf(false) }
    LaunchedEffect(storage) { storage.refresh() }

    fun size(bytes: Long?): String = bytes?.let { Formatter.formatShortFileSize(context, it) } ?: "…"

    SectionCard(title = stringResource(R.string.storage_title)) {
        StorageUsageRow(Icons.Outlined.PhotoLibrary, stringResource(R.string.storage_saved_photos), size(state.usage?.photoBytes))
        HorizontalDivider()
        StorageUsageRow(Icons.Outlined.Memory, stringResource(R.string.storage_on_device_models), size(state.usage?.modelBytes))
        HorizontalDivider()
        StorageUsageRow(Icons.Outlined.Cached, stringResource(R.string.storage_cache), size(state.usage?.cacheBytes))
        HorizontalDivider()
        StorageActionRow(
            icon = Icons.Outlined.Compress,
            label = if (state.compressing && state.compressionTotal > 0) {
                stringResource(R.string.storage_compressing_progress, state.compressedSoFar, state.compressionTotal)
            } else {
                stringResource(R.string.storage_compress_photos)
            },
            busy = state.compressing,
            enabled = !state.busy,
            onClick = { showCompressConfirm = true }
        )
        HorizontalDivider()
        StorageActionRow(
            icon = Icons.Outlined.Cached,
            label = stringResource(R.string.storage_clear_cache),
            busy = state.clearingCache,
            enabled = !state.busy,
            onClick = storage::clearCache
        )
        Text(
            stringResource(R.string.storage_footer),
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 12.dp),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.62f)
        )
    }

    if (showCompressConfirm) {
        FudGlassDialog(onDismissRequest = { showCompressConfirm = false }) {
            Text(stringResource(R.string.storage_compress_confirm_title), fontSize = 21.sp, fontWeight = FontWeight.Bold)
            Text(
                stringResource(R.string.storage_compress_confirm_message),
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.68f)
            )
            FudGlassDialogActions(
                primaryText = stringResource(R.string.storage_compress_action),
                onPrimary = {
                    showCompressConfirm = false
                    storage.compressPhotos()
                },
                dismissText = stringResource(R.string.action_cancel),
                onDismiss = { showCompressConfirm = false },
                destructive = true
            )
        }
    }

    state.compressionResult?.let { result ->
        // "Photos Compressed" only when a photo actually got smaller; otherwise the action name,
        // with a message that says why nothing (or not everything) changed.
        val title = if (result.compressedCount > 0) R.string.storage_compress_done_title else R.string.storage_compress_photos
        val summary = when {
            result.compressedCount > 0 -> stringResource(R.string.storage_compress_freed, size(result.bytesSaved))
            result.unreadableCount == 0 && result.failedCount == 0 -> stringResource(R.string.storage_compress_nothing)
            else -> null
        }
        val unreadable = if (result.unreadableCount > 0) stringResource(R.string.storage_compress_unreadable) else null
        val failed = if (result.failedCount > 0) stringResource(R.string.storage_compress_failed) else null
        FudGlassDialog(onDismissRequest = storage::dismissCompressionResult) {
            Text(stringResource(title), fontSize = 21.sp, fontWeight = FontWeight.Bold)
            Text(
                listOfNotNull(summary, unreadable, failed).joinToString(" "),
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.68f)
            )
            FudGlassDialogActions(
                primaryText = stringResource(R.string.action_ok),
                onPrimary = storage::dismissCompressionResult
            )
        }
    }
}

@Composable
private fun StorageUsageRow(icon: ImageVector, label: String, value: String) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        FudIconBubble(icon = icon, size = 22.dp, iconSize = 14.dp)
        Spacer(Modifier.width(14.dp))
        Text(label, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.58f),
            modifier = Modifier.padding(start = 12.dp)
        )
    }
}

@Composable
private fun StorageActionRow(
    icon: ImageVector,
    label: String,
    busy: Boolean,
    enabled: Boolean,
    onClick: () -> Unit
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        FudIconBubble(icon = icon, size = 22.dp, iconSize = 14.dp, tint = AppColors.Calorie)
        Spacer(Modifier.width(14.dp))
        Text(
            label,
            modifier = Modifier.weight(1f),
            color = if (enabled || busy) AppColors.Calorie else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.42f),
            style = MaterialTheme.typography.bodyLarge
        )
        if (busy) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
        }
    }
}
