using System.Globalization;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class NasSecuritySettingsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasSettingsEditViewModel<NasSecuritySettings> _reader = new();
    private NasSecuritySettings? _baseline;
    private MutationResult? _feedback;
    private bool _disposed, _synchronizing, _valid, _changed, _pending;
    public event Action? StateChanged;
    private bool Writable => _repository.WriteAvailability.CanSaveSecurity;
    public bool CanSave => !_disposed && !_pending && _valid && _changed && RiskAcknowledgement.IsChecked == true && _reader.CanSave;
    public bool IsBusy => _reader.IsLoading || _reader.IsSaving;
    public NasSecuritySettingsDialogContent(INasSettingsRepository repository)
    {
        _repository = repository; InitializeComponent();
        _reader.PropertyChanged += (_, args) => Refresh(args.PropertyName == "Draft");
    }
    public async Task ActivateAsync()
    {
        await _reader.ActivateAsync(_repository, L.Get("NasSettingsSecurityTitle"), async token =>
        {
            await _repository.PrepareServiceSettingsAsync(token);
            var pending = await _repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Security, token);
            _pending = pending is not null && (pending.Counts.Unknown > 0 || pending.ErrorCategory == MutationErrorCategory.Conflict ||
                pending.Status == MutationResultStatus.CancelledBeforeSubmission);
            return await _repository.LoadSecuritySettingsAsync(token);
        }, _repository.SaveSecuritySettingsAsync, (baseline, desired, id, token) =>
            _repository.SaveSecuritySettingsAsync(new NasServiceSettingsSaveRequest<NasSecuritySettings>(
                _repository.ProfileId, baseline, desired, id, true), token));
        CaptureBaseline();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || IsBusy) return;
        _feedback = null; RiskAcknowledgement.IsChecked = false;
        await _reader.LoadAsync(); CaptureBaseline();
    }
    public async Task SaveAsync()
    {
        if (!CanSave) return;
        _feedback = null;
        await _reader.SaveAsync();
        if (_disposed) return;
        var result = _reader.LastResult;
        if (result?.Status is MutationResultStatus.ConfirmedSuccess or MutationResultStatus.PartialSuccess && result.Counts.Unknown == 0)
        {
            await _reader.LoadAsync();
            if (_disposed) return;
            CaptureBaseline(); _feedback = result;
        }
        RiskAcknowledgement.IsChecked = false; Refresh();
    }
    private void CaptureBaseline()
    {
        if (_disposed) return;
        _baseline = _reader.Draft; _changed = false;
        _valid = _baseline is not null && NasSecuritySettingsRules.IsValidChange(_baseline, _baseline);
        RiskAcknowledgement.IsChecked = false; Refresh(true);
    }
    private void Fields_Changed(object sender, RoutedEventArgs args) => ReadFields();
    private void Text_Changed(object sender, TextChangedEventArgs args) => ReadFields();
    private void Acknowledgement_Changed(object sender, RoutedEventArgs args) { if (!_synchronizing) StateChanged?.Invoke(); }
    private void ReadFields()
    {
        if (_synchronizing || _disposed || _pending || !Writable || _reader.State != NasSettingsEditState.Editing || _baseline is not { } baseline) return;
        RiskAcknowledgement.IsChecked = false;
        var desired = baseline;
        _valid = true;
        if (baseline.AvailableSections.HasFlag(NasSecuritySections.AutoBlock))
        {
            _valid = int.TryParse(AttemptsInput.Text, NumberStyles.None, CultureInfo.CurrentCulture, out var attempts);
            _valid &= int.TryParse(MinutesInput.Text, NumberStyles.None, CultureInfo.CurrentCulture, out var minutes);
            _valid &= int.TryParse(ExpirationInput.Text, NumberStyles.None, CultureInfo.CurrentCulture, out var expiry);
            desired = desired with { AutoBlockEnabled = AutoBlockToggle.IsOn, AutoBlockFailedAttempts = attempts,
                AutoBlockWithinMinutes = minutes, AutoBlockExpiryDays = expiry };
        }
        var rows = baseline.DosProtection.Select(item => item with
        {
            Enabled = DosEditors.Items.OfType<CheckBox>().FirstOrDefault(box => (string)box.Tag == item.Id)?.IsChecked ?? item.Enabled,
        }).ToArray();
        desired = desired with { DosProtection = Array.AsReadOnly(rows), DosProtectionEnabled = NasSecuritySettingsRules.Aggregate(rows) };
        if (baseline.AvailableSections.HasFlag(NasSecuritySections.Firewall)) desired = desired with { FirewallEnabled = FirewallToggle.IsOn };
        if (baseline.AvailableSections.HasFlag(NasSecuritySections.PortScan)) desired = desired with { PortScanEnabled = PortScanToggle.IsOn };
        _valid &= NasSecuritySettingsRules.IsValidChange(baseline, desired);
        _changed = !SameValues(baseline, desired);
        if (_changed || !_valid) _feedback = null;
        if (_valid && !SameValues(_reader.Draft, desired)) _reader.Draft = desired;
        Refresh();
    }
    private static bool SameValues(NasSecuritySettings? a, NasSecuritySettings b) => a is not null &&
        a.AutoBlockEnabled == b.AutoBlockEnabled && a.AutoBlockFailedAttempts == b.AutoBlockFailedAttempts &&
        a.AutoBlockWithinMinutes == b.AutoBlockWithinMinutes && a.AutoBlockExpiryDays == b.AutoBlockExpiryDays &&
        a.FirewallEnabled == b.FirewallEnabled && a.PortScanEnabled == b.PortScanEnabled &&
        a.DosProtection.Select(item => (item.Id, item.Enabled)).SequenceEqual(b.DosProtection.Select(item => (item.Id, item.Enabled)));
    private void Refresh(bool synchronize = false)
    {
        if (_disposed || LoadingIndicator is null) return;
        var data = _reader.Draft;
        var available = data?.AvailableSections ?? NasSecuritySections.None;
        var editing = Writable && !_pending && _reader.State == NasSettingsEditState.Editing &&
            data?.FailedSections == NasSecuritySections.None && available != NasSecuritySections.None;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        var result = _feedback ?? _reader.LastResult;
        var error = _pending ? L.Get("NasSettingsSaveNeedsReview") : _reader.ErrorMessage;
        if (data is not null && data.FailedSections != NasSecuritySections.None)
            error = L.Get(available == NasSecuritySections.None ? "NasSettingsLoadError" : "NasSecurityPartialRead");
        else if (data is not null && available == NasSecuritySections.None) error = L.Get("NasSettingsUnavailable");
        if (result?.Status == MutationResultStatus.PartialSuccess && error is null) error = L.Get("NasFileServicePartialSave");
        var saved = result?.Status == MutationResultStatus.ConfirmedSuccess;
        StatusNotice.IsOpen = error is not null || saved;
        StatusNotice.Message = error ?? (saved ? L.Get("NasServiceSaved") : string.Empty);
        StatusNotice.Severity = saved && error is null ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        ReadOnlyNotice.Visibility = available != NasSecuritySections.None && !Writable ? Visibility.Visible : Visibility.Collapsed;
        AutoBlockSection.Visibility = Show(available, NasSecuritySections.AutoBlock);
        DosSection.Visibility = Show(available, NasSecuritySections.Dos);
        FirewallSection.Visibility = Show(available, NasSecuritySections.Firewall);
        PortScanSection.Visibility = Show(available, NasSecuritySections.PortScan);
        AutoBlockReadValues.Visibility = DosItems.Visibility = FirewallValue.Visibility = PortScanValue.Visibility =
            editing ? Visibility.Collapsed : Visibility.Visible;
        AutoBlockEditor.Visibility = DosEditors.Visibility = FirewallToggle.Visibility = PortScanToggle.Visibility =
            ConfirmationPanel.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
        ValidationNotice.Visibility = editing && !_valid && _baseline is not null ? Visibility.Visible : Visibility.Collapsed;
        RiskAcknowledgement.IsEnabled = editing && _valid && _changed;
        if (data is not null)
        {
            AutoBlockValue.Text = Flag(data.AutoBlockEnabled);
            AttemptsValue.Text = L.Format("NasSecurityAttempts", Number(data.AutoBlockFailedAttempts), Number(data.AutoBlockWithinMinutes));
            ExpirationValue.Text = data.AutoBlockExpiryDays == 0 ? L.Get("NasSecurityNoExpiration") : L.Format("NasSecurityExpiration", Number(data.AutoBlockExpiryDays));
            DosItems.ItemsSource = data.DosProtection.Select(item => L.Format("NasSecurityAdapter", item.Name, Flag(item.Enabled))).ToArray();
            DosEmpty.Visibility = data.DosProtection.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            FirewallValue.Text = Flag(data.FirewallEnabled); PortScanValue.Text = Flag(data.PortScanEnabled);
            ProfileValue.Text = L.Format("NasSecurityProfile", data.FirewallProfileName ?? L.Get("NasNetworkNotReported"));
            if (synchronize)
            {
                _synchronizing = true;
                AutoBlockToggle.IsOn = data.AutoBlockEnabled == true; FirewallToggle.IsOn = data.FirewallEnabled == true;
                PortScanToggle.IsOn = data.PortScanEnabled == true;
                AttemptsInput.Text = data.AutoBlockFailedAttempts?.ToString(CultureInfo.CurrentCulture) ?? "";
                MinutesInput.Text = data.AutoBlockWithinMinutes?.ToString(CultureInfo.CurrentCulture) ?? "";
                ExpirationInput.Text = data.AutoBlockExpiryDays?.ToString(CultureInfo.CurrentCulture) ?? "";
                DosEditors.Items.Clear();
                foreach (var item in data.DosProtection)
                {
                    var box = new CheckBox { Tag = item.Id, Content = item.Name, IsChecked = item.Enabled };
                    box.Checked += Fields_Changed; box.Unchecked += Fields_Changed;
                    DosEditors.Items.Add(box);
                }
                _synchronizing = false;
            }
        }
        StateChanged?.Invoke();
    }
    private static Visibility Show(NasSecuritySections available, NasSecuritySections section) => available.HasFlag(section) ? Visibility.Visible : Visibility.Collapsed;
    private static string Flag(bool? value) => L.Get(value is true ? "NasSecurityEnabled" : value is false ? "NasSecurityDisabled" : "NasNetworkNotReported");
    private static string Number(int? value) => value?.ToString(CultureInfo.CurrentCulture) ?? L.Get("NasNetworkNotReported");
    public void Dispose() { if (_disposed) return; _disposed = true; _reader.Dispose(); StateChanged = null; }
    private static LocalizationService L => LocalizationService.Current;
}
