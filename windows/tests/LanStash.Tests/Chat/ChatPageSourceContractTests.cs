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
    public void PageHasTextAndSingleAttachmentComposersWithoutRealtimeOrConversationActions()
    {
        var xaml = Read("windows/src/LanStash.App/Views/ChatPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/ChatPage.xaml.cs");
        var send = Read("windows/src/LanStash.App/Views/ChatPage.Send.cs");
        var attachments = Read("windows/src/LanStash.App/Views/ChatPage.Attachments.cs");
        var composer = Read("windows/src/LanStash.App/Features/Chat/ChatTextComposerViewModel.cs");
        var attachmentComposer = Read(
            "windows/src/LanStash.App/Features/Chat/ChatAttachmentComposerViewModel.cs");
        var combined = xaml + source + send + attachments + composer + attachmentComposer;

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
        Assert.DoesNotContain("CreateConversation", combined, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Socket", combined, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Realtime", combined, StringComparison.OrdinalIgnoreCase);
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
