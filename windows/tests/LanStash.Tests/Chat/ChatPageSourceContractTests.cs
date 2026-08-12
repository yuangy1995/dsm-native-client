namespace LanStash.Tests;

public sealed class ChatPageSourceContractTests
{
    [Fact]
    public void PageHasDedicatedReadOnlyFiveStateAdaptiveLayout()
    {
        var xaml = Read("windows/src/LanStash.App/Views/ChatPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/ChatPage.xaml.cs");

        Assert.Contains("x:Name=\"LoadingState\"", xaml);
        Assert.Contains("x:Name=\"EmptyState\"", xaml);
        Assert.Contains("x:Name=\"FilteredEmptyState\"", xaml);
        Assert.Contains("x:Name=\"ErrorState\"", xaml);
        Assert.Contains("x:Name=\"ContentState\"", xaml);
        Assert.Contains("x:Name=\"UnavailableState\"", xaml);
        Assert.Contains("x:Name=\"ValidationState\"", xaml);
        Assert.Contains("x:Name=\"ConversationPane\"", xaml);
        Assert.Contains("x:Name=\"MessagePane\"", xaml);
        Assert.Contains("CompactWidth = 720", source);
        Assert.Contains("ConversationPane.Visibility", source);
        Assert.Contains("MessagePane.Visibility", source);
        Assert.Contains("ChatBrowserReadOnly", xaml);
        Assert.Contains("AutomationProperties.Name=\"{x:Bind AutomationName}\"", xaml);
        Assert.Contains("!_viewModel.IsUnavailable && !_viewModel.RequiresValidation", source);
        Assert.Contains("if (_viewModel.IsUnavailable || _viewModel.RequiresValidation)", source);
    }

    [Fact]
    public void PageSupportsKeyboardTouchNarratorAndSystemThemes()
    {
        var xaml = Read("windows/src/LanStash.App/Views/ChatPage.xaml");

        Assert.True(Count(xaml, "MinHeight=\"44\"") >= 7);
        Assert.Contains("Key=\"Left\"", xaml);
        Assert.Contains("Key=\"F\"", xaml);
        Assert.Contains("Key=\"F5\"", xaml);
        Assert.Contains("Key=\"P\"", xaml);
        Assert.Contains("Modifiers=\"Menu\"", xaml);
        Assert.Contains("Modifiers=\"Control\"", xaml);
        Assert.Contains("Modifiers=\"Control,Shift\"", xaml);
        Assert.True(Count(xaml, "AutomationProperties.LiveSetting=\"Polite\"") >= 4);
        Assert.Contains("AutomationProperties.Name=\"{x:Bind PinActionAutomationName}\"", xaml);
        Assert.Contains("ToolTipService.ToolTip=\"{x:Bind PinActionText}\"", xaml);
        Assert.Contains("AutomationProperties.Name=\"{x:Bind PinnedStatusText}\"", xaml);
        Assert.Contains("ThemeResource CardBackgroundFillColorDefaultBrush", xaml);
        Assert.DoesNotContain("Background=\"#", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Foreground=\"#", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("BorderBrush=\"#", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Storyboard", xaml);
    }

    [Fact]
    public void PageHasTextSingleAttachmentConversationCreationAndForegroundRefreshWithoutSocket()
    {
        var xaml = Read("windows/src/LanStash.App/Views/ChatPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/ChatPage.xaml.cs");
        var send = Read("windows/src/LanStash.App/Views/ChatPage.Send.cs");
        var attachments = Read("windows/src/LanStash.App/Views/ChatPage.Attachments.cs");
        var composer = Read("windows/src/LanStash.App/Features/Chat/ChatTextComposerViewModel.cs");
        var attachmentComposer = Read(
            "windows/src/LanStash.App/Features/Chat/ChatAttachmentComposerViewModel.cs");
        var foreground = Read(
            "windows/src/LanStash.App/Features/Chat/ChatForegroundRefresher.cs");
        var create = Read("windows/src/LanStash.App/Views/ChatPage.CreateConversation.cs");
        var combined = xaml + source + send + attachments + composer + attachmentComposer + foreground + create;

        Assert.Contains("x:Name=\"ComposerPanel\"", xaml);
        Assert.Contains("x:Name=\"ComposerInput\"", xaml);
        Assert.Contains("AcceptsReturn=\"True\"", xaml);
        Assert.Contains("x:Name=\"SendMessageButton\"", xaml);
        Assert.Contains("ChatTextComposerViewModel", source);
        Assert.Contains("ChatAttachmentComposerViewModel", source);
        Assert.Contains("_composer.SendAsync", send);
        Assert.Contains("_attachmentComposer.SendAsync", send);
        Assert.Contains("SendTextAsync", composer);
        Assert.Contains("SendAttachmentAsync", attachmentComposer);
        Assert.Contains("RefreshMessagesAsync", send);
        Assert.Contains("x:Name=\"ChooseAttachmentButton\"", xaml);
        Assert.Contains("x:Name=\"AttachmentCard\"", xaml);
        Assert.Contains("x:Name=\"AttachmentFeedback\"", xaml);
        Assert.Contains("FileOpenPicker", attachments);
        Assert.Contains("FileSavePicker", attachments);
        Assert.Contains("ReadAttachmentThumbnailAsync", attachments);
        Assert.Contains("SaveAttachmentAsync", attachments);
        Assert.Contains("FileMode.CreateNew", attachments);
        Assert.Contains("ChatAttachmentSendReviewBlocker", attachmentComposer);
        Assert.Contains("MinHeight=\"48\"", xaml);
        Assert.Contains("ChatForegroundRefresher", source);
        Assert.Contains("TimeSpan.FromSeconds(30)", foreground);
        Assert.Contains("await _refreshConversations()", foreground);
        Assert.Contains("await _refreshMessages()", foreground);
        Assert.Contains("viewModel.CancelForegroundRefreshes", source);
        Assert.Contains("CreateConversationButton", xaml);
        Assert.Contains("ChatConversationCreatorViewModel", source);
        Assert.Contains("CreatePrivateGroupAsync", create);
        Assert.Contains("CreateDirectAsync", create);
        Assert.DoesNotContain("Socket", combined, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Realtime", combined, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ConversationCreationUsesNativeAccessibleDialogAndBilingualResources()
    {
        var page = Read("windows/src/LanStash.App/Views/ChatPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/ChatPage.CreateConversation.cs");
        var dialog = Read("windows/src/LanStash.App/Views/ChatCreateConversationDialogContent.xaml");
        var dialogSource = Read(
            "windows/src/LanStash.App/Views/ChatCreateConversationDialogContent.xaml.cs");
        var model = Read(
            "windows/src/LanStash.App/Features/Chat/ChatConversationCreatorViewModel.cs");
        var english = Read("windows/src/LanStash.App/Strings/en-US/Resources.resw");
        var chinese = Read("windows/src/LanStash.App/Strings/zh-CN/Resources.resw");

        Assert.Contains("Key=\"C\" Modifiers=\"Control,Shift\"", page);
        Assert.Contains("ContentDialog", source);
        Assert.Contains("GetDeferral()", source);
        Assert.Contains("DefaultButton = ContentDialogButton.Primary", source);
        Assert.Contains("AcceptCreatedConversationAsync", source);
        Assert.Contains("ChatCreateConversationDialogContent", source);
        Assert.Contains("SelectionMode=\"Single\"", dialog);
        Assert.Contains("ListViewSelectionMode.Multiple", dialogSource);
        Assert.Contains("MinHeight=\"44\"", dialog);
        Assert.Contains("AutomationProperties.LiveSetting=\"Assertive\"", dialog);
        Assert.Contains("AutomationProperties.SetName", dialogSource);
        Assert.Contains("ThemeResource TextFillColorSecondaryBrush", dialog);
        Assert.DoesNotContain("Foreground=\"#", dialog, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Background=\"#", dialog, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("RequiresReview", model);
        Assert.Contains("_pendingRequestId", model);
        Assert.Contains("PendingGroupMemberIds", model);
        foreach (var key in new[]
        {
            "ChatCreateAction",
            "ChatCreateDialogTitle",
            "ChatCreatePrimaryAction",
            "ChatCreateReviewAction",
            "ChatCreateCloseAction",
            "ChatCreateTypeLabel",
            "ChatCreateDirectMode",
            "ChatCreateGroupMode",
            "ChatCreateGroupTitleLabel",
            "ChatCreateDirectMemberLabel",
            "ChatCreateGroupMembersLabel",
            "ChatCreateUserListAutomationName",
            "ChatCreateLoading",
            "ChatCreateEmptyTitle",
            "ChatCreateEmptyMessage",
            "ChatCreateLoadErrorTitle",
            "ChatCreateLoadErrorMessage",
            "ChatCreateRetry",
            "ChatCreateReviewTitle",
            "ChatCreateReviewMessage",
            "ChatCreatePermissionTitle",
            "ChatCreatePermissionMessage",
            "ChatCreateUnavailableTitle",
            "ChatCreateUnavailableMessage",
            "ChatCreateCancelledTitle",
            "ChatCreateCancelledMessage",
            "ChatCreateFailedTitle",
            "ChatCreateFailedMessage",
        })
        {
            Assert.Contains($"name=\"{key}\"", english);
            Assert.Contains($"name=\"{key}\"", chinese);
        }
    }

    [Fact]
    public void ForegroundRefreshFollowsPageAndWindowVisibility()
    {
        var page = Read("windows/src/LanStash.App/Views/ChatPage.xaml.cs");
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");

        Assert.Contains("Loaded += ChatPage_Loaded", page);
        Assert.Contains("Unloaded += ChatPage_Unloaded", page);
        Assert.Contains("_isLoaded && _isWindowVisible", page);
        Assert.Contains("_foregroundRefresher.StartAsync(refreshImmediately)", page);
        Assert.Contains("_foregroundRefresher.StopAsync()", page);
        Assert.Contains("internal async Task SetWindowVisibleAsync(bool isVisible)", page);
        Assert.Contains("await _chat.SetWindowVisibleAsync(_isWindowVisible)", shell);
        Assert.Contains("await _chat.SetWindowVisibleAsync(isVisible)", shell);
    }

    [Fact]
    public void PageSupportsLocalConversationPinsWithoutServerPinOrStarRequests()
    {
        var xaml = Read("windows/src/LanStash.App/Views/ChatPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/ChatPage.xaml.cs");
        var model = Read("windows/src/LanStash.App/Features/Chat/ChatBrowserViewModel.cs");
        var state = Read("windows/src/LanStash.App/Features/Chat/ChatBrowserState.cs");
        var store = Read("windows/src/LanStash.App/Features/Chat/ChatConversationPinStore.cs");
        var app = Read("windows/src/LanStash.App/ViewModels/AppViewModel.cs");
        var english = Read("windows/src/LanStash.App/Strings/en-US/Resources.resw");
        var chinese = Read("windows/src/LanStash.App/Strings/zh-CN/Resources.resw");
        var repository = Read("windows/src/LanStash.Infrastructure/Features/Chat/DsmRepository.Chat.cs");
        var attachmentRepository = Read(
            "windows/src/LanStash.Infrastructure/Features/Chat/DsmRepository.ChatAttachment.cs");
        var combined = xaml + source + model + state + store;

        Assert.Contains("ToggleConversationPinAsync", model);
        Assert.Contains("FileChatConversationPinStore", store);
        Assert.Contains("PinnedConversationIds", model);
        Assert.Contains("profileId", store);
        Assert.Contains("x:Name=\"PinStorageError\"", xaml);
        Assert.Contains("x:Name=\"SelectedPinButton\"", xaml);
        Assert.Contains("TogglePinAccelerator_Invoked", source);
        Assert.Contains("IsPinned", state);
        Assert.Contains("PinActionAutomationName", state);
        Assert.Contains("MaximumPinnedConversations", store);
        Assert.Contains("_chatConversationPins.RemoveAsync(profile.Id)", app);
        foreach (var key in new[]
        {
            "ChatBrowserPinnedConversationAutomationName",
            "ChatBrowserPinnedStatus",
            "ChatBrowserPinConversation",
            "ChatBrowserUnpinConversation",
            "ChatBrowserPinConversationAutomationName",
            "ChatBrowserUnpinConversationAutomationName",
            "ChatBrowserPinStorageError.Title",
            "ChatBrowserPinStorageError.Message",
        })
        {
            Assert.Contains($"name=\"{key}\"", english);
            Assert.Contains($"name=\"{key}\"", chinese);
        }
        Assert.DoesNotContain("SYNO.Chat.Star", combined, StringComparison.Ordinal);
        Assert.DoesNotContain("Post.pin", repository + attachmentRepository, StringComparison.Ordinal);
        Assert.DoesNotContain("Post.unpin", repository + attachmentRepository, StringComparison.Ordinal);
        Assert.DoesNotContain("method\", \"pin", repository + attachmentRepository, StringComparison.Ordinal);
        Assert.DoesNotContain("method\", \"unpin", repository + attachmentRepository, StringComparison.Ordinal);
    }

    [Fact]
    public void PageHasReadOnlyGroupMembersDialogWithFiveStatesAndAccessibleControls()
    {
        var page = Read("windows/src/LanStash.App/Views/ChatPage.xaml");
        var pageSource = Read("windows/src/LanStash.App/Views/ChatPage.xaml.cs");
        var membersSource = Read("windows/src/LanStash.App/Views/ChatPage.Members.cs");
        var dialog = Read("windows/src/LanStash.App/Views/ChatMembersDialogContent.xaml");
        var dialogSource = Read("windows/src/LanStash.App/Views/ChatMembersDialogContent.xaml.cs");
        var model = Read("windows/src/LanStash.App/Features/Chat/ChatBrowserViewModel.cs");
        var state = Read("windows/src/LanStash.App/Features/Chat/ChatBrowserState.cs");
        var english = Read("windows/src/LanStash.App/Strings/en-US/Resources.resw");
        var chinese = Read("windows/src/LanStash.App/Strings/zh-CN/Resources.resw");
        var combined = page + pageSource + membersSource + dialog + dialogSource + model + state;

        Assert.Contains("x:Name=\"MembersButton\"", page);
        Assert.Contains("Key=\"M\" Modifiers=\"Control,Shift\"", page);
        Assert.Contains("MembersAccelerator_Invoked", membersSource);
        Assert.Contains("ContentDialog", membersSource);
        Assert.Contains("XamlRoot = XamlRoot", membersSource);
        Assert.Contains("DefaultButton = ContentDialogButton.Close", membersSource);
        Assert.Contains("<ListView", dialog);
        Assert.Contains("x:Name=\"MembersLoadingState\"", dialog);
        Assert.Contains("x:Name=\"MembersEmptyState\"", dialog);
        Assert.Contains("x:Name=\"MembersErrorState\"", dialog);
        Assert.Contains("x:Name=\"MembersContentState\"", dialog);
        foreach (var value in new[] { "Idle", "Loading", "Empty", "Error", "Content" })
        {
            Assert.Contains(value, state);
        }
        Assert.Contains("ThemeResource TextFillColorSecondaryBrush", dialog);
        Assert.DoesNotContain("Foreground=\"#", dialog, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Background=\"#", dialog, StringComparison.OrdinalIgnoreCase);
        Assert.True(Count(page + dialog, "MinHeight=\"44\"") >= 9);
        Assert.Contains("AutomationProperties.Name=\"{x:Bind AutomationName}\"", dialog);
        Assert.Contains("AutomationProperties.SetName", dialogSource);
        Assert.Contains("ToolTipService.SetToolTip", dialogSource);
        Assert.Contains("TextWrapping=\"WrapWholeWords\"", dialog);
        Assert.Contains("TextWrapping=\"Wrap\"", dialog);
        Assert.Contains("ChatMembersCurrentUser", state);
        Assert.Contains("ChatMembersDisabled", state);
        Assert.Contains("ChatMemberAutomationName", state);
        Assert.Contains("CanViewMembers", combined);
        Assert.Contains("ChatConversationKind.Group", state);
        Assert.Contains("CancelConversationMembersLoad", membersSource);
        foreach (var key in new[]
        {
            "ChatBrowserMembersButton",
            "ChatMembersDialogTitle",
            "ChatMembersRefresh",
            "ChatMembersClose",
            "ChatMembersLoading",
            "ChatMembersEmptyTitle",
            "ChatMembersEmptyMessage",
            "ChatMembersErrorTitle",
            "ChatMembersErrorMessage",
            "ChatMembersRetry",
            "ChatMembersCurrentUser",
            "ChatMembersDisabled",
            "ChatMembersCount",
            "ChatMembersList",
            "ChatMemberAutomationName",
            "ChatMemberAutomationNameWithTwoStatuses",
        })
        {
            Assert.Contains($"name=\"{key}", english);
            Assert.Contains($"name=\"{key}", chinese);
        }
    }

    [Fact]
    public void PageHasReadOnlyGroupAnnouncementsDialogWithFiveStatesAndAccessibleControls()
    {
        var page = Read("windows/src/LanStash.App/Views/ChatPage.xaml");
        var pageSource = Read("windows/src/LanStash.App/Views/ChatPage.xaml.cs");
        var announcementsSource = Read("windows/src/LanStash.App/Views/ChatPage.Announcements.cs");
        var dialog = Read("windows/src/LanStash.App/Views/ChatAnnouncementsDialogContent.xaml");
        var dialogSource = Read("windows/src/LanStash.App/Views/ChatAnnouncementsDialogContent.xaml.cs");
        var model = Read("windows/src/LanStash.App/Features/Chat/ChatBrowserViewModel.cs");
        var state = Read("windows/src/LanStash.App/Features/Chat/ChatBrowserState.cs");
        var repository = Read("windows/src/LanStash.Infrastructure/Features/Chat/DsmRepository.Chat.cs");
        var english = Read("windows/src/LanStash.App/Strings/en-US/Resources.resw");
        var chinese = Read("windows/src/LanStash.App/Strings/zh-CN/Resources.resw");
        var combined = page + pageSource + announcementsSource + dialog + dialogSource + model + state;

        Assert.Contains("x:Name=\"AnnouncementsButton\"", page);
        Assert.Contains("Key=\"N\" Modifiers=\"Control,Shift\"", page);
        Assert.Contains("AnnouncementsAccelerator_Invoked", announcementsSource);
        Assert.Contains("ContentDialog", announcementsSource);
        Assert.Contains("XamlRoot = XamlRoot", announcementsSource);
        Assert.Contains("DefaultButton = ContentDialogButton.Close", announcementsSource);
        Assert.Contains("<ListView", dialog);
        Assert.Contains("x:Name=\"AnnouncementsLoadingState\"", dialog);
        Assert.Contains("x:Name=\"AnnouncementsEmptyState\"", dialog);
        Assert.Contains("x:Name=\"AnnouncementsErrorState\"", dialog);
        Assert.Contains("x:Name=\"AnnouncementsContentState\"", dialog);
        Assert.Contains("ThemeResource TextFillColorSecondaryBrush", dialog);
        Assert.DoesNotContain("Foreground=\"#", dialog, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Background=\"#", dialog, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("AutomationProperties.Name=\"{x:Bind AutomationName}\"", dialog);
        Assert.Contains("AutomationProperties.SetName", dialogSource);
        Assert.Contains("ToolTipService.SetToolTip", dialogSource);
        Assert.Contains("TextWrapping=\"WrapWholeWords\"", dialog);
        Assert.Contains("CanViewAnnouncements", combined);
        Assert.Contains("IsEncrypted: false", model);
        Assert.Contains("CancelConversationAnnouncementsLoad", announcementsSource);
        Assert.Contains("\"search\"", repository);
        Assert.Contains("[\"has\"] = \"[\\\"pin\\\"]\"", repository);
        Assert.DoesNotContain("\"pin\",", repository);
        Assert.DoesNotContain("\"unpin\",", repository);
        foreach (var key in new[]
        {
            "ChatBrowserAnnouncementsButton",
            "ChatAnnouncementsDialogTitle",
            "ChatAnnouncementsRefresh",
            "ChatAnnouncementsClose",
            "ChatAnnouncementsLoading",
            "ChatAnnouncementsEmptyTitle",
            "ChatAnnouncementsEmptyMessage",
            "ChatAnnouncementsErrorTitle",
            "ChatAnnouncementsErrorMessage",
            "ChatAnnouncementsRetry",
            "ChatAnnouncementsCount",
            "ChatAnnouncementsList",
            "ChatAnnouncementsUnknownSender",
            "ChatAnnouncementsNoText",
            "ChatAnnouncementsPinnedAt",
            "ChatAnnouncementsSentAt",
            "ChatAnnouncementsSentAtUnavailable",
            "ChatAnnouncementAutomationName",
        })
        {
            Assert.Contains($"name=\"{key}", english);
            Assert.Contains($"name=\"{key}", chinese);
        }
    }

    [Fact]
    public void ShellRoutesChatWithoutWorkspaceFallbackAndDisposesPage()
    {
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var branch = Slice(shell, "if (module == AppModule.Chat)", "ContentFrame.Content = _workspace;");
        var workspace = Read("windows/src/LanStash.App/ViewModels/WorkspaceViewModel.cs");

        Assert.Contains("_app.Repository is not IChatRepository chatRepository", branch);
        Assert.Contains("_chat = new ChatPage(chatRepository)", branch);
        Assert.Contains("ContentFrame.Content = _chat;", branch);
        Assert.True(Count(branch, "return;") >= 2);
        Assert.DoesNotContain("ShowModuleAsync", branch);
        Assert.Contains("_chat?.Dispose();", shell);
        Assert.DoesNotContain("AppModule.Chat =>", workspace);
        Assert.DoesNotContain("LoadConversationsAsync", workspace);
    }

    [Theory]
    [InlineData("ChatBrowserSearch")]
    [InlineData("ChatBrowserConversationList")]
    [InlineData("ChatBrowserBack")]
    [InlineData("ChatBrowserRefreshMessages")]
    [InlineData("ChatBrowserMembersButton")]
    [InlineData("ChatBrowserLoadEarlier")]
    [InlineData("ChatBrowserMessageList")]
    [InlineData("ChatBrowserComposer")]
    [InlineData("ChatBrowserSend")]
    [InlineData("ChatBrowserSendProgress")]
    [InlineData("ChatBrowserSendStatus")]
    [InlineData("ChatAttachmentChoose")]
    [InlineData("ChatAttachmentRemove")]
    [InlineData("ChatAttachmentCancel")]
    [InlineData("ChatAttachmentProgress")]
    [InlineData("ChatAttachmentPreview")]
    [InlineData("ChatAttachmentSave")]
    public void InteractiveControlsHaveBilingualAutomationNames(string uid)
    {
        var english = Read("windows/src/LanStash.App/Strings/en-US/Resources.resw");
        var chinese = Read("windows/src/LanStash.App/Strings/zh-CN/Resources.resw");
        var name = $"{uid}.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name";
        Assert.Contains($"name=\"{name}\"", english);
        Assert.Contains($"name=\"{name}\"", chinese);
    }

    private static int Count(string source, string value) =>
        source.Split(value, StringSplitOptions.None).Length - 1;

    private static string Slice(string source, string start, string end)
    {
        var startIndex = source.IndexOf(start, StringComparison.Ordinal);
        var endIndex = source.IndexOf(end, startIndex, StringComparison.Ordinal);
        Assert.True(startIndex >= 0 && endIndex > startIndex);
        return source[startIndex..endIndex];
    }

    private static string Read(string relativePath)
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, relativePath);
            if (File.Exists(candidate))
            {
                return File.ReadAllText(candidate);
            }
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException(relativePath);
    }
}
