using LanStash.App.Features.Chat;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal static partial class SmokeSnapshot
{
    private static async Task SaveChatInteractionsAsync(FrameworkElement root)
    {
        await SaveChatInteractionsCoreAsync(root);
        MarkSnapshotComplete();
    }

    private static async Task SaveChatInteractionsCoreAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "thread";
        var repository = new SmokeChatInteractionRepository(state);
        if (state is "workspaces" or "workspaces-language") { await SaveChatWorkspacesAsync(root); return; }
        if (state.StartsWith("media-", StringComparison.Ordinal)) { await SaveChatMediaAsync(root, repository, state); return; }
        if (state.StartsWith("voice-", StringComparison.Ordinal)) { await SaveChatVoiceAsync(root, repository, state); return; }
        using var model = new ChatMessageInteractionModel(repository);
        using var dialog = new ChatMessageInteractionDialog(model, "10") { XamlRoot = root.XamlRoot, RequestedTheme = root.ActualTheme };
        var showing = dialog.ShowAsync(); await Task.Delay(180);
        async Task Click(string id)
        {
            await Task.Delay(60);
            var button = Descendants(dialog).OfType<Button>().Single(item => AutomationProperties.GetAutomationId(item) == id);
            if (!button.IsEnabled || button.Visibility != Visibility.Visible) throw new InvalidOperationException("聊天交互入口不可用。");
            ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke(); await Task.Delay(100);
        }
        Task? pending = null;
        if (state.StartsWith("search", StringComparison.Ordinal))
        {
            model.ShowSearch("10");
            var query = Descendants(dialog).OfType<TextBox>().Single(item => AutomationProperties.GetAutomationId(item) == "ChatMessageSearchQuery");
            query.Text = state == "search-filtered" ? "absent" : "Synthetic";
            await Click("ChatSearchMessages");
            if (state == "search-more") { await Click("ChatSearchMore"); if (model.SearchResults.Count != 2) throw new InvalidOperationException("旧消息搜索分页未合并。"); }
            if (state is "search-empty" or "search-filtered" && (!model.HasSearched || model.SearchResults.Count != 0)) throw new InvalidOperationException("搜索空状态不正确。");
            if (state == "search-error" && model.StatusKey is null) throw new InvalidOperationException("搜索错误未提供恢复状态。");
            if (state == "search-locate")
            {
                await model.OpenAsync(model.SearchResults[0].Message); await Click("ChatOpenConversation"); await showing;
                if (dialog.NavigateMessage?.Id != repository.Message.Id) throw new InvalidOperationException("搜索定位未返回原消息身份。");
                using var page = new ChatPage(repository); ((Frame)((ShellPage)((Frame)root).Content).FindName("ContentFrame")).Content = page;
                await Task.Delay(180); var browser = (ChatBrowserViewModel)page.DataContext;
                if (await browser.RevealMessageAsync(dialog.NavigateMessage) != repository.Message.Id) throw new InvalidOperationException("搜索结果未进入原会话。");
                await WriteSnapshotAsync(page, markComplete: false); return;
            }
        }
        else
        {
            pending = model.OpenAsync(repository.Message);
            if (state != "loading") await pending;
            if (state.StartsWith("edit", StringComparison.Ordinal))
            {
                await Click("ChatEditMessage");
                if (state == "edit-expired" && model.CanSaveEdit) throw new InvalidOperationException("过期消息允许编辑。");
                if (state is "edit-save" or "edit-unknown")
                {
                    Descendants(dialog).OfType<TextBox>().Single(item => AutomationProperties.GetAutomationId(item) == "ChatEditDraft").Text = "Synthetic edited text";
                    await Click("ChatSaveEdit");
                    if (state == "edit-save" && model.Selected?.Text != "Synthetic edited text") throw new InvalidOperationException("编辑结果未回显。");
                    if (state == "edit-unknown" && !model.HasPendingUpdate) throw new InvalidOperationException("编辑未知状态丢失。");
                }
            }
            if (state.StartsWith("vote", StringComparison.Ordinal))
            {
                await Click("ChatVote"); model.SetChoice("a", true); model.SetChoice("b", true);
                if (state == "vote-save") { await Click("ChatSubmitVote"); if (repository.VoteCalls != 1) throw new InvalidOperationException("投票未按完整选择提交。"); }
            }
            if (state is "reply" or "reply-unknown")
            {
                Descendants(dialog).OfType<TextBox>().Single(item => AutomationProperties.GetAutomationId(item) == "ChatReplyDraft").Text = "Synthetic thread reply";
                await Click("ChatSendReply");
                if (repository.ReplyCalls != 1 || repository.LastThread != repository.Message.Id) throw new InvalidOperationException("线程回复丢失原线程。");
                if (state == "reply-unknown" && !model.ReplyComposer.CanRefreshSend) throw new InvalidOperationException("未知线程发送未保留恢复入口。");
            }
        }
        await Task.Delay(120); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
        model.CancelReading(); repository.ReadGate?.TrySetResult(); if (pending is not null) await pending;
        dialog.Hide(); await showing;
    }

    private static async Task SaveChatVoiceAsync(FrameworkElement root, SmokeChatInteractionRepository repository, string state)
    {
        var path = Path.Combine(Path.GetTempPath(), "LanStashSyntheticVoice-" + Guid.NewGuid().ToString("N") + ".m4a");
        try
        {
            var capture = new SmokeVoiceCapture(path, state == "voice-permission");
            await using var model = new ChatVoiceRecordingModel(repository, repository.Conversation, capture);
            using var dialog = new ChatVoiceDialog(model, () => Task.CompletedTask) { XamlRoot = root.XamlRoot, RequestedTheme = root.ActualTheme };
            var showing = dialog.ShowAsync(); await Task.Delay(150);
            if (capture.Starts != 0) throw new InvalidOperationException("打开录音页自动启动了麦克风。");
            async Task Click(string id)
            {
                var button = Descendants(dialog).OfType<Button>().Single(item => AutomationProperties.GetAutomationId(item) == id);
                if (!button.IsEnabled) throw new InvalidOperationException("录音按钮未启用。");
                ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke(); await Task.Delay(100);
            }
            if (state != "voice-ready") await Click("ChatVoiceStart");
            if (state is "voice-recorded" or "voice-send" or "voice-unknown" or "voice-discard") await Click("ChatVoiceStop");
            if (state is "voice-send" or "voice-unknown")
            {
                await Click("ChatVoiceSend");
                if (repository.AttachmentCalls != 1) throw new InvalidOperationException("录音发送未进入既有附件执行链。");
                if (state == "voice-unknown" && (!model.Composer.CanRefreshSend || !File.Exists(path))) throw new InvalidOperationException("未知录音发送丢失副本。");
            }
            if (state == "voice-discard") { await Click("ChatVoiceDiscard"); if (File.Exists(path)) throw new InvalidOperationException("放弃录音未清理副本。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); dialog.Hide(); await showing;
            if (model.IsCapturing) throw new InvalidOperationException("关闭录音页后仍在采集。");
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    private static async Task SaveChatMediaAsync(FrameworkElement root, SmokeChatInteractionRepository repository, string state)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("合成聊天缺少工作区。");
        await using var page = new ChatPage(repository); ((Frame)shell.FindName("ContentFrame")).Content = page;
        await Task.Delay(180); var browser = (ChatBrowserViewModel)page.DataContext;
        await browser.SelectConversationAsync(browser.Conversations.Single());
        var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance;
        var opening = (Task)typeof(ChatPage).GetMethod("ShowChatMediaAsync", flags)!.Invoke(page,
            [new ChatMessageAttachmentItem("10", "101", repository.Message.Attachments.Single())])!;
        await Task.Delay(450);
        var dialog = (ContentDialog)typeof(ChatPage).GetField("_mediaDialog", flags)!.GetValue(page)!;
        var player = (Windows.Media.Playback.MediaPlayer)typeof(ChatPage).GetField("_chatMediaPlayer", flags)!.GetValue(page)!;
        if (state == "media-ready" && (player.Source is null || repository.MediaReads != 1)) throw new InvalidOperationException("媒体未按原附件读取和加载。");
        if (state == "media-large" && repository.MediaReads != 0) throw new InvalidOperationException("超限媒体仍被下载。");
        if (state == "media-error" && !Descendants(dialog).OfType<TextBlock>().Any(item => item.Text == Localization.LocalizationService.Current.Get("ChatMediaFailed")))
            throw new InvalidOperationException("媒体读取失败缺少恢复状态。");
        await WriteSnapshotAsync(dialog, markComplete: false);
        if (state == "media-ready") await page.DisposeAsync();
        else await page.SetWindowVisibleAsync(false);
        await opening;
        if (typeof(ChatPage).GetField("_chatMediaPlayer", flags)!.GetValue(page) is not null) throw new InvalidOperationException("隐藏窗口未释放播放器。");
    }

    private static async Task SaveChatWorkspacesAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage original }) throw new InvalidOperationException("缺少合成工作区。");
        var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance;
        var app = (AppViewModel)typeof(ShellPage).GetField("_app", flags)!.GetValue(original)!;
        Features.Settings.AppSettingsService.Current.SetChatNotificationsEnabled(true);
        var first = await app.AddSmokeConnectedChatAsync("Synthetic first");
        var second = await app.AddSmokeConnectedChatAsync("Synthetic second");
        var target = new ChatNotificationTarget(first.Session.Id, first.Profile.Id, "10", "101");
        if (!app.ActivateChatNotificationWorkspace(target)) throw new InvalidOperationException("通知无法选择原工作区。");
        await Task.Delay(250); var firstPage = app.GetChatPage(first.Repository);
        var firstBrowser = (ChatBrowserViewModel)firstPage.DataContext;
        await firstBrowser.SelectConversationAsync(firstBrowser.Conversations.Single());
        await Task.Delay(120);
        ((TextBox)firstPage.FindName("ComposerInput")).Text = "Synthetic preserved draft"; await Task.Delay(80);
        if (((ChatTextComposerViewModel)typeof(ChatPage).GetField("_composer", flags)!.GetValue(firstPage)!).DraftText != "Synthetic preserved draft")
            throw new InvalidOperationException("合成输入未进入当前草稿。");
        if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") == "workspaces-language")
        {
            var language = Localization.LocalizationService.Current;
            var initial = language.Selection;
            language.SetSelection(language.ResolvedLanguage == "zh-CN" ? AppLanguageSelection.English : AppLanguageSelection.SimplifiedChinese);
            await Task.Delay(250);
            if (!ReferenceEquals(firstPage, app.GetChatPage(first.Repository)) ||
                ((TextBlock)firstPage.FindName("LocalizedChatBrowserTitle")).Text != language.Get("ChatBrowserTitle.Text") ||
                ((Button)firstPage.FindName("MessageSearchButton")).Content as string != language.Get("ChatSearchMessagesButton.Content") ||
                ((TextBox)firstPage.FindName("ComposerInput")).Text != "Synthetic preserved draft")
                throw new InvalidOperationException("切换语言丢失聊天草稿或仍显示旧语言。");
            language.SetSelection(initial); await Task.Delay(250); app.GetChatPage(first.Repository);
            if (((TextBlock)firstPage.FindName("LocalizedChatBrowserTitle")).Text != language.Get("ChatBrowserTitle.Text"))
                throw new InvalidOperationException("恢复语言未刷新原聊天页。");
        }
        await app.SwitchProfileAsync(second.Profile); await Task.Delay(250);
        if (first.Session.IsDisposed || !first.Session.Refresher.State.IsRunning || first.Transport.Disposed)
            throw new InvalidOperationException("切换 NAS 释放了原工作区连接。");
        await app.SwitchProfileAsync(first.Profile); await Task.Delay(250);
        if (!ReferenceEquals(firstPage, app.GetChatPage(first.Repository))) throw new InvalidOperationException("返回原工作区丢失页面。");
        if (((TextBox)firstPage.FindName("ComposerInput")).Text != "Synthetic preserved draft") throw new InvalidOperationException("返回原工作区丢失草稿。");
        if (app.ActivateChatNotificationWorkspace(target with { SessionId = Guid.NewGuid() })) throw new InvalidOperationException("过期通知可以选择工作区。");
        app.BeginAddingProfile(); await Task.Delay(150);
        if (first.Session.IsDisposed || second.Session.IsDisposed) throw new InvalidOperationException("新增 NAS 页面释放了既有订阅。");
        if (!app.ActivateChatNotificationWorkspace(target)) throw new InvalidOperationException("新增连接期间无法返回原消息。");
        await Task.Delay(250);
        if (((Frame)root).Content is not ShellPage current) throw new InvalidOperationException("通知未回到工作区。");
        await current.ShowChatNotificationAsync(target);
        firstPage.UpdateLayout();
        var heading = (TextBlock)firstPage.FindName("LocalizedWorkspaceConversations");
        var create = (Button)firstPage.FindName("CreateConversationButton");
        var createTitle = Localization.LocalizationService.Current.Get("ChatCreateAction");
        if (heading.IsTextTrimmed || AutomationProperties.GetName(create) != createTitle ||
            ToolTipService.GetToolTip(create) as string != createTitle)
            throw new InvalidOperationException("会话栏标题被截断或新建入口缺少本地化辅助说明。");
        await WriteSnapshotAsync(firstPage, markComplete: false);
        await app.ReleaseSmokeChatAsync(first.Profile.Id);
        if (app.IsChatNotificationCurrent(target) || !first.Transport.Disposed || second.Transport.Disposed || second.Session.IsDisposed)
            throw new InvalidOperationException("断开后通知仍有效，或误释放了其他 NAS。");
        await app.ReleaseSmokeChatAsync(second.Profile.Id);
        Features.Settings.AppSettingsService.Current.SetChatNotificationsEnabled(false);
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            foreach (var child in Descendants(VisualTreeHelper.GetChild(root, index))) yield return child;
    }

    private sealed class SmokeVoiceCapture(string path, bool denied) : IChatVoiceCapture
    {
        public event EventHandler? Interrupted { add { } remove { } }
        public TimeSpan Duration => TimeSpan.FromSeconds(2);
        public int Starts;
        public Task StartAsync(CancellationToken token) { Starts++; if (denied) throw new UnauthorizedAccessException(); return Task.CompletedTask; }
        public async Task<ChatVoiceRecording?> StopAsync() { await File.WriteAllBytesAsync(path, [1, 2, 3]); return new(path, Duration); }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}

internal class SmokeChatInteractionRepository : IChatRepository
{
    private readonly string _state;
    public Guid ProfileId { get; } = Guid.NewGuid();
    public ChatAvailability Availability { get; } = new(ChatAvailabilityStatus.Available, Enum.GetValues<ChatReadFeature>().ToHashSet(), Enum.GetValues<ChatWriteFeature>().ToHashSet());
    public ChatConversation Conversation = new("10", ChatConversationKind.Group, "Synthetic team", ["1", "2"], 2, null, DateTimeOffset.UtcNow, 0, false);
    public ChatMessage Message = new("101", "10", "1", "Synthetic author", true, DateTimeOffset.UtcNow, "Synthetic message with a useful discussion.", [], ChatEncryptionState.NotEncrypted) { ReplyCount = 2 };
    public TaskCompletionSource? ReadGate;
    public int ReplyCalls, VoteCalls, AttachmentCalls, MediaReads; public string? LastThread;
    public SmokeChatInteractionRepository(string state)
    {
        _state = state;
        if (state.StartsWith("media-", StringComparison.Ordinal)) Message = Message with { Attachments =
            [new("3", ChatAttachmentKind.Voice, "synthetic.wav", "audio/wav", state == "media-large" ? ChatMediaService.MaximumBytes + 1 : SilentWave().Length, 1000, false)] };
        if (state is "loading" or "search-loading") ReadGate = new(TaskCreationOptions.RunContinuationsAsynchronously);
        if (state.StartsWith("vote", StringComparison.Ordinal)) Message = Message with { Poll = new("101", "Synthetic lunch options?", true, false, null, false,
            [new("a", "First option", 2, false), new("b", "Second option", 1, false)]) { HasStableOptionIds = true } };
    }
    private async Task ReadAsync(CancellationToken token)
    {
        if (ReadGate is not null) await ReadGate.Task.WaitAsync(token);
        if (_state is "error" or "search-error") throw new IOException("synthetic");
    }
    public Task<IReadOnlyList<ChatUser>> ListUsersAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<ChatUser>>([]);
    public Task<IReadOnlyList<ChatUser>> ListConversationMembersAsync(string conversationId, CancellationToken cancellationToken = default) => ListUsersAsync(cancellationToken);
    public async Task<IReadOnlyList<ChatConversation>> ListConversationsAsync(CancellationToken cancellationToken = default) { await ReadAsync(cancellationToken); return [Conversation]; }
    public Task<ChatMessagePage> ListMessagesAsync(string conversationId, string? beforeCursor, int limit, CancellationToken cancellationToken = default) => Task.FromResult(new ChatMessagePage([Message], null, false, 0, 1, 1));
    public async Task<ChatSearchPage> SearchMessagesAsync(string keyword, string? conversationId, string? cursor, int limit, CancellationToken cancellationToken = default)
    {
        await ReadAsync(cancellationToken);
        if (_state is "search-empty" or "search-filtered") return new([], null, 0);
        return new([Message with { Id = cursor is null ? "101" : "102" }], _state == "search-more" && cursor is null ? "1" : null, _state == "search-more" ? 2 : 1);
    }
    public Task<ChatMessage?> LocateMessageAsync(string conversationId, string messageId, string? threadId = null, CancellationToken cancellationToken = default) => Task.FromResult<ChatMessage?>(Message);
    public Task<ChatMessagePage> ListRepliesAsync(string conversationId, string threadId, string? beforeCursor, int limit, CancellationToken cancellationToken = default) =>
        Task.FromResult(new ChatMessagePage(_state == "thread-empty" ? [] : [Message with { Id = "201", ThreadId = "101", Text = "Synthetic first reply", Poll = null },
            Message with { Id = "202", ThreadId = "101", Text = "Synthetic second reply", Poll = null, SentAt = Message.SentAt.AddMilliseconds(1) }], null, false, 0, 2, 2));
    public Task<ChatEditingPolicy> GetEditingPolicyAsync(CancellationToken cancellationToken = default) => Task.FromResult(new ChatEditingPolicy(_state != "edit-expired", TimeSpan.FromMinutes(30)));
    public Task<ChatMessageUpdateOutcome> EditMessageAsync(ChatEditMessageRequest request, CancellationToken cancellationToken = default)
    {
        if (_state != "edit-unknown") Message = Message with { Text = request.Text, EditedAt = DateTimeOffset.UtcNow };
        return Task.FromResult(new ChatMessageUpdateOutcome(Result(_state == "edit-unknown"), _state == "edit-unknown" ? null : Message));
    }
    public Task<ChatMessage> GetPollMessageAsync(ChatMessage original, CancellationToken cancellationToken = default) => Task.FromResult(Message);
    public Task<ChatMessageUpdateOutcome> VoteAsync(ChatVoteRequest request, CancellationToken cancellationToken = default)
    {
        VoteCalls++; if (request.ChoiceIds.Count != 2) throw new InvalidOperationException("合成多选投票丢失选项。");
        Message = Message with { Poll = Message.Poll! with { Options = Message.Poll.Options.Select(option => option with { IsSelectedByCurrentUser = true }).ToArray() } };
        return Task.FromResult(new ChatMessageUpdateOutcome(Result(false), Message));
    }
    public Task<ChatTextSendOutcome> SendTextAsync(ChatTextSendRequest request, CancellationToken cancellationToken = default)
    {
        ReplyCalls++; LastThread = request.ThreadId;
        return Task.FromResult(new ChatTextSendOutcome(Result(_state == "reply-unknown"), "10", request.ClientRequestId,
            _state == "reply-unknown" ? null : Message with { Id = "203", ThreadId = "101", Text = request.Text }));
    }
    public Task<ChatAttachmentSendOutcome> SendAttachmentAsync(ChatAttachmentSendRequest request, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    { AttachmentCalls++; return Task.FromResult(new ChatAttachmentSendOutcome(Result(_state == "voice-unknown"), "10", request.ClientRequestId, _state == "voice-unknown" ? null : Message)); }
    public async Task<ChatAttachmentContentReadResult> SaveAttachmentAsync(string messageId, ChatAttachment attachment, Stream destination, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        MediaReads++; if (_state == "media-error") throw new IOException("synthetic");
        var bytes = SilentWave(); await destination.WriteAsync(bytes, cancellationToken); return new(ChatAttachmentContentReadStatus.Completed, bytes.Length, false);
    }
    private static byte[] SilentWave()
    {
        using var stream = new MemoryStream(); using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8); writer.Write(16036); writer.Write("WAVEfmt "u8); writer.Write(16);
        writer.Write((short)1); writer.Write((short)1); writer.Write(8000); writer.Write(16000); writer.Write((short)2); writer.Write((short)16);
        writer.Write("data"u8); writer.Write(16000); writer.Write(new byte[16000]); return stream.ToArray();
    }
    private static MutationResult Result(bool unknown) => unknown
        ? new(1, MutationResultStatus.SubmittedButUnverified, "synthetic", true, true, new(0, 0, 1))
        : new(1, MutationResultStatus.ConfirmedSuccess, "synthetic", true, false, new(1, 0, 0));
}

public sealed partial class AppViewModel
{
    internal async Task<(NasProfile Profile, SmokeConnectedChatRepository Repository, ChatWorkspaceSession Session, SmokeChatTransport Transport)> AddSmokeConnectedChatAsync(string name)
    {
        var repository = new SmokeConnectedChatRepository();
        var profile = new NasProfile(repository.ProfileId, name, "nas.invalid", 5001, "synthetic");
        var transport = new SmokeChatTransport(); var http = new HttpClient(transport);
        var session = new ChatWorkspaceSession(repository) { NotificationsEnabled = true };
        _connectedWorkspaces.Add(profile.Id, new(profile, profile, new(profile.Id, "synthetic-session", null, null),
            repository, new LanStash.Infrastructure.DsmApiClient(http), http, DsmConnectionSource.DirectAddress, session));
        Profiles.Add(profile); await session.StartAsync(); return (profile, repository, session, transport);
    }
    internal async Task ReleaseSmokeChatAsync(Guid id) { ReleaseWorkspace(id); await Task.WhenAll(_workspaceDisposals); }
}

internal sealed class SmokeChatTransport : HttpMessageHandler
{
    public bool Disposed;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => throw new InvalidOperationException("合成工作区不得访问网络。");
    protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
}

internal sealed class SmokeConnectedChatRepository() : SmokeChatInteractionRepository("thread"), IDsmRepository
{
    public IReadOnlyList<AppModule> AvailableModules => [AppModule.Chat, AppModule.Settings];
    public Task<FilePage> ListFilesAsync(string path, CancellationToken cancellationToken = default) => Task.FromResult(new FilePage([], 0, 0));
    public Task<FilePage> ListFilesAsync(string path, int offset, int limit, CancellationToken cancellationToken = default) => ListFilesAsync(path, cancellationToken);
    public Task<FilePage> ListFilesAsync(string path, int offset, int limit, FileListOptions options, CancellationToken cancellationToken = default) => ListFilesAsync(path, cancellationToken);
    public Task<byte[]> ReadFileRangeAsync(string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<FileRangeReadResult> ReadFileRangeResultAsync(string remotePath, long offset, long length, string? expectedContentVersion = null, long? expectedTotalLength = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<FileItem>> SearchFilesAsync(string path, string query, CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<FileItem>>([]);
    public Task CreateFolderAsync(string parentPath, string name, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task RenameAsync(string path, string newName, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task DeleteFilesAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<NasSettingsSnapshot> LoadNasSettingsAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
}
