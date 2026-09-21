using System.Globalization;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed record NasDiskRow(NasDiskTestTarget Target, string Name, string Detail);
public sealed record NasDiskHistoryRow(string Text);
public sealed partial class NasDiskTestsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasDiskTestViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    private NasDiskTestTarget[] _displayed = [];
    private NasDiskTestHistory? _history;
    private readonly DispatcherTimer _pollTimer = new() { Interval = TimeSpan.FromSeconds(4) };
    public event Action? StateChanged;
    public bool CanSave => false;
    public bool IsBusy => _model.IsBusy;
    public string? PrimaryButtonResourceKey => null;
    public NasDiskTestsDialogContent(INasSettingsRepository repository)
    { _repository = repository; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); _pollTimer.Tick += Poll_Tick; _synchronizing = false; }
    public async Task ActivateAsync() { await _model.ActivateAsync(_repository); if (!_disposed) _pollTimer.Start(); }
    public Task ReloadAsync() => _model.ReloadAsync();
    public Task SaveAsync() => Task.CompletedTask;
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        FeedbackNotice.IsOpen = _model.Feedback is not null; FeedbackNotice.Message = _model.Feedback ?? "";
        FeedbackNotice.Severity = _model.WasSuccessful ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        PendingNotice.IsOpen = _model.Pending.Count > 0;
        PendingNotice.Message = L.Format("NasDiskPending", string.Join(Environment.NewLine, _model.Pending.Select(item => NasDiskTestViewModel.DisplayName(item.Target))));
        ReadOnlyNotice.Visibility = _model.IsReadOnly ? Visibility.Visible : Visibility.Collapsed;
        SearchInput.IsEnabled = DiskList.IsEnabled = !IsBusy;
        var visible = _model.VisibleDisks;
        if (!_displayed.SequenceEqual(visible))
        {
            _displayed = visible.ToArray();
            DiskList.ItemsSource = _displayed.Select(item => new NasDiskRow(item, NasDiskTestViewModel.DisplayName(item),
                L.Get(item.SupportsSmartTest switch { true => "NasDiskSupported", false => "NasDiskUnsupportedDevice", _ => "NasDiskSupportUnknown" }))).ToArray();
        }
        DiskList.SelectedItem = DiskList.Items.OfType<NasDiskRow>().FirstOrDefault(row => ReferenceEquals(row.Target, _model.Selected));
        EmptyNotice.Visibility = !IsBusy && _model.ErrorMessage is null && visible.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Text = L.Get(_model.Disks.Count == 0 ? "NasDiskEmpty" : "NasDiskNoMatches");
        UnsupportedNotice.Visibility = _model.Selected is { SupportsSmartTest: not true } ? Visibility.Visible : Visibility.Collapsed;
        StatePanel.Visibility = _model.State is null ? Visibility.Collapsed : Visibility.Visible;
        if (_model.State is { } state)
        {
            StateText.Text = state.IsRunning ? L.Format("NasDiskRunning", TypeText(state.RunningType)) :
                L.Get(state.IsBusyWithOtherTest switch { true => "NasDiskOtherBusy", false => "NasDiskIdle", _ => "NasDiskBusyUnknown" });
            ProgressText.Text = L.Format("NasDiskProgress", state.ProgressDescription ?? L.Get("UnknownValue"));
            ProgressText.Visibility = state.IsRunning ? Visibility.Visible : Visibility.Collapsed;
            ResultText.Text = L.Format("NasDiskLastResult", state.LastResult ?? L.Get("UnknownValue"));
        }
        RefreshButton.IsEnabled = HistoryButton.IsEnabled = _model.CanRead;
        QuickButton.IsEnabled = _model.CanChoose(NasDiskTestCommand.Quick);
        ExtendedButton.IsEnabled = _model.CanChoose(NasDiskTestCommand.Extended); StopButton.IsEnabled = _model.CanChoose(NasDiskTestCommand.Stop);
        ConfirmationPanel.Visibility = _model.Command is null ? Visibility.Collapsed : Visibility.Visible;
        var action = L.Get(_model.Command switch { NasDiskTestCommand.Stop => "NasDiskStop.Content", NasDiskTestCommand.Extended => "NasDiskExtended.Content", _ => "NasDiskQuick.Content" });
        ConfirmationText.Text = L.Format(_model.Command == NasDiskTestCommand.Stop ? "NasDiskStopWarning" : "NasDiskStartWarning",
            _model.Selected is { } target ? NasDiskTestViewModel.DisplayName(target) : "", action);
        ExecuteButton.Content = action; ExecuteButton.IsEnabled = _model.CanExecute;
        RiskAcknowledgement.IsEnabled = _model.Command is { } command && _model.CanChoose(command);
        if (!_model.CanExecute) RiskAcknowledgement.IsChecked = false;
        HistoryErrorNotice.IsOpen = _model.HistoryError is not null; HistoryErrorNotice.Message = _model.HistoryError ?? "";
        HistoryPanel.Visibility = _model.History is null ? Visibility.Collapsed : Visibility.Visible;
        EmptyHistory.Visibility = _model.History?.Entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        TruncatedHistory.Visibility = _model.History?.IsTruncated == true ? Visibility.Visible : Visibility.Collapsed;
        if (!ReferenceEquals(_history, _model.History))
        {
            _history = _model.History;
            HistoryList.ItemsSource = _history?.Entries.Select(entry => new NasDiskHistoryRow(L.Format("NasDiskHistoryRow",
                TypeText(entry.Type), FormatReportedTime(entry.ReportedTime), entry.Result ?? L.Get("UnknownValue")))).ToArray();
        }
        _synchronizing = false; StateChanged?.Invoke();
    }
    private static string TypeText(NasDiskTestType? type) => L.Get(type switch { NasDiskTestType.Quick => "NasDiskQuickType", NasDiskTestType.Extended => "NasDiskExtendedType", _ => "UnknownValue" });
    private static string FormatReportedTime(string? value)
    {
        if (string.IsNullOrEmpty(value)) return L.Get("UnknownValue");
        DateTimeOffset parsed;
        if (double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var timestamp))
        {
            try { parsed = DateTimeOffset.UnixEpoch.AddSeconds(timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp); }
            catch (ArgumentOutOfRangeException) { return value; }
        }
        else if (!DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out parsed)) return value;
        return parsed.ToLocalTime().ToString("g", CultureInfo.GetCultureInfo(L.ResolvedLanguage));
    }
    private async void Poll_Tick(object? sender, object e) { if (!_disposed) await _model.PollAsync(); }
    private async Task SyncSelection()
    {
        if (_disposed || _synchronizing) return;
        _model.SetSearch(SearchInput.Text); await _model.SelectAsync((DiskList.SelectedItem as NasDiskRow)?.Target);
    }
    private async void Search_Changed(object sender, TextChangedEventArgs e) => await SyncSelection();
    private async void Selection_Changed(object sender, SelectionChangedEventArgs e) => await SyncSelection();
    private async void Refresh_Click(object sender, RoutedEventArgs e) { await SyncSelection(); await _model.RefreshStateAsync(); }
    private async void History_Click(object sender, RoutedEventArgs e) { await SyncSelection(); await _model.LoadHistoryAsync(); }
    private async void Quick_Click(object sender, RoutedEventArgs e) { await SyncSelection(); _model.Choose(NasDiskTestCommand.Quick); }
    private async void Extended_Click(object sender, RoutedEventArgs e) { await SyncSelection(); _model.Choose(NasDiskTestCommand.Extended); }
    private async void Stop_Click(object sender, RoutedEventArgs e) { await SyncSelection(); _model.Choose(NasDiskTestCommand.Stop); }
    private async void Confirm_Changed(object sender, RoutedEventArgs e)
    {
        if (_synchronizing || _disposed) return; var confirmed = RiskAcknowledgement.IsChecked == true;
        await SyncSelection(); _model.Confirm(confirmed); _synchronizing = true; RiskAcknowledgement.IsChecked = _model.CanExecute; _synchronizing = false;
    }
    private async void Execute_Click(object sender, RoutedEventArgs e) { await SyncSelection(); await _model.ExecuteAsync(); }
    public void Dispose()
    {
        if (_disposed) return; _disposed = true; _synchronizing = true; _pollTimer.Stop(); _pollTimer.Tick -= Poll_Tick; _model.Dispose();
        DiskList.ItemsSource = HistoryList.ItemsSource = null; _displayed = []; _history = null; StateChanged = null;
    }
    private static LocalizationService L => LocalizationService.Current;
}
