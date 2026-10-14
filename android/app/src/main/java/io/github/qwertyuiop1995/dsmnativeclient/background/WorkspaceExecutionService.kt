package io.github.qwertyuiop1995.dsmnativeclient.background

import android.annotation.SuppressLint
import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import io.github.qwertyuiop1995.dsmnativeclient.MainActivity
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.opaqueObjectExternalWorkspaceUri
import kotlinx.coroutines.*

/** 显式操作的执行时间租约；不接收文件、凭据或请求参数，系统结束后不重建网络操作。 */
class WorkspaceExecutionService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val registry = WorkspaceExecutionRegistry.shared
    private val attached = mutableSetOf<String>()
    private var observer: Job? = null
    private var foregroundId: Int? = null
    private var lastStart = 0
    private val manager get() = getSystemService(NotificationManager::class.java)
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStart = startId
        val id = intent?.getStringExtra(KEY)
        if (intent?.action == CANCEL) {
            id?.let(registry::cancel)
            if (attached.isEmpty()) stopSelfResult(startId)
            return START_NOT_STICKY
        }
        val entry = registry.entries.value.firstOrNull { it.id == id }
        try {
            ensureChannel()
            // 已取消或进程重建后的空请求也先履行系统前台启动约定，再结束服务。
            ServiceCompat.startForeground(this, entry?.let(::number) ?: EMPTY_ID, notification(entry), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            foregroundId = entry?.let(::number) ?: EMPTY_ID
            if (entry == null) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelfResult(startId); return START_NOT_STICKY }
            attached += entry.id
            registry.started(entry.id)
            if (observer == null) observer = scope.launch { registry.entries.collect { refresh(it) } }
            else refresh(registry.entries.value)
        } catch (_: Exception) {
            entry?.let { registry.failed(it.id, unavailableExecution()) }
            if (attached.isEmpty()) stopSelfResult(startId)
        }
        return START_NOT_STICKY
    }
    @SuppressLint("MissingPermission")
    private fun refresh(entries: List<WorkspaceExecutionEntry>) {
        val current = entries.filter { it.id in attached }
        val removed = attached - current.map { it.id }.toSet()
        attached.removeAll(removed)
        if (current.isEmpty()) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            removed.forEach { manager.cancel(number(it)) }
            foregroundId = null; stopSelfResult(lastStart); return
        }
        val primary = current.first()
        try {
            if (foregroundId != number(primary)) {
                ServiceCompat.startForeground(this, number(primary), notification(primary), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
                foregroundId = number(primary)
            }
            // 当前前台通知不能先当普通通知删除；先切换前台归属，再移除已结束任务。
            removed.forEach { manager.cancel(number(it)) }
            current.forEach { row -> runCatching { manager.notify(number(row), notification(row)) } }
        } catch (_: Exception) { current.forEach { registry.cancel(it.id) }; stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
    }
    private fun ensureChannel() { manager.createNotificationChannel(NotificationChannel(CHANNEL,
        getString(R.string.execution_channel), NotificationManager.IMPORTANCE_LOW)) }
    private fun notification(entry: WorkspaceExecutionEntry?): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(getString(entry?.activity?.title ?: R.string.execution_channel))
            .setContentText(getString(R.string.execution_running)).setOnlyAlertOnce(true).setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
        if (entry != null) {
            val progress = if (entry.total > 0) (entry.completed.toDouble() / entry.total * 1_000).toInt().coerceIn(0, 1_000) else 0
            builder.setProgress(1_000, progress, entry.total <= 0)
            val open = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW; data = Uri.parse(opaqueObjectExternalWorkspaceUri(entry.route))
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            builder.setContentIntent(PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            val cancel = Intent(this, WorkspaceExecutionService::class.java).apply {
                action = CANCEL; data = Uri.parse("lanstash-execution:${entry.id}"); putExtra(KEY, entry.id)
            }
            builder.addAction(0, getString(R.string.cancel), PendingIntent.getService(this, 0, cancel, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        }
        return builder.build()
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        attached.toList().forEach(registry::cancel)
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }
    override fun onDestroy() {
        observer?.cancel(); scope.cancel()
        stopForeground(STOP_FOREGROUND_REMOVE)
        attached.forEach { registry.cancel(it); manager.cancel(number(it)) }; attached.clear()
        super.onDestroy()
    }
    private fun number(entry: WorkspaceExecutionEntry) = number(entry.id)
    private fun number(id: String) = 0x40000000 or (id.hashCode() and 0x0fffffff)
    companion object {
        const val KEY = "execution"
        const val CANCEL = "io.github.qwertyuiop1995.dsmnativeclient.CANCEL_EXECUTION"
        const val CHANNEL = "workspace_execution"
        private const val EMPTY_ID = 0x3fffffff
    }
}
