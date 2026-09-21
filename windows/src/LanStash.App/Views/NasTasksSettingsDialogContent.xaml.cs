using System.Globalization;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed record NasTaskSettingsRow(NasTaskEntry Entry, string Detail);
public sealed record NasTaskResultRow(NasTaskResult Result, string Detail);
public sealed partial class NasTasksSettingsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasTaskManagementViewModel _model = new();
    private readonly CheckBox[] _days = new CheckBox[7];
    private bool _disposed, _synchronizing = true;
    private int _contentVersion = -1;
    private NasTaskEntry[] _displayed = [];
    private NasTaskResult[] _results = [];
    public event Action? StateChanged;
    public bool CanSave => false;
    public bool IsBusy => _model.IsBusy;
    public string? PrimaryButtonResourceKey => null;
    public NasTasksSettingsDialogContent(INasSettingsRepository repository)
    {
        _repository = repository; InitializeComponent();
        for (var day = 0; day < 7; day++)
        {
            var box = new CheckBox { Content = CultureInfo.GetCultureInfo(L.ResolvedLanguage).DateTimeFormat.GetDayName((DayOfWeek)day), Margin = new Thickness(0, 0, 12, 6) };
            box.Checked += Checks_Changed; box.Unchecked += Checks_Changed; _days[day] = box; DayChoices.Items.Add(box);
        }
        _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false;
    }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task ReloadAsync() => _model.ReloadAsync();
    public Task SaveAsync() => Task.CompletedTask;
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        FeedbackNotice.IsOpen = _model.Feedback is not null; FeedbackNotice.Message = _model.Feedback ?? "";
        FeedbackNotice.Severity = _model.WasSuccessful ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        PendingNotice.IsOpen = _model.PendingCommands.Count + _model.PendingSaves.Count > 0;
        PendingNotice.Message = L.Format("NasTasksPending", string.Join(Environment.NewLine,
            _model.PendingCommands.Select(item => item.Name).Concat(_model.PendingSaves.Select(item => item.Name)).Distinct()));
        var available = _repository.TaskCommandAvailability;
        ReadOnlyNotice.Visibility = !_repository.CanSaveScheduledTasks && !available.CanRun && !available.CanDelete && !available.CanEnableDisable ? Visibility.Visible : Visibility.Collapsed;
        SearchInput.IsEnabled = TaskList.IsEnabled = !IsBusy && !_model.IsEditing;
        var visible = _model.VisibleTasks;
        if (!_displayed.SequenceEqual(visible))
        {
            _displayed = visible.ToArray();
            TaskList.ItemsSource = _displayed.Select(item => new NasTaskSettingsRow(item,
                L.Format("NasTasksRow", item.Owner ?? L.Get("UnknownValue"),
                    L.Get(item.IsEnabled switch { true => "NasTasksOn", false => "NasTasksOff", _ => "UnknownValue" }),
                    item.NextTrigger ?? L.Get("UnknownValue")))).ToArray();
        }
        TaskList.SelectedItem = TaskList.Items.OfType<NasTaskSettingsRow>().FirstOrDefault(row => ReferenceEquals(row.Entry, _model.Selected));
        EmptyNotice.Visibility = !IsBusy && _model.ErrorMessage is null && visible.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Text = L.Get(_model.Tasks.Count == 0 ? "NasTasksEmpty" : "NasTasksNoMatches");
        CreateButton.IsEnabled = _model.CanCreate; EditButton.IsEnabled = _model.CanEdit;
        DetailButton.IsEnabled = ResultsButton.IsEnabled = _model.CanReadSelected && !IsBusy;
        EnableButton.IsEnabled = _model.CanCommand(NasTaskCommand.Enable); DisableButton.IsEnabled = _model.CanCommand(NasTaskCommand.Disable);
        RunButton.IsEnabled = _model.CanCommand(NasTaskCommand.Run); DeleteButton.IsEnabled = _model.CanCommand(NasTaskCommand.Delete);
        if (_contentVersion != _model.ContentVersion)
        {
            _contentVersion = _model.ContentVersion; var draft = _model.Draft;
            NameInput.Text = draft?.Name ?? ""; OwnerInput.Text = draft?.Owner ?? ""; EnabledInput.IsChecked = draft?.IsEnabled;
            HourInput.Value = draft?.Schedule?.Hour ?? double.NaN; MinuteInput.Value = draft?.Schedule?.Minute ?? double.NaN;
            var selectedDays = draft?.Schedule?.WeekDays?.Split(',') ?? [];
            for (var day = 0; day < 7; day++) _days[day].IsChecked = selectedDays.Contains(day.ToString(CultureInfo.InvariantCulture));
            ScriptInput.Text = draft?.Script ?? ""; NotifyInput.IsChecked = draft?.NotifyOnError; EmailInput.Text = draft?.NotificationEmails ?? "";
            RiskAcknowledgement.IsChecked = false;
        }
        EditorPanel.Visibility = _model.Draft is null ? Visibility.Collapsed : Visibility.Visible;
        BrowserPanel.Visibility = _model.Draft is not null || _model.HasLoadedResults ? Visibility.Collapsed : Visibility.Visible;
        IncompleteNotice.Visibility = _model.Draft is { } details && (details.Script is null || details.Owner is null ||
            details.IsEnabled is null || details.NotifyOnError is null || details.NotificationEmails is null ||
            details.Schedule is not { Hour: not null, Minute: not null, WeekDays: not null }) ? Visibility.Visible : Visibility.Collapsed;
        DetailTitle.Text = L.Get(_model.IsEditing ? _model.IsNew ? "NasTasksNewTitle" : "NasTasksEditTitle" : "NasTasksDetailTitle");
        var editing = _model.IsEditing && !IsBusy;
        foreach (var box in new[] { NameInput, OwnerInput, ScriptInput, EmailInput }) box.IsReadOnly = !editing;
        EnabledInput.IsEnabled = NotifyInput.IsEnabled = HourInput.IsEnabled = MinuteInput.IsEnabled = editing;
        foreach (var day in _days) day.IsEnabled = editing;
        ValidationNotice.Visibility = editing && !_model.CanSave ? Visibility.Visible : Visibility.Collapsed;
        if (!_results.SequenceEqual(_model.Results))
        {
            _results = _model.Results.ToArray();
            ResultList.ItemsSource = _results.Select(item => new NasTaskResultRow(item,
                L.Format("NasTasksResultRow", item.StartedAt ?? L.Get("UnknownValue"), item.StoppedAt ?? L.Get("UnknownValue"),
                    item.ExitType ?? L.Get("UnknownValue"), item.ExitCode is int code ? (object)code : L.Get("UnknownValue")))).ToArray();
        }
        ResultList.SelectedItem = ResultList.Items.OfType<NasTaskResultRow>().FirstOrDefault(row => ReferenceEquals(row.Result, _model.SelectedResult));
        HistoryPanel.Visibility = _model.HasLoadedResults ? Visibility.Visible : Visibility.Collapsed;
        EmptyHistory.Visibility = _model.HasLoadedResults && _results.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        ResultList.IsEnabled = !IsBusy;
        OutputPanel.Visibility = _model.HasLoadedOutput ? Visibility.Visible : Visibility.Collapsed;
        CommandOutput.Text = _model.Output?.Command ?? L.Get("UnknownValue"); ResultOutput.Text = _model.Output?.Output ?? L.Get("UnknownValue");
        CloseDetailButton.Visibility = _model.Draft is not null || _model.HasLoadedResults || _model.Command is not null ? Visibility.Visible : Visibility.Collapsed;
        CloseDetailButton.IsEnabled = !_model.IsMutating;
        ConfirmationPanel.Visibility = _model.IsEditing || _model.Command is not null ? Visibility.Visible : Visibility.Collapsed;
        var action = ActionText();
        ConfirmationText.Text = L.Format(_model.Command == NasTaskCommand.Delete ? "NasTasksDeleteWarning" : "NasTasksChangeWarning",
            _model.Draft?.Name ?? _model.Selected?.Name ?? "", action);
        ExecuteButton.Content = action; ExecuteButton.IsEnabled = _model.CanExecute;
        RiskAcknowledgement.IsEnabled = !IsBusy && (_model.CanSave || _model.Command is { } command && _model.CanCommand(command));
        if (!_model.CanExecute) RiskAcknowledgement.IsChecked = false;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private string ActionText() => L.Get(_model.Command switch
    {
        NasTaskCommand.Enable => "NasTasksEnable.Content", NasTaskCommand.Disable => "NasTasksDisable.Content",
        NasTaskCommand.Run => "NasTasksRun.Content", NasTaskCommand.Delete => "NasTasksDelete.Content", _ => "ActionSave"
    });
    private void SyncSelection()
    {
        if (_disposed || _synchronizing || _model.IsEditing) return;
        _model.SetSearch(SearchInput.Text);
        _model.SelectTask((TaskList.SelectedItem as NasTaskSettingsRow)?.Entry);
    }
    private void ReadFields()
    {
        if (_disposed || _synchronizing || IsBusy || !_model.IsEditing || _model.Draft is not { } draft) return;
        static int? Number(double value) => double.IsFinite(value) && value == Math.Truncate(value) && value is >= int.MinValue and <= int.MaxValue ? (int)value : null;
        _model.ChangeDraft(draft with
        {
            Name = NameInput.Text, Owner = OwnerInput.Text, IsEnabled = EnabledInput.IsChecked, Script = ScriptInput.Text,
            NotifyOnError = NotifyInput.IsChecked, NotificationEmails = EmailInput.Text,
            Schedule = draft.Schedule is null ? null : draft.Schedule with
            {
                Hour = Number(HourInput.Value), Minute = Number(MinuteInput.Value),
                WeekDays = string.Join(",", Enumerable.Range(0, 7).Where(day => _days[day].IsChecked == true))
            }
        });
    }
    private void Search_Changed(object sender, TextChangedEventArgs e) => SyncSelection();
    private void Selection_Changed(object sender, SelectionChangedEventArgs e) => SyncSelection();
    private void Fields_Changed(object sender, TextChangedEventArgs e) => ReadFields();
    private void Checks_Changed(object sender, RoutedEventArgs e) => ReadFields();
    private void Number_Changed(NumberBox sender, NumberBoxValueChangedEventArgs e) => ReadFields();
    private async void Create_Click(object sender, RoutedEventArgs e) { SyncSelection(); await _model.CreateAsync(); }
    private async void Detail_Click(object sender, RoutedEventArgs e) { SyncSelection(); await _model.OpenDetailAsync(false); }
    private async void Edit_Click(object sender, RoutedEventArgs e) { SyncSelection(); await _model.OpenDetailAsync(true); }
    private async void Enable_Click(object sender, RoutedEventArgs e) { SyncSelection(); await _model.ChooseCommandAsync(NasTaskCommand.Enable); }
    private async void Disable_Click(object sender, RoutedEventArgs e) { SyncSelection(); await _model.ChooseCommandAsync(NasTaskCommand.Disable); }
    private async void Run_Click(object sender, RoutedEventArgs e) { SyncSelection(); await _model.ChooseCommandAsync(NasTaskCommand.Run); }
    private async void Delete_Click(object sender, RoutedEventArgs e) { SyncSelection(); await _model.ChooseCommandAsync(NasTaskCommand.Delete); }
    private async void Results_Click(object sender, RoutedEventArgs e) { SyncSelection(); await _model.LoadResultsAsync(); }
    private async void Result_Changed(object sender, SelectionChangedEventArgs e)
    { if (!_synchronizing && !_disposed) await _model.SelectResultAsync((ResultList.SelectedItem as NasTaskResultRow)?.Result); }
    private void CloseDetail_Click(object sender, RoutedEventArgs e) => _model.CloseDetail();
    private void Confirm_Changed(object sender, RoutedEventArgs e)
    {
        if (_synchronizing || _disposed) return;
        var confirmed = RiskAcknowledgement.IsChecked == true; SyncSelection(); ReadFields(); _model.Confirm(confirmed);
        _synchronizing = true; RiskAcknowledgement.IsChecked = _model.CanExecute; _synchronizing = false;
    }
    private async void Execute_Click(object sender, RoutedEventArgs e)
    { SyncSelection(); ReadFields(); if (_model.CanExecute) await _model.ExecuteAsync(); }
    public void Dispose()
    {
        if (_disposed) return; _disposed = true; _synchronizing = true; _model.Dispose();
        ScriptInput.Text = EmailInput.Text = CommandOutput.Text = ResultOutput.Text = "";
        TaskList.ItemsSource = ResultList.ItemsSource = null; _displayed = []; _results = []; StateChanged = null;
    }
    private static LocalizationService L => LocalizationService.Current;
}
