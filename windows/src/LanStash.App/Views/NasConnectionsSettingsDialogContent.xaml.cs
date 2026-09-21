using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed record NasConnectionSettingsRow(NasConnectionEntry Connection, string Title, string Detail, string Status, string AutomationName);
public sealed partial class NasConnectionsSettingsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasConnectionManagementViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    private int _confirmationVersion = -1;
    private NasConnectionEntry[] _displayed = [];
    public event Action? StateChanged;
    public bool CanSave => false;
    public bool IsBusy => _model.IsBusy;
    public string? PrimaryButtonResourceKey => null;
    public NasConnectionsSettingsDialogContent(INasSettingsRepository repository)
    { _repository = repository; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; }
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
        PendingNotice.IsOpen = _model.Pending.Count > 0 && (_model.Pending.Count > 1 || _model.LastResult?.Counts.Unknown is not > 0);
        PendingNotice.Message = L.Format("NasConnectionsPending", string.Join(Environment.NewLine, _model.Pending.Select(item => NasConnectionManagementViewModel.Describe(item.Account, item.Source, item.Protocol))));
        ReadOnlyNotice.Visibility = _model.IsReadOnly ? Visibility.Visible : Visibility.Collapsed;
        PartialNotice.Visibility = !IsBusy && _model.ErrorMessage is null && !_model.IsComplete ? Visibility.Visible : Visibility.Collapsed;
        SearchInput.IsEnabled = ConnectionList.IsEnabled = !IsBusy;
        var visible = _model.VisibleConnections;
        if (!_displayed.SequenceEqual(visible))
        {
            _displayed = visible.ToArray();
            ConnectionList.ItemsSource = _displayed.Select(item =>
            {
                var title = NasConnectionManagementViewModel.Describe(item.Account, item.Source, item.Protocol ?? item.Type);
                var detail = L.Format("NasConnectionsDetails", item.Description ?? L.Get("UnknownValue"), item.Location ?? L.Get("UnknownValue"), item.ReportedTime ?? L.Get("UnknownValue"));
                var status = L.Get(item.IsCurrent switch { true => "NasConnectionsCurrent", false => "NasConnectionsOther", _ => "NasConnectionsCurrentUnknown" });
                return new NasConnectionSettingsRow(item, title, detail, status, L.Format("NasDetailsRowAutomationName", title, detail + Environment.NewLine + status));
            }).ToArray();
        }
        ConnectionList.SelectedItem = ConnectionList.Items.OfType<NasConnectionSettingsRow>().FirstOrDefault(row => ReferenceEquals(row.Connection, _model.Selected));
        EmptyNotice.Visibility = !IsBusy && _model.ErrorMessage is null && visible.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Text = L.Get(_model.Connections.Count == 0 ? "NasConnectionsEmpty" : "NasConnectionsNoMatches");
        RestrictionNotice.Visibility = !IsBusy && !_model.IsReadOnly && _model.IsComplete && _model.Selected is not null && !_model.CanChoose ? Visibility.Visible : Visibility.Collapsed;
        ConfirmationPanel.Visibility = _model.CanChoose ? Visibility.Visible : Visibility.Collapsed;
        ConfirmationText.Text = L.Format("NasConnectionsConfirmation", _model.Selected is { } selected ? NasConnectionManagementViewModel.Describe(selected.Account, selected.Source, selected.Protocol ?? selected.Type) : "");
        if (_confirmationVersion != _model.ConfirmationVersion)
        {
            _confirmationVersion = _model.ConfirmationVersion; RiskAcknowledgement.IsChecked = false; CurrentSessionAcknowledgement.IsChecked = false;
        }
        RiskAcknowledgement.IsEnabled = CurrentSessionAcknowledgement.IsEnabled = _model.CanChoose;
        CurrentWarning.Visibility = CurrentSessionAcknowledgement.Visibility = _model.Selected?.RequiresCurrentSessionConfirmation == true ? Visibility.Visible : Visibility.Collapsed;
        DisconnectButton.IsEnabled = _model.CanExecute;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void SyncSelection()
    {
        if (_disposed) return;
        _model.SetSearch(SearchInput.Text); _model.SelectConnection((ConnectionList.SelectedItem as NasConnectionSettingsRow)?.Connection.Id);
    }
    private void Search_Changed(object sender, TextChangedEventArgs e) { if (!_synchronizing) SyncSelection(); }
    private void Selection_Changed(object sender, SelectionChangedEventArgs e) { if (!_synchronizing) SyncSelection(); }
    private void Confirmation_Changed(object sender, RoutedEventArgs e)
    { if (!_synchronizing) { SyncSelection(); _model.Confirm(RiskAcknowledgement.IsChecked == true, CurrentSessionAcknowledgement.IsChecked == true); } }
    private async void Disconnect_Click(object sender, RoutedEventArgs e) { SyncSelection(); await _model.DisconnectAsync(); }
    public void Dispose() { if (_disposed) return; _disposed = true; _synchronizing = true; _model.Dispose(); ConnectionList.ItemsSource = null; _displayed = []; StateChanged = null; }
    private static LocalizationService L => LocalizationService.Current;
}
