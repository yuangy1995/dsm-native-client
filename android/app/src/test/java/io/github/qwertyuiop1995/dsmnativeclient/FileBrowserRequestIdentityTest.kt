package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBrowserState
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileSortOption
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileTypeFilter
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileViewMode
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FileBrowserRequestIdentityTest {
    private val initial = FileBrowserState(
        path = "/share",
        searchQuery = "draft",
        activeSearchQuery = "report",
        sortOption = FileSortOption.NAME,
        sortAscending = true,
        typeFilter = FileTypeFilter.ALL,
        viewMode = FileViewMode.LIST,
        selectedPaths = setOf("/share/a.txt"),
    )
    private val identity = initial.fileBrowserRequestIdentity()

    @Test
    fun `清除或切换选择不改变文件请求身份`() {
        assertTrue(initial.clearSelection().matchesFileBrowserRequest(identity))
        assertTrue(initial.toggleSelection("/share/b.txt").matchesFileBrowserRequest(identity))
    }

    @Test
    fun `视图模式和搜索草稿不改变文件请求身份`() {
        assertTrue(initial.changeViewMode(FileViewMode.GRID).matchesFileBrowserRequest(identity))
        assertTrue(initial.editSearchQuery("new draft").matchesFileBrowserRequest(identity))
    }

    @Test
    fun `路径或已提交查询改变文件请求身份`() {
        assertFalse(initial.copy(path = "/other").matchesFileBrowserRequest(identity))
        assertFalse(initial.copy(activeSearchQuery = "photo").matchesFileBrowserRequest(identity))
    }

    @Test
    fun `排序或筛选改变文件请求身份`() {
        assertFalse(initial.copy(sortOption = FileSortOption.SIZE).matchesFileBrowserRequest(identity))
        assertFalse(initial.copy(sortAscending = false).matchesFileBrowserRequest(identity))
        assertFalse(initial.copy(typeFilter = FileTypeFilter.FILES).matchesFileBrowserRequest(identity))
    }

    @Test
    fun `每个高级条件变化都会拒绝旧结果且进入目录会清空查询`() {
        val request = io.github.qwertyuiop1995.dsmnativeclient.domain.FileSearchRequest(listOf("/share"), name = "report")
        val current = initial.copy(searchRequest = request)
        val identity = current.fileBrowserRequestIdentity()
        listOf(request.copy(folders = listOf("/other")), request.copy(searchesContents = true),
            request.copy(minimumBytes = 10), request.copy(owner = "synthetic"), request.copy(recursive = false))
            .forEach { assertFalse(current.copy(searchRequest = it).matchesFileBrowserRequest(identity)) }
        assertTrue(current.editSearchQuery("draft").matchesFileBrowserRequest(identity))
        assertTrue(current.enterDirectory("/share/sub").searchRequest == null)
        assertTrue(current.openShortcut("/other").searchRequest == null)
    }

    @Test
    fun `只有当前代次可以回写同身份文件请求`() {
        val oldRequest = FileBrowserRequestToken(generation = 41, identity = identity)
        val currentRequest = FileBrowserRequestToken(generation = 42, identity = identity)

        assertFalse(initial.matchesFileBrowserRequest(oldRequest, currentGeneration = 42))
        assertTrue(initial.matchesFileBrowserRequest(currentRequest, currentGeneration = 42))
    }

    @Test
    fun `请求代次阻止路径往返后的旧结果回写`() {
        val firstVisit = FileBrowserRequestToken(generation = 10, identity = identity)
        val secondVisit = FileBrowserRequestToken(generation = 12, identity = identity)

        assertFalse(initial.matchesFileBrowserRequest(firstVisit, currentGeneration = 12))
        assertTrue(initial.matchesFileBrowserRequest(secondVisit, currentGeneration = 12))
    }
}
