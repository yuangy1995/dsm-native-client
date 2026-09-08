package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerOverview
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerRegistryImage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerSection
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogEntry
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogLevel
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.ContainersScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.CONTAINER_REGISTRY_SCROLL_TEST_TAG
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test

class ContainerReadOnlyScreenTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 容器列表和详情仅显示名称状态与只读边界() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        setContainerContent()

        rule.onNodeWithText(context.getString(R.string.container_management_read_only))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.containers)).performClick()
        rule.onNodeWithContentDescription(context.getString(R.string.running)).assertIsDisplayed()
        rule.onNodeWithText("Synthetic container")
            .assertIsDisplayed()
            .assertHasClickAction()
            .performClick()
        rule.onAllNodesWithText(context.getString(R.string.running)).assertCountEquals(2)
        rule.onAllNodesWithText(context.getString(R.string.container_management_read_only))
            .assertCountEquals(2)
        rule.onAllNodesWithText("technical-container-detail").assertCountEquals(0)
        rule.onAllNodesWithText(context.getString(R.string.start)).assertCountEquals(0)
        rule.onAllNodesWithText(context.getString(R.string.stop)).assertCountEquals(0)
        rule.onAllNodesWithText(context.getString(R.string.delete)).assertCountEquals(0)
    }

    @Test
    fun 映像保留只读仓库入口且网络不再提供写操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        setContainerContent(supportsRegistry = true)

        rule.onNodeWithText(context.getString(R.string.images)).performClick()
        rule.onNodeWithText(context.getString(R.string.search_images))
            .assertIsDisplayed()
            .assertHasClickAction()
        rule.onNodeWithText("Synthetic image").assertIsDisplayed()
        rule.onAllNodesWithText(context.getString(R.string.delete)).assertCountEquals(0)

        rule.onNodeWithContentDescription(context.getString(R.string.go_up)).performClick()
        rule.onNodeWithText(context.getString(R.string.networks)).performClick()
        rule.onNodeWithText("Synthetic network").assertIsDisplayed()
        rule.onAllNodesWithText(context.getString(R.string.new_network)).assertCountEquals(0)
        rule.onAllNodesWithText(context.getString(R.string.delete)).assertCountEquals(0)
    }

    @Test
    fun 总览只派生稳定数量且失败分区不冒充零() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        setContainerContent(
            unavailableSections = setOf(ContainerSection.NETWORKS),
        )

        rule.onNodeWithText(context.getString(R.string.overview)).assertIsDisplayed()
        rule.onNodeWithText(
            context.resources.getQuantityString(R.plurals.container_overview_total, 1, 1),
        )
            .assertIsDisplayed()
        val running = context.resources.getQuantityString(
            R.plurals.container_overview_running_count,
            1,
            1,
        )
        val stopped = context.resources.getQuantityString(
            R.plurals.container_overview_stopped_count,
            0,
            0,
        )
        val other = context.resources.getQuantityString(
            R.plurals.container_overview_other_count,
            0,
            0,
        )
        rule.onNodeWithText(
            context.getString(R.string.container_overview_state_counts, running, stopped, other),
        )
            .assertIsDisplayed()
        rule.onNodeWithText(
            context.resources.getQuantityString(
                R.plurals.container_overview_section_count,
                1,
                context.getString(R.string.images),
                1,
            ),
        ).assertIsDisplayed()
        rule.onNodeWithText(
            context.resources.getQuantityString(
                R.plurals.container_overview_section_count,
                1,
                context.getString(R.string.projects),
                1,
            ),
        ).assertIsDisplayed()
        rule.onNodeWithText(
            context.getString(
                R.string.container_overview_section_unavailable,
                context.getString(R.string.networks),
            ),
        ).assertIsDisplayed()
        rule.onAllNodesWithText("technical", substring = true).assertCountEquals(0)
        rule.onAllNodesWithText("container-1", substring = true).assertCountEquals(0)
        rule.onAllNodesWithText("sensitive-event", substring = true).assertCountEquals(0)
        rule.onAllNodesWithText(context.getString(R.string.start)).assertCountEquals(0)
        rule.onAllNodesWithText(context.getString(R.string.stop)).assertCountEquals(0)
        rule.onAllNodesWithText(context.getString(R.string.delete)).assertCountEquals(0)
        rule.onAllNodesWithText(context.getString(R.string.new_network)).assertCountEquals(0)
    }

    @Test
    fun 镜像仓库大量标签可滚动到末项且关闭操作保持可见() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val tags = (1..200).map { index -> "synthetic-long-tag-$index-with-readable-content" }
        setContainerContent(
            supportsRegistry = true,
            registryVisible = true,
            registryTags = tags,
            registryResultCount = 50,
            registryOfficialIndices = setOf(1),
            fontScale = 2f,
        )

        rule.onNodeWithTag(CONTAINER_REGISTRY_SCROLL_TEST_TAG).assert(hasScrollAction())
        rule.onNodeWithText(context.getString(R.string.close))
            .assertIsDisplayed()
            .assertHasClickAction()
        val tagCount = context.resources.getQuantityString(
            R.plurals.container_registry_tag_count,
            tags.size,
            tags.size,
        )
        rule.onNodeWithTag(CONTAINER_REGISTRY_SCROLL_TEST_TAG)
            .performScrollToNode(hasText(tagCount))
        rule.onNodeWithText(tagCount).assertIsDisplayed()
        rule.onNodeWithTag(CONTAINER_REGISTRY_SCROLL_TEST_TAG)
            .performScrollToNode(hasText(tags.last()))
        rule.onNodeWithText(tags.last()).assertIsDisplayed()
        rule.onNodeWithTag(CONTAINER_REGISTRY_SCROLL_TEST_TAG)
            .performScrollToNode(hasText(context.getString(R.string.container_registry_read_only_hint)))
        rule.onNodeWithText(context.getString(R.string.container_registry_read_only_hint))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.close))
            .assertIsDisplayed()
            .assertHasClickAction()
        rule.onNodeWithTag(CONTAINER_REGISTRY_SCROLL_TEST_TAG)
            .performScrollToNode(hasText("synthetic/image-1"))
        rule.onNodeWithText("synthetic/image-1")
            .assertIsDisplayed()
            .assertIsSelected()
        rule.onNode(hasText(context.getString(R.string.container_registry_official)) and hasAnyAncestor(isSelected()), useUnmergedTree = true)
            .assertIsDisplayed()
        rule.onNodeWithTag(CONTAINER_REGISTRY_SCROLL_TEST_TAG)
            .performScrollToNode(hasText(tags.last()))
        rule.onNodeWithText(tags.last()).assertIsDisplayed()
    }

    @Test
    fun 官方镜像仅在明确来源的搜索结果和已选详情中显示资源化标识() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val officialLabel = context.getString(R.string.container_registry_official)
        setContainerContent(
            supportsRegistry = true,
            registryVisible = true,
            registryTags = listOf("latest"),
            registryResultCount = 3,
            registryOfficialIndices = setOf(1),
            registryAutomatedIndices = setOf(2),
            registryTrustedIndices = setOf(3),
        )

        rule.onAllNodesWithText(officialLabel, useUnmergedTree = true).assertCountEquals(2)
        rule.onAllNodesWithContentDescription(officialLabel, useUnmergedTree = true)
            .assertCountEquals(2)
    }

    private fun setContainerContent(
        supportsRegistry: Boolean = false,
        unavailableSections: Set<ContainerSection> = emptySet(),
        registryVisible: Boolean = false,
        registryTags: List<String> = emptyList(),
        registryResultCount: Int = 1,
        registryOfficialIndices: Set<Int> = emptySet(),
        registryAutomatedIndices: Set<Int> = emptySet(),
        registryTrustedIndices: Set<Int> = emptySet(),
        fontScale: Float = 1f,
    ) {
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        val registryImages = (1..registryResultCount).map { index ->
            ContainerRegistryImage(
                name = "synthetic/image-$index",
                registry = "registry.example.invalid",
                description = "Synthetic image $index",
                starCount = 0,
                isOfficial = index in registryOfficialIndices,
                isAutomated = index in registryAutomatedIndices,
                isTrusted = index in registryTrustedIndices,
            )
        }
        val registryImage = registryImages.first()
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(density.density, fontScale),
            ) {
                LanStashTheme {
                    ContainersScreen(
                    state = WorkspaceState(
                        profile = NasProfile(
                            id = "synthetic",
                            name = "Synthetic",
                            address = "https://nas.example.invalid",
                            username = "operator",
                        ),
                        containers = Loadable.Ready(
                            ContainerOverview(
                                containers = listOf(
                                    resource(
                                        id = "container-1",
                                        name = "Synthetic container",
                                        state = ResourceState.RUNNING,
                                        detail = "technical-container-detail",
                                    ),
                                ),
                                images = listOf(
                                    resource("image-1", "Synthetic image", ResourceState.HEALTHY),
                                ),
                                networks = listOf(
                                    resource("network-1", "Synthetic network", ResourceState.UNKNOWN),
                                ),
                                projects = listOf(
                                    resource("project-1", "Synthetic project", ResourceState.HEALTHY),
                                ),
                                events = listOf(
                                    LogEntry(
                                        id = "sensitive-event-id",
                                        level = LogLevel.INFO,
                                        timeEpochSeconds = 1,
                                        user = "sensitive-event-user",
                                        event = "sensitive-event-content",
                                    ),
                                ),
                                unavailableSections = unavailableSections,
                            ),
                        ),
                        supportsContainerRegistry = supportsRegistry,
                        containerRegistryVisible = registryVisible,
                        containerRegistryResults = if (registryVisible) {
                            Loadable.Ready(registryImages)
                        } else {
                            Loadable.Idle
                        },
                        selectedContainerRegistryImage = registryImage.takeIf { registryVisible },
                        containerRegistryTags = if (registryVisible) {
                            Loadable.Ready(registryTags)
                        } else {
                            Loadable.Idle
                        },
                    ),
                        model = model,
                    )
                }
            }
        }
    }

    private fun resource(
        id: String,
        name: String,
        state: ResourceState,
        detail: String = "technical-detail",
    ) = ManagedResource(id = id, name = name, detail = detail, state = state)
}
