using System.ComponentModel;
using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ChatAdvancedDialogContent : UserControl, IDisposable
{
    private readonly ChatAdvancedViewModel _model;
    private readonly LocalizationService _l = LocalizationService.Current;
    private bool _rendering;
    private bool _ready;
    private bool _submissionCompleted;
    private bool _initialCloseSelection;
    private ChatAdvancedEntry? _cancelEntry;
    internal event Action? StateChanged;
    internal Style ActionButtonStyle => (Style)Resources["ChatAdvancedActionButtonStyle"];
    internal ChatAdvancedDialogContent(ChatAdvancedViewModel model, string? selectedMessageId)
    {
        InitializeComponent(); _model = model;
        SectionPicker.ItemsSource = new[] { _l.Get("ChatAdvancedReminders"), _l.Get("ChatAdvancedSchedules"), _l.Get("ChatAdvancedPolls"),
            _l.Get("ChatActionForward"), _l.Get("ChatActionAnnouncements"), _l.Get("ChatActionClose"), _l.Get("ChatBatchDelete") };
        SectionPicker.Header = _l.Get("ChatAdvancedSection");
        FilterBox.PlaceholderText = _l.Get("ChatAdvancedSearch"); AutomationProperties.SetName(FilterBox, _l.Get("ChatAdvancedSearch"));
        MessagePicker.Header = _l.Get("ChatAdvancedMessage"); MessagePicker.ItemsSource = model.MessageChoices;
        MessagePicker.SelectedItem = model.MessageChoices.FirstOrDefault(item => item.Id == selectedMessageId);
        SourceList.ItemsSource = model.ForwardChoices;
        if (model.ForwardChoices.FirstOrDefault(item => item.Id == selectedMessageId) is { } initialSource) SourceList.SelectedItems.Add(initialSource);
        model.SetSelectedMessage(selectedMessageId);
        MessageText.Header = _l.Get("ChatAdvancedText"); PollChoices.Header = _l.Get("ChatAdvancedChoices");
        MultipleBox.Content = _l.Get("ChatAdvancedMultiple"); AnonymousBox.Content = _l.Get("ChatAdvancedAnonymous");
        DatePicker.Header = _l.Get("ChatAdvancedDate"); TimePicker.Header = _l.Get("ChatAdvancedTime");
        var at = DateTimeOffset.Now.AddHours(1); DatePicker.Date = at; TimePicker.Time = at.TimeOfDay;
        DatePicker.MinDate = DateTimeOffset.Now.Date;
        TimeHint.Text = _l.Format("ChatAdvancedLocalTime", TimeZoneInfo.Local.DisplayName);
        RetryButton.Content = _l.Get("ChatAdvancedRetry"); RefreshButton.Content = _l.Get("ChatAdvancedRefresh");
        BackButton.Content = _l.Get("ChatAdvancedBack"); ReadOnlyText.Text = _l.Get("ChatAdvancedReadOnly");
        TargetLabel.Text = _l.Get("ChatActionTargets");
        SourceLabel.Text = _l.Get("ChatBatchMessages"); DirectUserLabel.Text = _l.Get("ChatBatchNewDirectUsers");
        SourceEmptyText.Text = _l.Get("ChatBatchNoMessages");
        StopRemainingButton.Content = _l.Get("ChatBatchStopRemaining");
        ContinueConfirmation.Content = _l.Get("ChatBatchConfirmContinue");
        AutomationProperties.SetName(SourceList, _l.Get("ChatBatchMessages"));
        AutomationProperties.SetName(DirectUserList, _l.Get("ChatBatchNewDirectUsers"));
        AutomationProperties.SetName(BatchResultList, _l.Get("ChatBatchResults"));
        AutomationProperties.SetName(TargetList, _l.Get("ChatActionTargets"));
        ActionConfirmation.Content = _l.Get("ChatActionConfirm");
        AutomationProperties.SetName(EntryList, _l.Get("ChatAdvancedEntries"));
        EntryList.ItemsSource = model.Items; model.PropertyChanged += ModelChanged;
        _ready = true; Render();
    }

    internal string PrimaryText => _l.Get(_model.CanContinueBatch ? "ChatBatchContinue" : _model.RequiresReview ? "ChatAdvancedReview" : _cancelEntry is not null
        ? _cancelEntry.Pin is not null ? "ChatActionUnpin" : _cancelEntry.Reminder is not null ? "ChatAdvancedCancelReminder" : "ChatAdvancedCancelSchedule"
        : _model.Section switch { ChatAdvancedSection.Reminders => "ChatAdvancedSetReminder", ChatAdvancedSection.ScheduledMessages => "ChatAdvancedSchedule",
            ChatAdvancedSection.Polls => "ChatAdvancedCreatePoll", ChatAdvancedSection.Forward => "ChatActionForward",
            ChatAdvancedSection.Announcements => "ChatActionPin", ChatAdvancedSection.DeleteMessages => "ChatBatchDelete", _ => "ChatActionClose" });
    internal bool CanSubmit => !_model.IsBusy && !_model.IsLoading && !_submissionCompleted && (_model.CanContinueBatch ? ContinueConfirmation.IsChecked == true : (_model.RequiresReview || (_model.CanWrite && _model.ErrorKey is null &&
        (_cancelEntry is not null || _model.Section switch
        {
            ChatAdvancedSection.Reminders => MessagePicker.SelectedItem is ChatAdvancedMessageChoice && SelectedTime is { } at && at > DateTimeOffset.Now,
            ChatAdvancedSection.ScheduledMessages => !string.IsNullOrWhiteSpace(MessageText.Text) && SelectedTime is { } sendAt && sendAt > DateTimeOffset.Now,
            ChatAdvancedSection.Polls => new ChatPollDraft(_model.ConversationId ?? "", MessageText.Text.Trim(), Choices, MultipleBox.IsChecked == true, AnonymousBox.IsChecked == true, Guid.NewGuid()).IsValid,
            ChatAdvancedSection.Forward => SourceList.SelectedItems.Count > 0 && SourceList.SelectedItems.OfType<ChatAdvancedMessageChoice>().All(source => _model.CanForwardMessage(source.Id)) &&
                TargetList.SelectedItems.Count + DirectUserList.SelectedItems.Count > 0 && ActionConfirmation.IsChecked == true,
            ChatAdvancedSection.Announcements => MessagePicker.SelectedItem is ChatAdvancedMessageChoice && ActionConfirmation.IsChecked == true,
            ChatAdvancedSection.DeleteMessages => SourceList.SelectedItems.Count > 0 && ActionConfirmation.IsChecked == true,
            _ => TargetList.SelectedItems.Count > 0 && ActionConfirmation.IsChecked == true,
        }))));
    private string[] Choices => PollChoices.Text.Split('\n').Select(value => value.Trim()).Where(value => value.Length > 0).ToArray();
    private DateTimeOffset? SelectedTime
    {
        get
        {
            if (DatePicker.Date is not { } date) return null;
            var local = DateTime.SpecifyKind(date.Date.AddHours(TimePicker.Time.Hours).AddMinutes(TimePicker.Time.Minutes), DateTimeKind.Unspecified);
            return TimeZoneInfo.Local.IsInvalidTime(local) ? null : new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local));
        }
    }
    internal async Task SubmitAsync()
    {
        if (!CanSubmit) return;
        if (_model.CanContinueBatch) await _model.ContinueBatchAsync();
        else if (_model.RequiresReview) await _model.ReviewAsync();
        else if (_cancelEntry is { } entry) await _model.CancelEntryAsync(entry);
        else if (_model.Section == ChatAdvancedSection.Reminders && MessagePicker.SelectedItem is ChatAdvancedMessageChoice message && SelectedTime is { } at)
            await _model.SetReminderAsync(message.Id, at);
        else if (_model.Section == ChatAdvancedSection.ScheduledMessages && SelectedTime is { } sendAt) await _model.ScheduleAsync(MessageText.Text.Trim(), sendAt);
        else if (_model.Section == ChatAdvancedSection.Polls) await _model.CreatePollAsync(MessageText.Text.Trim(), Choices, MultipleBox.IsChecked == true, AnonymousBox.IsChecked == true);
        else if (_model.Section == ChatAdvancedSection.Forward)
            await _model.ForwardMessagesAsync(SourceList.SelectedItems.OfType<ChatAdvancedMessageChoice>().Select(item => item.Id).ToArray(),
                TargetList.SelectedItems.OfType<ChatAdvancedTarget>().Select(item => item.Id).ToArray(),
                DirectUserList.SelectedItems.OfType<ChatAdvancedTarget>().Select(item => item.Id).ToArray());
        else if (_model.Section == ChatAdvancedSection.Announcements && MessagePicker.SelectedItem is ChatAdvancedMessageChoice pinned) await _model.PinAsync(pinned.Id);
        else if (_model.Section == ChatAdvancedSection.CloseConversation)
            await _model.CloseConversationsAsync(TargetList.SelectedItems.OfType<ChatAdvancedTarget>().Select(item => item.Id).ToArray());
        else if (_model.Section == ChatAdvancedSection.DeleteMessages)
            await _model.DeleteMessagesAsync(SourceList.SelectedItems.OfType<ChatAdvancedMessageChoice>().Select(item => item.Id).ToArray());
        ContinueConfirmation.IsChecked = false;
        if (_model.OutcomeKey == "ChatAdvancedDone")
        {
            // 成功后需要重新选择目标或编辑草稿；快速连点不能变成第二次创建或反向操作。
            if (_cancelEntry is null) { MessagePicker.SelectedItem = null; MessageText.Text = ""; PollChoices.Text = ""; SourceList.SelectedItems.Clear(); TargetList.SelectedItems.Clear(); DirectUserList.SelectedItems.Clear(); ActionConfirmation.IsChecked = false; }
            _submissionCompleted = true;
        }
        if (!_model.RequiresReview) _submissionCompleted = true;
        if (_model.OutcomeKey == "ChatAdvancedDone") _cancelEntry = null;
        Render();
    }
    private void ModelChanged(object? sender, PropertyChangedEventArgs args) => Render();
    private void Render()
    {
        if (!_ready) return;
        _rendering = true;
        if (!ReferenceEquals(MessagePicker.ItemsSource, _model.MessageChoices))
        {
            var selected = (MessagePicker.SelectedItem as ChatAdvancedMessageChoice)?.Id;
            MessagePicker.ItemsSource = _model.MessageChoices;
            MessagePicker.SelectedItem = _model.MessageChoices.FirstOrDefault(item => item.Id == selected);
            ActionConfirmation.IsChecked = false;
        }
        SectionPicker.SelectedIndex = (int)_model.Section; SectionPicker.IsEnabled = !_model.IsBusy && !_model.RequiresReview;
        BatchResults.Visibility = Show(_model.BatchEntries.Count > 0);
        BatchSummary.Text = _model.BatchSummary; BatchResultList.ItemsSource = _model.BatchEntries;
        StopRemainingButton.Visibility = Show(_model.CanContinueBatch);
        ContinueConfirmation.Visibility = Show(_model.CanContinueBatch);
        LoadingRing.IsActive = _model.IsLoading; LoadingRing.Visibility = Show(_model.IsLoading);
        ErrorPanel.Visibility = Show(_model.ErrorKey is not null && !_model.IsLoading); ErrorText.Text = _model.ErrorKey is { } error ? _l.Get(error) : "";
        ContentPanel.Visibility = Show(!_model.IsLoading && _model.ErrorKey is null);
        var action = _model.Section is ChatAdvancedSection.Forward or ChatAdvancedSection.CloseConversation;
        var delete = _model.Section == ChatAdvancedSection.DeleteMessages;
        FilterBox.Visibility = EntryList.Visibility = Show(!action && !delete);
        EmptyText.Visibility = Show(!action && !delete && _model.Items.Count == 0);
        EmptyText.Text = _l.Get(_model.Filter.Length > 0 ? "ChatAdvancedFilteredEmpty" : "ChatAdvancedEmpty");
        Feedback.IsOpen = _model.OutcomeKey is not null; Feedback.Message = _model.OutcomeKey is { } outcome ? _l.Get(outcome) : "";
        Feedback.Severity = _model.RequiresReview ? InfoBarSeverity.Warning : InfoBarSeverity.Informational;
        ReadOnlyText.Visibility = Show(!_model.CanWrite);
        Editor.Visibility = Show(_cancelEntry is null && !_model.RequiresReview);
        ConfirmationPanel.Visibility = Show(_cancelEntry is not null && !_model.RequiresReview);
        foreach (var control in Editor.Children.OfType<Control>())
            control.IsEnabled = _model.CanWrite && !_model.IsBusy && !_model.RequiresReview;
        BackButton.IsEnabled = !_model.IsBusy && !_model.RequiresReview;
        EntryList.IsEnabled = !_model.IsBusy && !_model.RequiresReview;
        var poll = _model.Section == ChatAdvancedSection.Polls;
        var forward = _model.Section == ChatAdvancedSection.Forward;
        var sourceChoices = delete ? _model.DeleteChoices : _model.ForwardChoices;
        if (!ReferenceEquals(SourceList.ItemsSource, sourceChoices))
        {
            var selected = SourceList.SelectedItems.OfType<ChatAdvancedMessageChoice>().Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
            SourceList.ItemsSource = sourceChoices;
            foreach (var item in sourceChoices.Where(item => selected.Contains(item.Id))) SourceList.SelectedItems.Add(item);
            ActionConfirmation.IsChecked = false;
        }
        if (!ReferenceEquals(TargetList.ItemsSource, _model.Targets))
        {
            TargetList.ItemsSource = _model.Targets; ActionConfirmation.IsChecked = false;
            if (_model.Section == ChatAdvancedSection.CloseConversation && !_initialCloseSelection && _model.Targets.FirstOrDefault(item => item.Id == _model.ConversationId) is { } current)
            { TargetList.SelectedItems.Add(current); _initialCloseSelection = true; }
        }
        if (!ReferenceEquals(DirectUserList.ItemsSource, _model.DirectUsers)) { DirectUserList.ItemsSource = _model.DirectUsers; ActionConfirmation.IsChecked = false; }
        MessagePicker.Visibility = Show(_model.Section is ChatAdvancedSection.Reminders or ChatAdvancedSection.Announcements);
        SourceLabel.Visibility = SourceList.Visibility = Show(forward || delete);
        SourceEmptyText.Visibility = Show((forward || delete) && sourceChoices.Count == 0);
        SourceLabel.Text = _l.Get(delete ? "ChatBatchDeleteMessages" : "ChatBatchMessages");
        AutomationProperties.SetName(SourceList, SourceLabel.Text);
        DirectUserLabel.Visibility = DirectUserList.Visibility = Show(forward && _model.DirectUsers.Count > 0);
        TargetLabel.Visibility = TargetList.Visibility = Show(action);
        TargetLabel.Text = _l.Get(forward ? "ChatActionTargets" : "ChatBatchCloseTargets");
        AutomationProperties.SetName(TargetList, TargetLabel.Text);
        MessageText.Visibility = Show(_model.Section is ChatAdvancedSection.ScheduledMessages or ChatAdvancedSection.Polls);
        MessageText.MaxLength = poll ? 256 : 0;
        PollChoices.Visibility = MultipleBox.Visibility = AnonymousBox.Visibility = Show(poll);
        DatePicker.Visibility = TimePicker.Visibility = TimeHint.Visibility = Show(_model.Section is ChatAdvancedSection.Reminders or ChatAdvancedSection.ScheduledMessages);
        ActionHint.Visibility = ActionConfirmation.Visibility = Show(action || delete || _model.Section == ChatAdvancedSection.Announcements);
        ActionHint.Text = _l.Get(delete ? "ChatBatchDeleteWarning" : forward ? "ChatActionForwardWarning" : _model.Section == ChatAdvancedSection.Announcements ? "ChatActionPinWarning" : "ChatActionCloseWarning");
        RefreshButton.IsEnabled = RetryButton.IsEnabled = !_model.IsBusy;
        _rendering = false; StateChanged?.Invoke();
    }
    private async void Section_Changed(object sender, SelectionChangedEventArgs args)
    { if (_ready && !_rendering && SectionPicker.SelectedIndex >= 0) { _submissionCompleted = false; _cancelEntry = null; _initialCloseSelection = false; ActionConfirmation.IsChecked = false; TargetList.SelectedItems.Clear(); DirectUserList.SelectedItems.Clear(); FilterBox.Text = ""; await _model.SetSectionAsync((ChatAdvancedSection)SectionPicker.SelectedIndex); } }
    private void Filter_Changed(object sender, TextChangedEventArgs args) { if (_ready && !_rendering) _model.SetFilter(FilterBox.Text); }
    private async void Refresh_Click(object sender, RoutedEventArgs args)
    {
        if (!_model.IsBusy && !_model.RequiresReview) { _submissionCompleted = false; _cancelEntry = null; }
        await _model.RefreshAsync();
    }
    private void CancelEntry_Click(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { Tag: ChatAdvancedEntry entry } || !entry.CanCancel || _model.RequiresReview) return;
        _submissionCompleted = false; _cancelEntry = entry; ConfirmationText.Text = _l.Format(entry.Pin is not null ? "ChatActionConfirmUnpin" : entry.Reminder is not null ? "ChatAdvancedConfirmCancelReminder" : "ChatAdvancedConfirmCancelSchedule", entry.Detail); Render();
    }
    private void Back_Click(object sender, RoutedEventArgs args) { if (_model.IsBusy || _model.RequiresReview) return; _submissionCompleted = false; _cancelEntry = null; Render(); }
    private void StopRemaining_Click(object sender, RoutedEventArgs args) { _model.StopRemainingBatch(); _submissionCompleted = true; Render(); }
    private void InputChanged() { if (_ready && !_rendering) { _submissionCompleted = false; StateChanged?.Invoke(); } }
    private void Input_Changed(object sender, SelectionChangedEventArgs args)
    {
        if (_ready && !_rendering && ReferenceEquals(sender, MessagePicker)) _model.SetSelectedMessage((MessagePicker.SelectedItem as ChatAdvancedMessageChoice)?.Id);
        if (_ready && !_rendering && ReferenceEquals(sender, SourceList)) _model.SetSelectedMessages(SourceList.SelectedItems.OfType<ChatAdvancedMessageChoice>().Select(item => item.Id));
        if (_ready && !_rendering) ActionConfirmation.IsChecked = false;
        InputChanged();
    }
    private void Text_Changed(object sender, TextChangedEventArgs args) => InputChanged();
    private void Date_Changed(CalendarDatePicker sender, CalendarDatePickerDateChangedEventArgs args) => InputChanged();
    private void Time_Changed(object sender, TimePickerValueChangedEventArgs args) => InputChanged();
    private void Confirmation_Changed(object sender, RoutedEventArgs args) => InputChanged();
    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    public void Dispose() { _ready = false; _model.PropertyChanged -= ModelChanged; }
}
