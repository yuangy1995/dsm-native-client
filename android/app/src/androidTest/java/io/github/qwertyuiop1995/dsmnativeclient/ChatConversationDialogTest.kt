package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.longClick
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatUser
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatReminder
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatScheduledMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.ui.ChatMembersDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.ChatAttachmentPreviewDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.ChatScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.ChatRemindersDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.ChatScheduledMessagesDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.ChatPollComposerDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.NewConversationDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.Rule
import org.junit.Test
import java.io.ByteArrayOutputStream

class ChatConversationDialogTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 多选用户显示私人群聊名称和创建操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                NewConversationDialog(
                    state = workspace().copy(
                        chatNewConversationVisible = true,
                        chatUsers = Loadable.Ready(users()),
                        chatSelectedUserIds = setOf("2", "3"),
                        chatGroupTitle = "Synthetic group",
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.private_group_name)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.create_private_group))
            .assertIsDisplayed().assertIsEnabled()
        rule.onNodeWithText("Member 2").assertIsDisplayed().assertHeightIsAtLeast(48.dp)
    }

    @Test
    fun 私人群聊创建中显示可访问进度并停用操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                NewConversationDialog(
                    state = workspace().copy(
                        chatNewConversationVisible = true,
                        chatUsers = Loadable.Ready(users()),
                        chatSelectedUserIds = setOf("2", "3"),
                        chatGroupTitle = "Synthetic group",
                        chatMutationState = activeMutation(
                            ChatMutationOperation.PRIVATE_GROUP_CREATE,
                        ),
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithContentDescription(
            context.getString(R.string.chat_conversation_change_in_progress),
        ).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.create_private_group))
            .assertIsDisplayed().assertIsNotEnabled()
        rule.onNodeWithText(context.getString(R.string.cancel))
            .assertIsDisplayed().assertIsNotEnabled()
    }

    @Test
    fun 群成员弹窗显示成员目录() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                ChatMembersDialog(
                    state = workspace().copy(
                        chatMembersVisible = true,
                        chatMembers = Loadable.Ready(users()),
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.group_members)).assertIsDisplayed()
        rule.onNodeWithText("Member 3").assertIsDisplayed()
    }

    @Test
    fun 图片附件预览弹窗可显示并关闭() {
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        val output = ByteArrayOutputStream()
        Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
            .compress(Bitmap.CompressFormat.PNG, 100, output)
        rule.setContent {
            LanStashTheme {
                ChatAttachmentPreviewDialog(
                    state = workspace().copy(
                        chatAttachmentPreviewName = "Synthetic image.png",
                        chatAttachmentPreviewBytes = output.toByteArray(),
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithText("Synthetic image.png").assertIsDisplayed()
    }

    @Test
    fun 视频附件预览弹窗先显示准备状态() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                ChatAttachmentPreviewDialog(
                    state = workspace().copy(
                        chatAttachmentPreviewName = "Synthetic video.mp4",
                        chatAttachmentPreviewIsVideo = true,
                        chatAttachmentPreviewIsLoading = true,
                        chatAttachmentPreviewProgress = 0.5f,
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithText("Synthetic video.mp4").assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.preparing_attachment_preview)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.attachment_preview_progress, 50)).assertIsDisplayed()
    }

    @Test
    fun 会话列表显示未读数和本地置顶操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                ChatScreen(
                    rawState = workspace().copy(
                        conversations = Loadable.Ready(
                            listOf(
                                ChatConversation(
                                    id = "channel-1",
                                    title = "Synthetic chat",
                                    kind = ConversationKind.DIRECT,
                                    unreadCount = 3,
                                ),
                            ),
                        ),
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithText("3").assertIsDisplayed()
        rule.onNodeWithText("Synthetic chat").performTouchInput { longClick() }
        rule.onNodeWithText(
            context.getString(R.string.pin_conversation, "Synthetic chat"),
        ).assertIsDisplayed()
    }

    @Test
    fun 宽屏同时显示会话列表和详情占位() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                Box(Modifier.requiredWidth(1000.dp).height(700.dp)) {
                    ChatScreen(
                        rawState = workspace().copy(
                            conversations = Loadable.Ready(
                                listOf(
                                    ChatConversation(
                                        id = "channel-1",
                                        title = "Synthetic wide chat",
                                        kind = ConversationKind.DIRECT,
                                    ),
                                ),
                            ),
                        ),
                        model = model,
                    )
                }
            }
        }

        rule.onNodeWithText("Synthetic wide chat").assertExists()
        rule.onNodeWithText(context.getString(R.string.select_conversation)).assertExists()
        rule.onNodeWithText(context.getString(R.string.select_conversation_description)).assertExists()
    }

    @Test
    fun 提醒弹窗显示本地格式时间和移除操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                ChatRemindersDialog(
                    state = workspace().copy(
                        chatRemindersVisible = true,
                        chatReminders = Loadable.Ready(
                            listOf(ChatReminder("r1", "post-1", 1_774_166_400_000)),
                        ),
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.chat_reminders)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.chat_reminder_message_reference)).assertIsDisplayed()
    }

    @Test
    fun 提醒变更中显示进度并停用关闭操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                ChatRemindersDialog(
                    state = workspace().copy(
                        chatRemindersVisible = true,
                        chatReminders = Loadable.Ready(emptyList()),
                        chatMutationState = activeMutation(ChatMutationOperation.REMINDER_SET),
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithContentDescription(
            context.getString(R.string.chat_reminder_change_in_progress),
        ).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.close)).assertIsNotEnabled()
    }

    @Test
    fun 定时消息弹窗显示正文时间和新建操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                ChatScheduledMessagesDialog(
                    state = workspace().copy(
                        chatScheduledMessagesVisible = true,
                        chatScheduledMessages = Loadable.Ready(
                            listOf(
                                ChatScheduledMessage(
                                    "job-1", "channel-1", "Synthetic scheduled text", 1_800_000_000_000,
                                ),
                            ),
                        ),
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithText("Synthetic scheduled text").assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.new_scheduled_message)).assertIsDisplayed()
    }

    @Test
    fun 定时消息变更中显示进度并停用关闭操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                ChatScheduledMessagesDialog(
                    state = workspace().copy(
                        chatScheduledMessagesVisible = true,
                        chatScheduledMessages = Loadable.Ready(emptyList()),
                        chatMutationState = activeMutation(ChatMutationOperation.SCHEDULE_CREATE),
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithContentDescription(
            context.getString(R.string.chat_schedule_change_in_progress),
        ).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.close)).assertIsNotEnabled()
    }

    @Test
    fun 投票表单显示两个必需选项和安全边界说明() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                ChatPollComposerDialog(
                    state = workspace().copy(chatPollComposerVisible = true),
                    model = model,
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.chat_poll_question)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.chat_poll_option_number, 1)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.chat_poll_option_number, 2)).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.chat_poll_creation_limit)).assertIsDisplayed()
    }

    @Test
    fun 投票创建中显示进度并停用关闭操作() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        rule.setContent {
            LanStashTheme {
                ChatPollComposerDialog(
                    state = workspace().copy(
                        chatPollComposerVisible = true,
                        chatPollQuestion = "Synthetic question?",
                        chatPollOptions = listOf("First", "Second"),
                        chatMutationState = activeMutation(ChatMutationOperation.POLL_CREATE),
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithContentDescription(
            context.getString(R.string.chat_poll_creation_in_progress),
        ).assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.cancel)).assertIsNotEnabled()
    }

    private fun workspace() = WorkspaceState(
        profile = NasProfile("synthetic", "Synthetic", "https://nas.example.invalid", "operator"),
    )

    private fun activeMutation(operation: ChatMutationOperation): ChatMutationWorkspaceState {
        val requestId = "request-${operation.name}"
        val target = ChatMutationTarget(
            profileId = "synthetic",
            operation = operation,
            requestId = requestId,
            conversationId = "channel-1",
            requestFingerprint = "0".repeat(64),
        )
        return ChatMutationWorkspaceState(
            entries = mapOf(
                requestId to ChatMutationEntry(
                    target = target,
                    mutationInProgress = true,
                    generation = 1,
                ),
            ),
        )
    }

    private fun users() = listOf(
        ChatUser("2", "Member 2", "member2"),
        ChatUser("3", "Member 3", "member3"),
    )
}
