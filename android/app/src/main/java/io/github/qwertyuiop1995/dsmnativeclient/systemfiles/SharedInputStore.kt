package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.net.URI
import java.util.Locale
import java.util.UUID

@Serializable internal data class SharedFile(val id: String, val name: String, val mime: String?, val bytes: Long) {
    override fun toString() = "SharedFile(bytes=$bytes)"
}
@Serializable internal data class SharedBatch(val id: String, val files: List<SharedFile>, val created: Long = System.currentTimeMillis(), val version: Int = 1) {
    override fun toString() = "SharedBatch(${files.size})"
}

/** 索引加密，内容保存在不参与备份的私有目录；完整复制成功才发布草稿。 */
internal class SharedInputStore(private val preferences: SharedPreferences, private val root: File, private val packageName: String) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_shared_input",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM), File(context.noBackupFilesDir, "shared-input"), context.packageName)
    private val json = Json { encodeDefaults = true }
    fun uri(id: String): String { require(uuid(id)); return "content://$packageName.shared-input/$id" }
    fun id(uri: String): String? = runCatching { URI(uri) }.getOrNull()?.takeIf {
        it.scheme == "content" && it.rawAuthority == "$packageName.shared-input" && it.rawQuery == null && it.rawFragment == null
    }?.rawPath?.removePrefix("/")?.takeIf(::uuid)
    fun file(id: String): File { require(uuid(id)); return File(root, id) }
    fun entry(id: String): SharedFile = synchronized(lock) {
        val raw = preferences.getString("file:$id", null) ?: throw sharedInputFailure()
        runCatching { json.decodeFromString<SharedFile>(raw) }.getOrElse { throw workspaceStorageFailure() }.also {
            if (it.id != id || !valid(it)) throw workspaceStorageFailure()
        }
    }
    fun batches(): List<SharedBatch> = synchronized(lock) {
        preferences.all.keys.filter { it.startsWith("batch:") }.map { key ->
            val raw = preferences.getString(key, null) ?: throw workspaceStorageFailure()
            val row = runCatching { json.decodeFromString<SharedBatch>(raw) }.getOrElse { throw workspaceStorageFailure() }
            if (row.version != 1 || !uuid(row.id) || key != "batch:${row.id}" || row.files.size !in 1..MAX_SHARED_FILES ||
                row.files.any { !valid(it) } || row.files.map { it.id }.distinct().size != row.files.size ||
                row.files.any { entry(it.id) != it }) throw workspaceStorageFailure()
            row
        }.sortedBy { it.created }
    }
    suspend fun receive(sources: List<SharedSource>): SharedBatch = withContext(Dispatchers.IO) {
        require(sources.size in 1..MAX_SHARED_FILES && sources.all { validSharedName(it.name) })
        require(sources.map { it.name.lowercase(Locale.ROOT) }.distinct().size == sources.size)
        val copied = mutableListOf<SharedFile>()
        val created = mutableListOf<File>()
        var retained = false
        try {
            if (!root.mkdirs() && !root.isDirectory) throw workspaceStorageFailure()
            for (source in sources) {
                val id = UUID.randomUUID().toString()
                val file = file(id); created += file
                synchronized(lock) { copying.add(id) }
                var count = 0L
                source.open().use { input -> file.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val read = input.read(buffer)
                        if (read < 0) break
                        count += read
                        if (source.expectedBytes != null && count > source.expectedBytes) throw sharedInputFailure()
                        output.write(buffer, 0, read)
                    }
                    output.fd.sync()
                } }
                if (source.expectedBytes != null && count != source.expectedBytes) throw sharedInputFailure()
                copied += SharedFile(id, source.name, source.mime, count)
            }
            val batch = SharedBatch(UUID.randomUUID().toString(), copied)
            synchronized(lock) {
                val edit = preferences.edit().putString("batch:${batch.id}", json.encodeToString(batch))
                copied.forEach { edit.putString("file:${it.id}", json.encodeToString(it)) }
                if (!edit.commit()) throw workspaceStorageFailure()
            }
            retained = true; batch
        } finally {
            synchronized(lock) {
                if (!retained) created.forEach { it.delete() }
                created.forEach { copying.remove(it.name) }
            }
        }
    }
    /** 与传输原子提交标记配合：只有完整任务批次已保存后才删除草稿。 */
    fun handedOff(batch: SharedBatch) = synchronized(lock) {
        if (batches().none { it == batch }) throw workspaceStorageFailure()
        if (!preferences.edit().remove("batch:${batch.id}").commit()) throw workspaceStorageFailure()
    }
    fun discard(batch: SharedBatch) = synchronized(lock) {
        if (batches().none { it == batch }) throw workspaceStorageFailure()
        val edit = preferences.edit().remove("batch:${batch.id}")
        batch.files.forEach { edit.remove("file:${it.id}") }
        if (!edit.commit()) throw workspaceStorageFailure()
        batch.files.forEach { file(it.id).delete() }
    }
    fun release(uri: String, referenced: (String) -> Boolean) = synchronized(lock) {
        val id = id(uri) ?: return@synchronized
        if (referenced(uri) || batches().any { row -> row.files.any { it.id == id } }) return@synchronized
        if (!preferences.edit().remove("file:$id").commit()) throw workspaceStorageFailure()
        file(id).delete()
    }
    /** 崩溃留下的未发布副本可以清理，草稿和任意传输记录仍引用的文件必须保留。 */
    fun reconcile(transfers: TransferStore) = synchronized(lock) {
        batches().filter { transfers.sharedUploadBatchExists(it.id) }.forEach { batch ->
            batch.files.forEach { file -> transfers.updateUpload(file.id) {
                if (it.workId == null && it.state == io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState.WAITING)
                    it.copy(state = io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState.FAILED,
                        errorKind = io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind.UPLOAD_FAILED.name) else it
            } }
            handedOff(batch)
        }
        val drafts = batches().flatMap { it.files }.mapTo(mutableSetOf()) { it.id }
        val referenced = transfers.snapshot().uploads.mapNotNullTo(mutableSetOf()) { id(it.sourceUri) }
        root.listFiles()?.filter { uuid(it.name) && it.name !in drafts && it.name !in referenced && it.name !in copying }?.forEach {
            if (!preferences.edit().remove("file:${it.name}").commit()) throw workspaceStorageFailure()
            it.delete()
        }
    }
    private fun valid(file: SharedFile) = uuid(file.id) && validSharedName(file.name) && file.bytes >= 0
    private fun uuid(id: String) = runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)
    private companion object { val lock = Any(); val copying = mutableSetOf<String>() }
}
