using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed class ChatMessageInteractionDialog : ContentDialog, IDisposable
{
    private readonly ChatMessageInteractionModel _model;
    private readonly LocalizationService _l = LocalizationService.Current;
    private readonly StackPanel _search = new() { Spacing = 8 }, _thread = new() { Spacing = 8 },
        _edit = new() { Spacing = 8 }, _vote = new() { Spacing = 8 }, _choices = new() { Spacing = 6 };
    private readonly StackPanel _attachments = new() { Spacing = 6 };
    private readonly TextBox _query = new() { MinHeight = 44 }, _editText = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 110, MaxHeight = 220 },
        _reply = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 60, MaxHeight = 160 };
    private readonly ComboBox _scope = new() { MinHeight = 44, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ListView _results = new() { MaxHeight = 280, DisplayMemberPath = nameof(ChatMessageItem.SearchSummary), IsItemClickEnabled = true, SelectionMode = ListViewSelectionMode.Single },
        _replies = new() { MaxHeight = 190, DisplayMemberPath = nameof(ChatMessageItem.SearchSummary), IsItemClickEnabled = true, SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock _empty = Text(), _root = Text(), _selected = Text(), _policy = Text(), _replyStatus = Text(), _question = Text();
    private readonly InfoBar _status = new() { IsClosable = false };
    private readonly ProgressRing _loading = new() { Width = 30, Height = 30 };
    private readonly Button _searchButton, _more, _editButton, _voteButton, _earlier, _save, _submitVote, _refresh,
        _sendReply, _refreshReply, _showRoot;
    private bool _updating, _disposed;
    private ChatPoll? _renderedPoll;
    private ChatMessage? _renderedAttachments;
    public ChatMessage? NavigateMessage { get; private set; }
    public ChatMessageAttachmentItem? AttachmentRequest { get; private set; }
    public bool SaveAttachmentRequest { get; private set; }

    public ChatMessageInteractionDialog(ChatMessageInteractionModel model, string? currentConversationId)
    {
        _model = model;
        CloseButtonText = _l.Get("ActionClose"); DefaultButton = ContentDialogButton.Close;
        AutomationProperties.SetAutomationId(this, "ChatMessageInteractionDialog");
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        var body = new StackPanel { Spacing = 10, MinWidth = 440, MaxWidth = 700 };
        body.Children.Add(_loading); body.Children.Add(_search); body.Children.Add(_thread); body.Children.Add(_edit); body.Children.Add(_vote); body.Children.Add(_status);
        _refresh = Add(body, "ChatInteractionRefresh", () => _model.RefreshAsync());
        Content = new ScrollViewer { Content = body, MaxHeight = 560, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        _scope.Items.Add(new ComboBoxItem { Content = _l.Get("ChatSearchAll"), Tag = (string?)null });
        if (currentConversationId is not null) _scope.Items.Add(new ComboBoxItem { Content = _l.Get("ChatSearchCurrent"), Tag = currentConversationId });
        _scope.SelectedIndex = currentConversationId is null ? 0 : 1;
        _scope.Header = _l.Get("ChatSearchScope"); _query.Header = _l.Get("ChatSearchQuery");
        AutomationProperties.SetAutomationId(_query, "ChatMessageSearchQuery");
        AutomationProperties.SetAutomationId(_scope, "ChatMessageSearchScope");
        _search.Children.Add(_scope); _search.Children.Add(_query);
        _searchButton = Add(_search, "ChatSearchMessages", () => _model.SearchAsync());
        _search.Children.Add(_results); _search.Children.Add(_empty); _more = Add(_search, "ChatSearchMore", () => _model.SearchAsync(true));
        _results.ItemsSource = model.SearchResults; _replies.ItemsSource = model.Replies;
        AutomationProperties.SetName(_results, _l.Get("ChatSearchResults")); AutomationProperties.SetAutomationId(_results, "ChatMessageSearchResults");
        AutomationProperties.SetName(_replies, _l.Get("ChatThreadReplies")); AutomationProperties.SetAutomationId(_replies, "ChatThreadReplies");
        _thread.Children.Add(_root); _showRoot = Add(_thread, "ChatThreadSelectRoot", () => { if (_model.Root is { } root) _model.Select(root); return Task.CompletedTask; });
        _thread.Children.Add(_replies); _earlier = Add(_thread, "ChatThreadEarlier", () => _model.LoadEarlierAsync()); _thread.Children.Add(_selected);
        _thread.Children.Add(_attachments);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        _editButton = Add(actions, "ChatEditMessage", () => _model.BeginEditAsync());
        _voteButton = Add(actions, "ChatVote", () => _model.BeginVoteAsync());
        Add(actions, "ChatOpenConversation", () => { NavigateMessage = _model.Selected; Hide(); return Task.CompletedTask; });
        _thread.Children.Add(actions);
        _reply.Header = _l.Get("ChatReplyMessage"); AutomationProperties.SetAutomationId(_reply, "ChatReplyDraft"); _thread.Children.Add(_reply);
        var replyButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        _sendReply = Add(replyButtons, "ChatSendReply", () => _model.SendReplyAsync());
        _refreshReply = Add(replyButtons, "ChatRefreshReply", () => _model.SendReplyAsync(true)); _thread.Children.Add(replyButtons); _thread.Children.Add(_replyStatus);
        _editText.Header = _l.Get("ChatEditBody"); AutomationProperties.SetAutomationId(_editText, "ChatEditDraft");
        _edit.Children.Add(_policy); _edit.Children.Add(_editText); _save = Add(_edit, "ChatSaveEdit", () => _model.SaveEditAsync());
        Add(_edit, "ChatBackToThread", BackAsync);
        _vote.Children.Add(_question); _vote.Children.Add(_choices); _submitVote = Add(_vote, "ChatSubmitVote", () => _model.SubmitVoteAsync()); Add(_vote, "ChatBackToThread", BackAsync);
        _query.TextChanged += (_, _) => { if (!_updating) _model.Query = _query.Text; };
        _scope.SelectionChanged += (_, _) => { if (!_updating) _model.ShowSearch((_scope.SelectedItem as ComboBoxItem)?.Tag as string); };
        _editText.TextChanged += (_, _) => { if (!_updating) _model.EditText = _editText.Text; };
        _reply.TextChanged += (_, _) => { if (!_updating) _model.ReplyComposer.DraftText = _reply.Text; };
        _results.ItemClick += async (_, args) => { if (args.ClickedItem is ChatMessageItem item) await _model.OpenAsync(item.Message); };
        _replies.ItemClick += (_, args) => { if (args.ClickedItem is ChatMessageItem item) _model.Select(item.Message); };
        model.PropertyChanged += Changed;
        Closing += (_, args) => { if (_model.IsSubmitting && !_disposed) args.Cancel = true; else _model.CancelReading(); };
        Closed += (_, _) => Dispose();
        Update();
    }

    private Task BackAsync() { _model.BackToThread(); return Task.CompletedTask; }
    internal Task MarkVisibleThreadReadAsync()
    {
        if (_disposed || _thread.Visibility != Visibility.Visible || Content is not ScrollViewer outer) return Task.CompletedTask;
        var outerRows = ChatPage.ReadVisibleRows(_replies, outer).Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        return _model.MarkVisibleThreadReadAsync(ChatPage.ReadVisibleRows(_replies, FindScroller(_replies))
            .Where(item => outerRows.Contains(item.Id)).ToArray());
    }

    private static ScrollViewer? FindScroller(DependencyObject root)
    {
        if (root is ScrollViewer scroll) return scroll;
        for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root); index++)
            if (FindScroller(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, index)) is { } child) return child;
        return null;
    }
    private Button Add(StackPanel panel, string key, Func<Task> action)
    {
        var button = new Button { Content = _l.Get(key), MinHeight = 44 };
        AutomationProperties.SetAutomationId(button, key); button.Click += async (_, _) => await action(); panel.Children.Add(button); return button;
    }
    private static TextBlock Text() => new() { TextWrapping = TextWrapping.WrapWholeWords, IsTextSelectionEnabled = true };
    private void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args) => Update();
    private void Update()
    {
        if (_disposed || _updating) return;
        _updating = true;
        try
        {
            Title = _l.Get(_model.Section switch { ChatInteractionSection.Search => "ChatSearchMessages", ChatInteractionSection.Edit => "ChatEditMessage", ChatInteractionSection.Vote => "ChatVote", _ => "ChatThreadTitle" });
            _search.Visibility = Visible(_model.Section == ChatInteractionSection.Search);
            _thread.Visibility = Visible(_model.Section == ChatInteractionSection.Thread && _model.Root is not null);
            _edit.Visibility = Visible(_model.Section == ChatInteractionSection.Edit); _vote.Visibility = Visible(_model.Section == ChatInteractionSection.Vote);
            _loading.Visibility = Visible(_model.IsBusy); _loading.IsActive = _model.IsBusy;
            _query.IsEnabled = _scope.IsEnabled = !_model.IsBusy;
            if (_query.Text != _model.Query) _query.Text = _model.Query;
            _searchButton.IsEnabled = _model.CanSearch; _more.Visibility = Visible(_model.CanSearchMore); _results.IsEnabled = !_model.IsBusy;
            _empty.Visibility = Visible(!_model.IsBusy && _model.SearchResults.Count == 0);
            _empty.Text = _l.Get(_model.HasSearched ? "ChatSearchEmpty" : "ChatSearchPrompt");
            _status.IsOpen = _model.StatusKey is not null; _status.Message = _model.StatusKey is { } key ? _l.Get(key) : "";
            _status.Severity = _model.StatusKey == "ChatInteractionSaved" ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
            _refresh.Visibility = Visible(_model.Section != ChatInteractionSection.Search && _model.CanRefresh);
            _refresh.IsEnabled = !_model.IsBusy;
            _root.Text = _model.Root is { } root ? _l.Format("ChatThreadRoot", _model.Conversation?.Title ?? "", new ChatMessageItem(root).SearchSummary) : "";
            _selected.Text = _model.Selected is { } selected && selected.Id != _model.Root?.Id ? new ChatMessageItem(selected).SearchSummary : "";
            _selected.Visibility = Visible(_selected.Text.Length > 0); _replies.IsEnabled = _showRoot.IsEnabled = !_model.IsBusy;
            _editButton.Visibility = Visible(_model.CanEditMessage); _voteButton.Visibility = Visible(_model.CanOpenVote);
            _earlier.Visibility = Visible(_model.CanLoadEarlier);
            if (_editText.Text != _model.EditText) _editText.Text = _model.EditText;
            _editText.IsEnabled = !_model.IsBusy && !_model.HasPendingUpdate; _save.IsEnabled = _model.CanSaveEdit;
            _policy.Text = _model.EditingPolicy is { } policy ? _l.Get(!policy.AllowsEditing ? "ChatEditUnavailable" : policy.MaximumAge is null ? "ChatEditUnlimited" : "ChatEditLimited") : "";
            if (_model.EditingPolicy?.MaximumAge is { } age) _policy.Text = _l.Format("ChatEditTimeLimit", age.TotalMinutes);
            var composer = _model.ReplyComposer;
            if (_reply.Text != composer.DraftText) _reply.Text = composer.DraftText;
            _reply.IsEnabled = composer.CanEdit && !_model.IsBusy; _reply.Visibility = Visible(composer.IsAvailable);
            _sendReply.IsEnabled = composer.CanSend && !_model.IsBusy; _sendReply.Visibility = Visible(composer.IsAvailable);
            _refreshReply.Visibility = Visible(composer.CanRefreshSend); _refreshReply.IsEnabled = !_model.IsBusy;
            _replyStatus.Text = composer.State switch
            {
                ChatTextComposerState.NeedsReview => _l.Get("ChatInteractionPending"),
                ChatTextComposerState.Sent => _l.Get("ChatBrowserComposerSent"),
                ChatTextComposerState.Sending => _l.Get("ChatBrowserComposerSending"),
                ChatTextComposerState.Failure => _l.Get("ChatInteractionFailed"),
                ChatTextComposerState.PermissionDenied => _l.Get("ChatInteractionPermission"), _ => "",
            };
            RenderPoll(); _submitVote.IsEnabled = _model.CanVote;
            RenderAttachments();
        }
        finally { _updating = false; }
    }

    private void RenderAttachments()
    {
        if (ReferenceEquals(_renderedAttachments, _model.Selected)) return;
        _renderedAttachments = _model.Selected; _attachments.Children.Clear();
        if (_model.Selected is not { } message) return;
        foreach (var item in new ChatMessageItem(message).Attachments)
        {
            var buttons = new StackPanel { Spacing = 6 };
            void Request(bool save) { AttachmentRequest = item; SaveAttachmentRequest = save; NavigateMessage = message; Hide(); }
            if (item.IsImage || item.IsPlayable)
            {
                var open = new Button { Content = _l.Format("ChatAttachmentOpenNamed", item.FileName), MinHeight = 44 };
                open.Click += (_, _) => Request(false); buttons.Children.Add(open);
            }
            if (item.CanSave)
            {
                var save = new Button { Content = _l.Format("ChatAttachmentSaveNamed", item.FileName), MinHeight = 44 };
                save.Click += (_, _) => Request(true); buttons.Children.Add(save);
            }
            _attachments.Children.Add(buttons);
        }
    }

    private void RenderPoll()
    {
        var poll = _model.Selected?.Poll;
        if (poll is null) { _choices.Children.Clear(); _renderedPoll = null; return; }
        _question.Text = poll.Question;
        if (!ReferenceEquals(_renderedPoll, poll))
        {
            _renderedPoll = poll; _choices.Children.Clear();
            foreach (var option in poll.Options)
            {
                var choice = new CheckBox { Content = _l.Format("ChatAdvancedPollOptionCount", option.Text, option.VoteCount), Tag = option.Id, MinHeight = 44 };
                AutomationProperties.SetAutomationId(choice, "ChatVoteChoice");
                choice.Checked += ChoiceChanged; choice.Unchecked += ChoiceChanged; _choices.Children.Add(choice);
            }
        }
        foreach (var item in _choices.Children.OfType<CheckBox>())
        {
            item.IsChecked = _model.SelectedChoices.Contains((string)item.Tag);
            item.IsEnabled = !_model.IsBusy && !_model.HasPendingUpdate && !poll.IsClosed && (poll.ClosesAt is null || poll.ClosesAt > DateTimeOffset.UtcNow);
        }
    }
    private void ChoiceChanged(object sender, RoutedEventArgs args)
    {
        if (!_updating && sender is CheckBox { Tag: string id } choice) _model.SetChoice(id, choice.IsChecked == true);
    }
    private static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    public void Dispose()
    {
        if (_disposed) return; _disposed = true; _model.PropertyChanged -= Changed; _model.Close();
    }
}
