package io.github.qwertyuiop1995.dsmnativeclient.chat

import android.annotation.SuppressLint
import android.app.*
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.*
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.OpaqueWorkspaceTarget
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal interface ChatNoticeDriving {
    fun allowed(): Boolean
    fun route(scope: ChatNoticeScope, conversation: String): String?
    fun incoming(scope: ChatNoticeScope, route: String)
    fun reconcile(scope: ChatNoticeScope, reminders: List<ChatLocalReminder>)
    fun remove(scope: ChatNoticeScope)
}

/** 系统可见字段只使用随机标识及本地化通用提示，不提供回复或已读写动作。 */
internal class ChatNoticeDriver(private val context: Context, private val store: ChatNoticeStore,
    private val profiles: SecureProfileStore) : ChatNoticeDriving {
    private val manager get() = context.getSystemService(NotificationManager::class.java)
    override fun allowed(): Boolean {
        ensureChannel()
        return NotificationManagerCompat.from(context).areNotificationsEnabled() &&
            manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE &&
            (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, POST_NOTIFICATIONS_PERMISSION) == android.content.pm.PackageManager.PERMISSION_GRANTED)
    }
    private fun ensureChannel() { manager.createNotificationChannel(NotificationChannel(CHANNEL,
        context.getString(R.string.chat_notices_title), NotificationManager.IMPORTANCE_DEFAULT)) }
    override fun route(scope: ChatNoticeScope, conversation: String) = profiles.issueOpaqueWorkspaceTarget(scope.owner.profileId,
        OpaqueWorkspaceTarget.ChatConversation(conversation), scope.owner)
    override fun incoming(scope: ChatNoticeScope, route: String) { post(scope, route, "message:$route", false) }
    @SuppressLint("MissingPermission")
    private fun post(scope: ChatNoticeScope, route: String, id: String, reminder: Boolean) = synchronized(ChatNoticeStore.lock) {
        if (!valid(scope) || !allowed()) return@synchronized
        val uri = opaqueObjectExternalWorkspaceUri(route) ?: return@synchronized
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW; data = Uri.parse(uri)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val notification = NotificationCompat.Builder(context, CHANNEL).setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(context.getString(if (reminder) R.string.chat_notice_reminder_title else R.string.chat_notice_message_title))
            .setContentText(context.getString(R.string.chat_notice_open)).setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setContentIntent(PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            .setAutoCancel(true).setOnlyAlertOnce(true).build()
        NotificationManagerCompat.from(context).notify(tag(scope) + id, 0, notification)
    }
    fun deliver(row: ChatLocalReminder, now: Long): Boolean = synchronized(ChatNoticeStore.lock) {
        val scope = store.scope(row.scopeId) ?: return@synchronized false
        if (!valid(scope) || !allowed() || !store.claim(row, now)) return@synchronized false
        post(scope, row.route, row.id, true); true
    }
    private fun valid(scope: ChatNoticeScope) = store.enabled() && store.scope(scope.id) == scope &&
        runCatching { profiles.requireCurrentOwner(scope.owner) }.isSuccess
    override fun reconcile(scope: ChatNoticeScope, reminders: List<ChatLocalReminder>) {
        if (!valid(scope)) return
        val work = WorkManager.getInstance(context)
        val keep = reminders.filterNot { it.delivered }.sortedBy { it.reminder.remindAtEpochMillis }.take(50)
        // 已移除或改期的随机编号使旧 Worker 无法领取；取消只处理本模块工作。
        val active = work.getWorkInfosByTag(tag(scope)).get().filterNot { it.state.isFinished }
        val expected = keep.map { it.id }.toSet()
        active.filter { info -> info.tags.none { it.startsWith(RECORD_TAG) && it.removePrefix(RECORD_TAG) in expected } }
            .forEach { work.cancelWorkById(it.id) }
        keep.forEach { row ->
            val request = OneTimeWorkRequestBuilder<ChatReminderWorker>().setInputData(workDataOf(KEY to row.id))
                .setInitialDelay((row.reminder.remindAtEpochMillis - System.currentTimeMillis()).coerceAtLeast(0), TimeUnit.MILLISECONDS)
                .addTag(tag(scope)).addTag(RECORD_TAG + row.id).build()
            work.enqueueUniqueWork("chat-reminder:${row.id}", ExistingWorkPolicy.KEEP, request).result.get()
        }
    }
    override fun remove(scope: ChatNoticeScope) {
        WorkManager.getInstance(context).cancelAllWorkByTag(tag(scope))
        manager.activeNotifications.filter { it.tag?.startsWith(tag(scope)) == true }.forEach { manager.cancel(it.tag, it.id) }
    }
    companion object {
        const val CHANNEL = "chat_local_notices"
        const val KEY = "notice"
        private const val RECORD_TAG = "chat-record:"
        fun tag(scope: ChatNoticeScope) = "chat:${scope.id}:"
    }
}

class ChatReminderWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val id = inputData.getString(ChatNoticeDriver.KEY) ?: return@withContext Result.failure()
        try {
            val store = ChatNoticeStore(applicationContext)
            val row = store.reminder(id) ?: return@withContext Result.success()
            ChatNoticeDriver(applicationContext, store, SecureProfileStore(applicationContext)).deliver(row, System.currentTimeMillis())
            Result.success()
        } catch (_: Exception) { Result.failure() }
    }
}
