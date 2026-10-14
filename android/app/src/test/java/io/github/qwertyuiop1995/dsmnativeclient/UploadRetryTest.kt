package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import java.io.ByteArrayInputStream
import java.io.IOException
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class UploadRetryTest {
    private val profile = NasProfile("upload-profile", "NAS", "https://nas.example.invalid", "synthetic")
    private val session = DsmSession(profile.id, "synthetic-session")
    private val store = SecureProfileStore(MemoryPreferences())
    private val transferPreferences = MemoryPreferences()
    private val transfers = TransferStore(transferPreferences)
    private val owner = store.commitConnection(store.connectionAttempt(profile.id), profile, session, "", false)
    private val bytes = "original-content".encodeToByteArray()
    private val source = UploadSource("file.bin", "application/octet-stream", bytes.size.toLong(), { ByteArrayInputStream(bytes) })
    private val original = PersistedUpload("upload-a", profile.id, "content://synthetic/item", "file.bin",
        expectedBytes = bytes.size.toLong(), destinationPath = "/synthetic", state = TransferState.FAILED,
        workId = "execution-a", backupMode = false, overwrite = true, requiresRefresh = true)
    private var remote: ByteArray? = bytes
    private var failDownload = false
    private var beforeDownload: () -> Unit = {}
    private val methods = mutableListOf<String>()
    private val repo = authorizedRepository(profile, session,
        DsmApiClient(OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            val method = request.url.queryParameter("method") ?: (request.body as FormBody).let { form ->
                (0 until form.size).first { form.name(it) == "method" }.let(form::value)
            }
            methods += method
            val binary = method == "download"
            val body = if (binary) {
                beforeDownload()
                if (failDownload) throw IOException("Synthetic network failure")
                requireNotNull(remote).toResponseBody("application/octet-stream".toMediaType())
            } else {
                check(method == "list" || method == "getinfo") { "恢复不得上传：$method" }
                val items = remote?.let { """{"path":"/synthetic/file.bin","name":"file.bin","isdir":false,"size":${it.size},"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}""" }.orEmpty()
                """{"success":true,"data":{"files":[$items],"total":${if (remote == null) 0 else 1}}}""".toResponseBody("application/json".toMediaType())
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body).build()
        }.build()), listOf("SYNO.FileStation.List", "SYNO.FileStation.Download")
            .associateWith { ApiCapability(it, "entry.cgi", 1, 2) })
        .also { it.bindOwner(owner) { store.requireCurrentOwner(owner) } }

    private suspend fun seed(upload: PersistedUpload = original, proof: Boolean = true) {
        store.bindRecord(WorkspaceRecordKind.UPLOAD, upload.id, owner)
        transfers.upsert(upload)
        if (proof) transfers.saveUploadContent(upload, requireNotNull(upload.workId), source.contentFingerprint())
    }

    private suspend fun retry(upload: PersistedUpload = original, input: UploadSource = source) =
        retryStoredUpload(repo, upload, TransferStore(transferPreferences), store, input)

    @Test fun `重新打开存储后用原正文摘要恢复成功且不读取后来变化的来源`() = runBlocking {
        seed()
        val (decision, result) = retry(input = source.copy(openInputStream = { error("恢复只核对原始摘要") }))
        assertEquals(RetryUploadDecision.ALREADY_COMPLETE, decision)
        assertEquals(TransferState.SUCCEEDED, result.state)
        assertFalse(result.requiresRefresh)
        assertEquals(result, transfers.upload(original.id))
        assertEquals(listOf("list", "getinfo", "download"), methods)
    }

    @Test fun `同大小不同内容即使原先允许覆盖仍不重排且保留未定事实`() = runBlocking {
        seed(); remote = "different-values".encodeToByteArray()
        assertEquals(bytes.size, remote!!.size)
        assertEquals(RetryUploadDecision.CONFLICT, retry().first)
        assertEquals(original, transfers.upload(original.id))
        assertEquals(listOf("list", "getinfo", "download"), methods)
    }

    @Test fun `旧无摘要任务同大小不能认领成功`() = runBlocking {
        seed(proof = false)
        assertEquals(RetryUploadDecision.UNRESOLVED, retry().first)
        assertEquals(original, transfers.upload(original.id))
        assertEquals(listOf("list", "getinfo"), methods)
    }

    @Test fun `目标暂时消失也不能重放不确定上传`() = runBlocking {
        seed(); remote = null
        repeat(2) { assertEquals(RetryUploadDecision.UNRESOLVED, retry().first) }
        assertEquals(original, transfers.upload(original.id))
        assertEquals(listOf("list", "list"), methods)
    }

    @Test fun `明确失败且无目标时重排并清除历史覆盖授权`() = runBlocking {
        val failed = original.copy(requiresRefresh = false)
        seed(failed); remote = null
        val (decision, next) = retry(failed)
        assertEquals(RetryUploadDecision.REQUEUE, decision)
        assertEquals(TransferState.WAITING, next.state)
        assertFalse(next.overwrite); assertNull(next.workId)
        assertNull(transfers.uploadContent(next))
        assertEquals(listOf("list"), methods)
    }

    @Test fun `未保存会话可以只读恢复但不能虚报后台已重排`() = runBlocking {
        val failed = original.copy(requiresRefresh = false)
        seed(failed); remote = null
        store.commitConnection(store.connectionAttempt(profile.id), profile, session, null, false, persistSession = false)
        assertEquals(owner, store.currentOwner(profile.id))
        assertEquals(RetryUploadDecision.SAVED_SESSION_REQUIRED, retry(failed).first)
        assertEquals(failed, transfers.upload(original.id))
    }

    @Test fun `来源内容变化时明确失败任务也要求重新选择`() = runBlocking {
        val failed = original.copy(requiresRefresh = false)
        seed(failed); remote = null
        val changed = source.copy(openInputStream = { ByteArrayInputStream("different-values".encodeToByteArray()) })
        assertEquals(RetryUploadDecision.SOURCE_CHANGED, retry(failed, changed).first)
        assertEquals(failed, transfers.upload(original.id))
    }

    @Test fun `另一个账号在任何读取前被拒绝`() = runBlocking {
        seed(); store.saveProfile(profile.copy(username = "another"))
        val failure = runCatching { retry() }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.WORKSPACE_CHANGED, failure.kind)
        assertTrue(methods.isEmpty())
        assertEquals(original, transfers.upload(original.id))
    }

    @Test fun `读取期间退出的迟到结果不能确认任务`() = runBlocking {
        seed(); beforeDownload = { store.signOut(owner) }
        val failure = runCatching { retry() }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.WORKSPACE_CHANGED, failure.kind)
        assertEquals(original, transfers.upload(original.id))
    }

    @Test fun `读取期间任务被其他执行器改变不会被旧结果覆盖`() = runBlocking {
        seed()
        val newer = original.copy(workId = "execution-b", state = TransferState.RUNNING)
        beforeDownload = { transfers.upsert(newer) }
        val failure = runCatching { retry() }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.WORKSPACE_CHANGED, failure.kind)
        assertEquals(newer, transfers.upload(original.id))
    }

    @Test fun `内容读取断线保留原事实且没有上传请求`() = runBlocking {
        seed(); failDownload = true
        assertTrue(runCatching { retry() }.isFailure)
        assertEquals(original, transfers.upload(original.id))
        assertEquals(listOf("list", "getinfo", "download"), methods)
    }
}
