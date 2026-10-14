package io.github.qwertyuiop1995.dsmnativeclient

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.net.Uri
import io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.ForegroundInfo
import androidx.work.WorkManager
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferDirection

internal object TransferNotifications {
    const val CHANNEL_ID = "file_transfers"
    const val EXTRA_OPEN_TRANSFERS = "open_transfers"

    fun foreground(
        context: Context,
        taskId: String,
        workId: java.util.UUID,
        state: TransferState,
        completedBytes: Long,
        totalBytes: Long?,
        direction: TransferDirection = TransferDirection.DOWNLOAD,
        recordKind: WorkspaceRecordKind = direction.recordKind(),
        openTaskIntent: PendingIntent? = null,
    ): ForegroundInfo {
        ensureChannel(context)
        val isPhotoBackup = isPhotoBackup(context, taskId, direction)
        val content = foregroundNotificationContent(direction, state, isPhotoBackup)
        val progressMaximum = 1_000
        val progress = totalBytes?.takeIf { it > 0 }?.let {
            ((completedBytes.toDouble() / it.toDouble()) * progressMaximum)
                .toInt()
                .coerceIn(0, progressMaximum)
        }
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(
                if (direction == TransferDirection.UPLOAD) {
                    android.R.drawable.stat_sys_upload
                } else {
                    android.R.drawable.stat_sys_download
                },
            )
            .setContentTitle(context.getString(content.title))
            .setContentText(context.getString(content.status))
            .setContentIntent(openTaskIntent ?: openAppIntent(context, taskId, recordKind))
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setProgress(progressMaximum, progress ?: 0, progress == null)
            .addAction(
                0,
                context.getString(R.string.cancel),
                WorkManager.getInstance(context).createCancelPendingIntent(workId),
            )
            .build()
        return ForegroundInfo(
            notificationId(taskId),
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
    }

    @SuppressLint("MissingPermission")
    fun completion(
        context: Context,
        taskId: String,
        succeeded: Boolean,
        direction: TransferDirection = TransferDirection.DOWNLOAD,
    ) = completion(
        context,
        taskId,
        if (succeeded) TransferCompletionOutcome.SUCCESS else TransferCompletionOutcome.FAILURE,
        direction,
    )

    @SuppressLint("MissingPermission")
    fun completion(
        context: Context,
        taskId: String,
        outcome: TransferCompletionOutcome,
        direction: TransferDirection = TransferDirection.DOWNLOAD,
    ) {
        ensureChannel(context)
        if (!canPostNotifications(context)) return
        val title = completionNotificationTitle(
            direction = direction,
            outcome = outcome,
            isPhotoBackup = isPhotoBackup(context, taskId, direction),
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(
                if (outcome == TransferCompletionOutcome.SUCCESS) android.R.drawable.stat_sys_download_done
                else android.R.drawable.stat_notify_error,
            )
            .setContentTitle(context.getString(title))
            .setContentText(context.getString(R.string.notification_open_transfers))
            .setContentIntent(openAppIntent(context, taskId, direction.recordKind()))
            .setAutoCancel(true)
            .build()
        runCatching {
            NotificationManagerCompat.from(context).notify(notificationId(taskId), notification)
        }
    }

    private fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.notification_channel_transfers),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = context.getString(R.string.notification_channel_transfers_description)
            },
        )
    }

    internal fun openAppIntent(context: Context, taskId: String, kind: WorkspaceRecordKind): PendingIntent {
        val token = SecureProfileStore(context).issueLocalTransferTarget(kind, taskId)

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (token != null) {
                action = Intent.ACTION_VIEW
                data = Uri.parse(opaqueObjectExternalWorkspaceUri(token))
            } else putExtra(EXTRA_OPEN_TRANSFERS, true)
        }
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun canPostNotifications(context: Context): Boolean =
        if (Build.VERSION.SDK_INT < 33) {
            NotificationManagerCompat.from(context).areNotificationsEnabled()
        } else {
            ContextCompat.checkSelfPermission(context, POST_NOTIFICATIONS_PERMISSION) ==
                PackageManager.PERMISSION_GRANTED
        }

    private fun isPhotoBackup(
        context: Context,
        taskId: String,
        direction: TransferDirection,
    ): Boolean = direction == TransferDirection.UPLOAD &&
        TransferStore(context).upload(taskId)?.backupMode == true

    private fun notificationId(taskId: String): Int = taskId.hashCode() and Int.MAX_VALUE
}

internal data class ForegroundNotificationContent(
    val title: Int,
    val status: Int,
)

internal enum class TransferCompletionOutcome { SUCCESS, FAILURE, CANCELLED, NEEDS_REVIEW }

internal fun foregroundNotificationContent(
    direction: TransferDirection,
    state: TransferState,
    isPhotoBackup: Boolean,
): ForegroundNotificationContent = when {
    direction == TransferDirection.DOWNLOAD -> ForegroundNotificationContent(
        title = R.string.notification_download_title,
        status = if (state == TransferState.WAITING) {
            R.string.transfer_waiting_to_download
        } else {
            R.string.transfer_downloading
        },
    )
    isPhotoBackup -> ForegroundNotificationContent(
        title = R.string.notification_backup_title,
        status = if (state == TransferState.WAITING) {
            R.string.transfer_waiting_to_backup
        } else {
            R.string.transfer_backing_up
        },
    )
    else -> ForegroundNotificationContent(
        title = R.string.notification_upload_title,
        status = if (state == TransferState.WAITING) {
            R.string.transfer_waiting
        } else {
            R.string.transfer_uploading
        },
    )
}

internal fun completionNotificationTitle(
    direction: TransferDirection,
    succeeded: Boolean,
    isPhotoBackup: Boolean,
): Int = completionNotificationTitle(
    direction,
    if (succeeded) TransferCompletionOutcome.SUCCESS else TransferCompletionOutcome.FAILURE,
    isPhotoBackup,
)

internal fun completionNotificationTitle(
    direction: TransferDirection,
    outcome: TransferCompletionOutcome,
    isPhotoBackup: Boolean,
): Int = when {
    outcome == TransferCompletionOutcome.CANCELLED && isPhotoBackup ->
        R.string.notification_backup_cancelled
    outcome == TransferCompletionOutcome.CANCELLED -> R.string.notification_upload_cancelled
    outcome == TransferCompletionOutcome.NEEDS_REVIEW && isPhotoBackup ->
        R.string.notification_backup_needs_review
    outcome == TransferCompletionOutcome.NEEDS_REVIEW ->
        R.string.notification_upload_needs_review
    direction == TransferDirection.DOWNLOAD && outcome == TransferCompletionOutcome.SUCCESS ->
        R.string.notification_download_completed
    direction == TransferDirection.DOWNLOAD -> R.string.notification_download_failed
    isPhotoBackup && outcome == TransferCompletionOutcome.SUCCESS ->
        R.string.notification_backup_completed
    isPhotoBackup -> R.string.notification_backup_failed
    outcome == TransferCompletionOutcome.SUCCESS -> R.string.notification_upload_completed
    else -> R.string.notification_upload_failed
}

internal const val POST_NOTIFICATIONS_PERMISSION = "android.permission.POST_NOTIFICATIONS"
