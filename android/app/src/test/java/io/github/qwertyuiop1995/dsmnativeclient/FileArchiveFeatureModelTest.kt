package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class FileArchiveFeatureModelTest {
    private val profile = NasProfile("archive-model", "NAS", "https://synthetic.example.invalid", "synthetic")
    private val source = FileItem("/share/archive.zip", "archive.zip", false, size = 10, canRead = true)
    private val destination = FileItem("/share", "share", true, canRead = true, canWrite = true)
    private val folder = ArchiveItem(7, "Folder", "Folder", true)
    private val child = ArchiveItem(3, "a.txt", "Folder/a.txt", false, 12)
    private var workspace = WorkspaceState(profile, selectedModule = Module.FILES, fileBrowser = FileBrowserState(path = destination.path), fileDirectoryBaselines = mapOf(destination.path to destination))
    private val requests = mutableListOf<Map<String, String>>()
    private var response: (Map<String, String>) -> JsonObject = { fields ->
        page(if (fields["item_id"] == "-1") listOf(folder) else listOf(child))
    }
    private val repo = authorizedRepository(profile, DsmSession(profile.id, "synthetic-session"), DsmApiClient(OkHttpClient.Builder().addInterceptor { chain ->
        val request = chain.request(); val form = request.body as FormBody
        val fields = (0 until form.size).associate { form.name(it) to form.value(it) }
        synchronized(requests) { requests += fields }
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
            .body(buildJsonObject { put("success", true); put("data", response(fields)) }.toString().toResponseBody("application/json".toMediaType())).build()
    }.build()), listOf(ApiCapability("SYNO.FileStation.Extract", "entry.cgi", 2, 2)).associateBy(ApiCapability::name))
    private var active: DsmRepository? = repo
    private val extractions = mutableListOf<FileExtractionRequest>()
    private val compressions = mutableListOf<FileCompressionRequest>()
    private fun feature(scope: CoroutineScope) = FileArchiveFeatureModel(scope, { active }, { workspace }, { "Archive" }, { extractions += it; true }, { compressions += it; true })
    private suspend fun waitLoaded(feature: FileArchiveFeatureModel) = withTimeout(5_000) { while (feature.state.value.page !is Loadable.Ready) delay(10) }

    @Test fun `所选文件夹与子项跨目录保留且空选择不提交`() = runBlocking {
        val feature = feature(this); assertTrue(feature.open(source)); waitLoaded(feature)
        feature.setExtractAll(false); feature.submit(); assertTrue(extractions.isEmpty())
        feature.enter(folder); waitLoaded(feature); feature.toggle(child); feature.up(); waitLoaded(feature)
        assertEquals(setOf(3), feature.state.value.selected.keys)
        feature.submit()
        assertEquals(FileArchiveSelection.Items(listOf(child)), extractions.single().options.selection)
        assertEquals(source, extractions.single().source)
        assertNull(feature.state.value.editor)
    }

    @Test fun `密码和编码修改使旧清单失效并在重新读取后使用当前选项`() = runBlocking {
        val feature = feature(this); feature.open(source); waitLoaded(feature)
        feature.toggle(folder)
        feature.editOptions { it.copy(password = "synthetic-password", codepage = "chs") }
        assertFalse(feature.canSubmit()); assertTrue(feature.state.value.selected.isEmpty())
        feature.submit(); assertTrue(extractions.isEmpty())
        feature.reload(); waitLoaded(feature); feature.setExtractAll(true); feature.submit()
        val request = extractions.single()
        assertEquals("chs", request.options.codepage); assertEquals("synthetic-password", request.options.password)
        assertFalse(request.toString().contains("synthetic-password"))
        assertNull(feature.state.value.options.password)
    }

    @Test fun `覆盖需要明确确认且修改选项清除旧确认`() = runBlocking {
        val feature = feature(this); feature.open(source); waitLoaded(feature)
        feature.editOptions { it.copy(overwrite = true) }; feature.submit()
        assertTrue(feature.state.value.confirmation); assertTrue(extractions.isEmpty())
        feature.editOptions { it.copy(keepDirectories = false) }; assertFalse(feature.state.value.confirmation)
        feature.submit(); feature.submit(acceptOverwrite = true)
        assertTrue(extractions.single().options.overwrite); assertFalse(extractions.single().options.keepDirectories)
    }

    @Test fun `换账号或离开文件模块后旧草稿不能提交`() = runBlocking {
        val feature = feature(this); feature.open(source); waitLoaded(feature)
        active = null; feature.submit(); assertTrue(extractions.isEmpty()); assertNull(feature.state.value.editor)
        active = repo; feature.open(source); waitLoaded(feature)
        workspace = workspace.copy(selectedModule = Module.SETTINGS); feature.submit()
        assertTrue(extractions.isEmpty()); assertNull(feature.state.value.editor)
    }

    @Test fun `自动中文名称修正只采用更清楚的返回且后续请求沿用`() = runBlocking {
        response = { fields -> page(listOf(folder.copy(name = if (fields["codepage"] == "chs") "资料" else "Ã¤", path = if (fields["codepage"] == "chs") "资料" else "Ã¤"))) }
        val feature = feature(this); feature.open(source); waitLoaded(feature); feature.submit()
        assertEquals("chs", extractions.single().options.codepage)
        assertEquals(listOf(null, "chs"), requests.map { it["codepage"] })
    }

    @Test fun `分页合并重复编号显示错误且不把部分结果当作完整提交`() = runBlocking {
        response = { page(listOf(folder), total = 2) }
        val feature = feature(this); feature.open(source); waitLoaded(feature); feature.more()
        withTimeout(5_000) { while (feature.state.value.loadingMore) delay(10) }
        assertEquals(DsmErrorKind.ARCHIVE_CONTENT_UNAVAILABLE, feature.state.value.moreFailure?.kind)
        assertFalse(feature.canSubmit()); feature.close()
    }

    @Test fun `压缩保留名称中的点并传递所选级别与密码`() = runBlocking {
        val feature = feature(this); assertTrue(feature.openCompression(listOf(source)))
        feature.editCompression(name = "report.v1", format = ArchiveFormat.SEVEN_ZIP, level = ArchiveCompressionLevel.BEST)
        feature.editOptions { it.copy(password = "synthetic-password") }; feature.submit()
        val request = compressions.single()
        assertEquals("report.v1.7z", request.filename); assertEquals(ArchiveCompressionLevel.BEST, request.level)
        assertEquals("synthetic-password", request.password); assertTrue(requests.isEmpty())
        assertFalse(request.copy(name = "../other").isValid)
        assertEquals("report.ZIP", request.copy(name = "report.ZIP", format = ArchiveFormat.ZIP).filename)
    }

    @Test fun `相同归档任务目标相交时阻止重放而其他目录仍可继续`() {
        val first = FileServerMutationTarget(profile.id, Module.FILES, FileServerMutationOperation.EXTRACT, listOf(source), destination)
        assertTrue(first.overlapsArchiveTarget(first.copy(destinationFolderBaseline = destination.copy(path = "/share/sub"))))
        assertFalse(first.overlapsArchiveTarget(first.copy(profileId = "other")))
        assertFalse(first.overlapsArchiveTarget(first.copy(sourceBaselines = listOf(source.copy(path = "/other/a.zip")), destinationFolderBaseline = destination.copy(path = "/other"))))
        assertFalse(first.overlapsArchiveTarget(first.copy(sourceBaselines = listOf(source.copy(path = "/shared/a.zip")), destinationFolderBaseline = destination.copy(path = "/shared"))))
    }

    private fun page(items: List<ArchiveItem>, total: Int = items.size) = buildJsonObject {
        put("total", total); putJsonArray("items") { items.forEach { item -> add(buildJsonObject {
            put("itemid", item.id); put("name", item.name); put("path", item.path); put("is_dir", item.isDirectory); item.size?.let { put("size", it) }
        }) } }
    }
}
