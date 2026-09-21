using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed record NasDdnsSettingsRow(string Title, string Details, string State, NasDDNSRecord Record);
public sealed partial class NasDdnsSettingsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasDdnsViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    private NasDDNSDraft? _displayedDraft;
    private NasDDNSRecord[] _displayedRecords = [];
    public event Action? StateChanged;
    public bool CanSave => !_disposed && _model.CanSave && RiskAcknowledgement.IsChecked == true;
    public bool IsBusy => _model.IsBusy;
    public NasDdnsSettingsDialogContent(INasSettingsRepository repository)
    {
        _repository = repository; InitializeComponent();
        EmptyNotice.Text = L.Get("NasSettingsDdnsNone");
        ValidationNotice.Text = L.Get("NasSettingsDdnsValidationError");
        _model.PropertyChanged += (_, _) => Refresh();
        ProviderList.ItemsSource = _model.Providers;
        ProviderChoice.ItemsSource = _model.Providers;
        _synchronizing = false;
    }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task ReloadAsync() => _disposed ? Task.CompletedTask : _model.RefreshAsync();
    public async Task SaveAsync()
    {
        ReadFields();
        if (CanSave) await _model.ExecuteConfirmedAsync();
    }
    private void Refresh()
    {
        if (_disposed) return;
        _synchronizing = true;
        var selected = SelectedRecord;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        StatusNotice.IsOpen = _model.ErrorMessage is not null; StatusNotice.Message = _model.ErrorMessage ?? string.Empty;
        FeedbackNotice.IsOpen = _model.FeedbackMessage is not null; FeedbackNotice.Message = _model.FeedbackMessage ?? string.Empty;
        FeedbackNotice.Severity = _model.WasSuccessful ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        ReadOnlyNotice.Visibility = _model.IsUnsupported ? Visibility.Visible : Visibility.Collapsed;
        ActionToolbar.Visibility = _model.IsUnsupported ? Visibility.Collapsed : Visibility.Visible;
        EmptyNotice.Visibility = !IsBusy && _model.ErrorMessage is null && _model.Records.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (!_displayedRecords.SequenceEqual(_model.Records))
        {
        _displayedRecords = _model.Records.ToArray();
        RecordList.ItemsSource = _displayedRecords.Select(record => new NasDdnsSettingsRow(
            L.Format("NasDdnsRecordTitle", record.Hostname, _model.Providers.FirstOrDefault(provider => provider.Id == record.ProviderId)?.Name ?? record.ProviderId),
            L.Format("NasDdnsRecordDetails", record.Username, Address(record.ExternalIp), Address(record.Ipv6)),
            L.Format("NasDdnsRecordState", L.Get(record.IsEnabled ? "NasSecurityEnabled" : "NasSecurityDisabled"),
                L.Get(record.Heartbeat ? "NasSecurityEnabled" : "NasSecurityDisabled")), record)).ToArray();
        RecordList.SelectedItem = RecordList.Items.OfType<NasDdnsSettingsRow>().FirstOrDefault(row => row.Record.ProviderId == selected?.ProviderId);
        }
        if (!ReferenceEquals(_displayedDraft, _model.Draft))
        {
            _displayedDraft = _model.Draft;
            ProviderChoice.SelectedItem = _model.Providers.FirstOrDefault(p => p.Id == _model.Draft.ProviderId) ??
                (!_model.IsExisting ? _model.Providers.FirstOrDefault(p => !_model.Records.Any(r => r.ProviderId == p.Id)) : null);
            if (!_model.IsExisting) _model.Draft.ProviderId = (ProviderChoice.SelectedItem as NasDDNSProvider)?.Id;
            HostnameInput.Text = _model.Draft.Hostname ?? ""; UsernameInput.Text = _model.Draft.Username ?? "";
            EnabledInput.IsChecked = _model.Draft.IsEnabled; HeartbeatInput.IsChecked = _model.Draft.Heartbeat;
        }
        PasswordInput.Password = _model.Draft.Password ?? "";
        PasswordInput.Visibility = _model.Draft.ProviderId == "Synology" ? Visibility.Collapsed : Visibility.Visible;
        EditorPanel.Visibility = _model.IsEditing ? Visibility.Visible : Visibility.Collapsed;
        foreach (var control in new Control[] { HostnameInput, UsernameInput, PasswordInput, EnabledInput, HeartbeatInput, SaveChoiceButton, TestButton, CancelEditButton })
            control.IsEnabled = _model.CanEdit;
        ProviderChoice.IsEnabled = _model.CanEdit && !_model.IsExisting;
        PasswordNotice.Visibility = _model.IsExisting && _model.Draft.ProviderId != "Synology" ? Visibility.Visible : Visibility.Collapsed;
        CreateButton.IsEnabled = _model.CanEdit && _model.Providers.Any(p => !_model.Records.Any(r => r.ProviderId == p.Id));
        EditButton.IsEnabled = DeleteButton.IsEnabled = _model.CanEdit && SelectedRecord is not null;
        UpdateButton.IsEnabled = _model.CanEdit && _model.Records.Count > 0;
        RecordList.IsEnabled = !IsBusy;
        ConfirmationPanel.Visibility = _model.SelectedAction is not null ? Visibility.Visible : Visibility.Collapsed;
        ConfirmationText.Text = _model.SelectedAction switch
        {
            NasDdnsAction.Save => L.Get("NasDdnsConfirmSave"), NasDdnsAction.Test => L.Get("NasDdnsConfirmTest"),
            NasDdnsAction.Delete => L.Format("NasDdnsConfirmDelete", SelectedRecord?.Hostname ?? ""),
            NasDdnsAction.UpdateAddress => L.Get("NasDdnsConfirmUpdate"), _ => "",
        };
        RiskAcknowledgement.IsEnabled = _model.CanEdit;
        ValidationNotice.Visibility = _model.CanEdit && _model.SelectedAction is not null && !_model.HasValidAction ? Visibility.Visible : Visibility.Collapsed;
        if (!_model.CanExecute) RiskAcknowledgement.IsChecked = false;
        ActionButton.Visibility = _model.SelectedAction is NasDdnsAction.Test or NasDdnsAction.Delete or NasDdnsAction.UpdateAddress ? Visibility.Visible : Visibility.Collapsed;
        ActionButton.Content = L.Get(_model.SelectedAction switch
        {
            NasDdnsAction.Test => "NasSettingsDdnsTest", NasDdnsAction.Delete => "NasDdnsDeleteAction", _ => "NasDdnsUpdateAction",
        });
        ActionButton.IsEnabled = _model.CanExecute;
        _synchronizing = false;
        StateChanged?.Invoke();
    }
    private NasDDNSRecord? SelectedRecord => (RecordList.SelectedItem as NasDdnsSettingsRow)?.Record;
    private void ReadFields()
    {
        if (_disposed || _synchronizing || !_model.IsEditing || IsBusy) return;
        var draft = _model.Draft; var provider = (ProviderChoice.SelectedItem as NasDDNSProvider)?.Id;
        if (draft.ProviderId == provider && draft.Hostname == HostnameInput.Text && draft.Username == UsernameInput.Text &&
            (draft.Password ?? "") == PasswordInput.Password && draft.IsEnabled == (EnabledInput.IsChecked == true) &&
            draft.Heartbeat == (HeartbeatInput.IsChecked == true)) return;
        draft.ProviderId = provider; draft.Hostname = HostnameInput.Text; draft.Username = UsernameInput.Text;
        draft.Password = provider == "Synology" ? null : PasswordInput.Password; draft.IsEnabled = EnabledInput.IsChecked == true; draft.Heartbeat = HeartbeatInput.IsChecked == true;
        _model.DraftChanged(); RiskAcknowledgement.IsChecked = false;
    }
    private void Create_Click(object sender, RoutedEventArgs e) { if (_model.CanEdit) _model.BeginCreate(); }
    private void Edit_Click(object sender, RoutedEventArgs e) { if (_model.CanEdit && SelectedRecord is { } record) _model.BeginEdit(record); }
    private void CancelEdit_Click(object sender, RoutedEventArgs e) => _model.CancelEdit();
    private void Delete_Click(object sender, RoutedEventArgs e)
    { if (_model.CanEdit && SelectedRecord is { } record) { _model.CancelEdit(); _model.SelectAction(NasDdnsAction.Delete, record); } }
    private void Update_Click(object sender, RoutedEventArgs e)
    { if (_model.CanEdit) { _model.CancelEdit(); _model.SelectAction(NasDdnsAction.UpdateAddress); } }
    private void SaveChoice_Click(object sender, RoutedEventArgs e) { ReadFields(); _model.SelectAction(NasDdnsAction.Save); }
    private void TestChoice_Click(object sender, RoutedEventArgs e) { ReadFields(); _model.SelectAction(NasDdnsAction.Test); }
    private async void Execute_Click(object sender, RoutedEventArgs e)
    { ReadFields(); if (_model.SelectedAction != NasDdnsAction.Save) await _model.ExecuteConfirmedAsync(); }
    private void Risk_Changed(object sender, RoutedEventArgs e)
    {
        if (_synchronizing || _disposed) return;
        var checkedNow = RiskAcknowledgement.IsChecked == true;
        ReadFields();
        if (checkedNow) _model.ConfirmAction(); else _model.InvalidateConfirmation();
        _synchronizing = true; RiskAcknowledgement.IsChecked = _model.CanExecute; _synchronizing = false;
        Refresh();
    }
    private void Record_Changed(object sender, SelectionChangedEventArgs e) { if (!_synchronizing) _model.CancelEdit(); }
    private void Provider_Changed(object sender, SelectionChangedEventArgs e) => ReadFields();
    private void Text_Changed(object sender, TextChangedEventArgs e) => ReadFields();
    private void Password_Changed(object sender, RoutedEventArgs e) => ReadFields();
    private void Fields_Changed(object sender, RoutedEventArgs e) => ReadFields();
    private static string Address(string? value) => string.IsNullOrWhiteSpace(value) || value is "0.0.0.0" or "::" or "0:0:0:0:0:0:0:0"
        ? L.Get("NasNetworkNotReported") : value;
    public void Dispose()
    {
        if (_disposed) return; _disposed = true; _synchronizing = true;
        PasswordInput.Password = ""; _model.Dispose(); _displayedDraft = null; _displayedRecords = []; StateChanged = null;
    }
    private static LocalizationService L => LocalizationService.Current;
}
