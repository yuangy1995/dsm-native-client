using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class NasRemoteAccessDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasSettingsEditViewModel<NasRemoteAccessSettings> _reader = new();
    private NasRemoteAccessSettings? _baseline, _confirmed;
    private MutationResult? _feedback;
    private bool _disposed, _synchronizing = true, _activated, _pending;
    public event Action? StateChanged;
    public bool IsBusy => _reader.IsLoading || _reader.IsSaving;
    private bool Writable => _repository.WriteAvailability.CanSaveRemoteAccess;
    private bool Editing => !_disposed && !_pending && _reader.IsEditing && Writable;
    private bool Known(NasRemoteAccessParts part) => _baseline is { } value && value.AvailableParts.HasFlag(part) && !value.FailedParts.HasFlag(part) && NasRemoteAccessRules.Value(value, part) is not null;
    private bool CanEditRelay => Editing && Known(NasRemoteAccessParts.Relay) && (_baseline!.CanDisableRelay || _baseline.RelayEnabled == false);
    public bool CanSave => !_disposed && !_pending && _reader.CanSave && _baseline is not null && _reader.Draft is { } draft &&
        NasRemoteAccessRules.IsValidChange(_baseline, draft) && _confirmed == draft && RiskAcknowledgement.IsChecked == true;
    public NasRemoteAccessDialogContent(INasSettingsRepository repository)
    {
        _repository = repository; InitializeComponent();
        _reader.PropertyChanged += (_, args) => Refresh(args.PropertyName == "Draft"); _synchronizing = false;
    }
    public async Task ActivateAsync()
    {
        if (_disposed || _activated) return; _activated = true;
        await _reader.ActivateAsync(_repository, L.Get("NasRemoteTitle"), LoadAsync,
            (baseline, desired, id, token) => _repository.SaveRemoteAccessSettingsAsync(new(_repository.ProfileId, baseline, desired, id, true), token));
        CaptureBaseline();
    }
    private async Task<NasRemoteAccessSettings> LoadAsync(CancellationToken token)
    {
        await _repository.PrepareServiceSettingsAsync(token);
        var reviewed = await _repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.RemoteAccess, token);
        _pending = reviewed is not null && (reviewed.Counts.Unknown > 0 || reviewed.ErrorCategory == MutationErrorCategory.Conflict || reviewed.Status == MutationResultStatus.CancelledBeforeSubmission);
        if (reviewed is not null) _feedback = reviewed;
        return await _repository.LoadRemoteAccessSettingsAsync(token);
    }
    public async Task ReloadAsync()
    {
        if (_disposed || IsBusy || !_activated) return;
        _confirmed = null; await _reader.LoadAsync(); CaptureBaseline();
    }
    public async Task SaveAsync()
    {
        if (_disposed) return;
        ReadFields(); if (!CanSave) return;
        _feedback = null;
        await _reader.SaveAsync(); if (_disposed) return;
        _feedback = _reader.LastResult; _confirmed = null;
        _pending = _feedback?.Counts.Unknown > 0;
        // 成功或已明确的部分结果重新读取；未知结果保留当前快照并明确锁定，等待用户核查。
        if (_feedback is { Counts.Unknown: 0, Status: MutationResultStatus.ConfirmedSuccess or MutationResultStatus.PartialSuccess })
        { await _reader.LoadAsync(); if (_disposed) return; CaptureBaseline(); }
        Refresh(true);
    }
    private void CaptureBaseline()
    {
        if (_disposed) return; _baseline = _reader.Draft; _confirmed = null; Refresh(true);
    }
    private void ReadFields()
    {
        if (_disposed || _synchronizing || !Editing || _baseline is null) return;
        var desired = _baseline with
        {
            RelayEnabled = CanEditRelay ? RelayToggle.IsOn : _baseline.RelayEnabled,
            RouterConfigurationEnabled = Known(NasRemoteAccessParts.Router) ? RouterToggle.IsOn : _baseline.RouterConfigurationEnabled
        };
        if (desired == _reader.Draft) { Refresh(true); return; }
        _confirmed = null; _reader.Draft = desired; Refresh();
    }
    private void Fields_Changed(object sender, RoutedEventArgs e) => ReadFields();
    private void Confirm_Changed(object sender, RoutedEventArgs e)
    {
        if (_synchronizing || _disposed) return;
        var confirmed = RiskAcknowledgement.IsChecked == true; ReadFields();
        _confirmed = confirmed && Editing && _baseline is not null && _reader.Draft is { } draft && NasRemoteAccessRules.IsValidChange(_baseline, draft) ? draft : null;
        Refresh();
    }
    private void Refresh(bool fields = false)
    {
        if (_disposed) return; _synchronizing = true;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _reader.ErrorMessage is not null && (!_pending || _reader.State == NasSettingsEditState.Failed); ErrorNotice.Message = _reader.ErrorMessage ?? "";
        var result = _feedback ?? _reader.LastResult;
        FeedbackNotice.IsOpen = result is not null;
        FeedbackNotice.Severity = result?.Status == MutationResultStatus.ConfirmedSuccess ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        FeedbackNotice.Message = result is null ? "" : L.Format(result.Status switch
        {
            MutationResultStatus.ConfirmedSuccess => "NasRemoteSaved",
            MutationResultStatus.PartialSuccess => "NasRemotePartial",
            MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "NasRemoteUnknown",
            MutationResultStatus.CancelledBeforeSubmission => "NasRemoteNotSent",
            MutationResultStatus.Unsupported => "NasRemoteUnsupported",
            _ => result.ErrorCategory switch { MutationErrorCategory.Permission => "NasRemotePermission", MutationErrorCategory.Conflict => "NasRemoteChanged", _ => "NasRemoteFailed" }
        }, result.Counts.Succeeded, result.Counts.Failed, result.Counts.Unknown);
        PendingNotice.IsOpen = _pending;
        var hasSettings = _reader.Draft is not null && _baseline is not null;
        SettingsPanel.Visibility = hasSettings ? Visibility.Visible : Visibility.Collapsed;
        ReadOnlyNotice.Visibility = hasSettings && !Writable ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Visibility = !IsBusy && (_reader.IsUnsupported || hasSettings && _baseline!.AvailableParts == NasRemoteAccessParts.None && _baseline.FailedParts == NasRemoteAccessParts.None) ? Visibility.Visible : Visibility.Collapsed;
        if (fields)
        {
            var value = _pending ? _baseline : _reader.Draft;
            RelayToggle.IsOn = value?.RelayEnabled == true; RouterToggle.IsOn = value?.RouterConfigurationEnabled == true;
        }
        RelayToggle.Visibility = Known(NasRemoteAccessParts.Relay) ? Visibility.Visible : Visibility.Collapsed;
        RouterToggle.Visibility = Known(NasRemoteAccessParts.Router) ? Visibility.Visible : Visibility.Collapsed;
        RelayToggle.IsEnabled = CanEditRelay; RouterToggle.IsEnabled = Editing && Known(NasRemoteAccessParts.Router);
        RelayUnavailable.Visibility = Known(NasRemoteAccessParts.Relay) ? Visibility.Collapsed : Visibility.Visible;
        RouterUnavailable.Visibility = Known(NasRemoteAccessParts.Router) ? Visibility.Collapsed : Visibility.Visible;
        RelayUnavailable.Text = L.Get(_baseline?.FailedParts.HasFlag(NasRemoteAccessParts.Relay) == true ? "NasRemoteReadFailed" : "NasRemoteUnavailable");
        RouterUnavailable.Text = L.Get(_baseline?.FailedParts.HasFlag(NasRemoteAccessParts.Router) == true ? "NasRemoteReadFailed" : "NasRemoteUnavailable");
        RelayProtection.Visibility = _baseline?.CanDisableRelay == false ? Visibility.Visible : Visibility.Collapsed;
        RiskNotice.Visibility = RiskAcknowledgement.Visibility = Editing ? Visibility.Visible : Visibility.Collapsed;
        RiskAcknowledgement.IsEnabled = Editing && _baseline is not null && _reader.Draft is { } draft && NasRemoteAccessRules.IsValidChange(_baseline, draft);
        RiskAcknowledgement.IsChecked = _confirmed is not null && _confirmed == _reader.Draft;
        _synchronizing = false; StateChanged?.Invoke();
    }
    public void Dispose()
    {
        if (_disposed) return; _disposed = true; _synchronizing = true; _reader.Dispose();
        _baseline = _confirmed = null; _feedback = null; StateChanged = null;
    }
    private static LocalizationService L => LocalizationService.Current;
}
