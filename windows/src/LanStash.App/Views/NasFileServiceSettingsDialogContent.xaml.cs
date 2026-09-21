using System.Globalization;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class NasFileServiceSettingsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasSettingsEditViewModel<NasFileServiceSettings> _reader = new();
    private NasFileServiceSettings? _baseline;
    private MutationResult? _saveFeedback;
    private bool _disposed, _synchronizing, _valid, _changed, _pendingReview;
    public event Action? StateChanged;
    private bool WriteAvailable => _repository.WriteAvailability.CanSaveFileService;
    public bool CanSave => !_disposed && !_pendingReview && _valid && _changed &&
        RiskAcknowledgement.IsChecked == true && _reader.CanSave;
    public bool IsBusy => _reader.IsLoading || _reader.IsSaving;

    public NasFileServiceSettingsDialogContent(INasSettingsRepository repository)
    {
        _repository = repository;
        InitializeComponent();
        _reader.PropertyChanged += (_, args) => RefreshFields(args.PropertyName == "Draft");
    }

    public async Task ActivateAsync()
    {
        await _reader.ActivateAsync(_repository, L.Get("NasSettingsFileServiceTitle"), async token =>
        {
            await _repository.PrepareServiceSettingsAsync(token);
            var pending = await _repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.FileServices, token);
            _pendingReview = pending is not null && (pending.Counts.Unknown > 0 ||
                pending.ErrorCategory == MutationErrorCategory.Conflict || pending.Status == MutationResultStatus.CancelledBeforeSubmission);
            return await _repository.LoadFileServiceSettingsAsync(token);
        }, _repository.SaveFileServiceSettingsAsync, (baseline, desired, id, token) =>
            _repository.SaveFileServiceSettingsAsync(new NasServiceSettingsSaveRequest<NasFileServiceSettings>(
                _repository.ProfileId, baseline, desired, id, true), token));
        CaptureBaseline();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || IsBusy) return;
        RiskAcknowledgement.IsChecked = false;
        _saveFeedback = null;
        await _reader.LoadAsync();
        CaptureBaseline();
    }
    public async Task SaveAsync()
    {
        if (!CanSave) return;
        _saveFeedback = null;
        await _reader.SaveAsync();
        if (_disposed) return;
        var result = _reader.LastResult;
        if (result?.Status is MutationResultStatus.ConfirmedSuccess or MutationResultStatus.PartialSuccess &&
            result.Counts.Unknown == 0)
        {
            // 与 macOS 模型一致，已知保存结果后更新实际值；不能让未生效草稿冒充当前设置。
            await _reader.LoadAsync();
            if (_disposed) return;
            CaptureBaseline();
            _saveFeedback = result;
        }
        RiskAcknowledgement.IsChecked = false;
        RefreshFields();
    }
    private void CaptureBaseline()
    {
        if (_disposed) return;
        _baseline = _reader.Draft;
        _valid = _baseline is not null && NasFileServiceSettingsRules.IsValidChange(_baseline, _baseline);
        _changed = false;
        RefreshFields();
    }

    private void Fields_Changed(object sender, RoutedEventArgs e) => ReadFields();
    private void Port_Changed(object sender, TextChangedEventArgs e) => ReadFields();
    private void Acknowledgement_Changed(object sender, RoutedEventArgs e)
    {
        if (!_synchronizing) StateChanged?.Invoke();
    }
    private void ReadFields()
    {
        if (_synchronizing || _disposed || _pendingReview || !WriteAvailable ||
            _reader.State != NasSettingsEditState.Editing || _baseline is not { } baseline) return;
        RiskAcknowledgement.IsChecked = false;
        var available = baseline.AvailableFields;
        var ftpPort = baseline.FtpPort; var sftpPort = baseline.SftpPort;
        _valid = ReadPort(FtpPort, NasFileServiceFields.FtpPort, ref ftpPort) &&
            ReadPort(SftpPort, NasFileServiceFields.SftpPort, ref sftpPort);
        var desired = baseline with
        {
            SmbEnabled = Switch(Smb, NasFileServiceFields.Smb, baseline.SmbEnabled),
            NfsEnabled = Switch(Nfs, NasFileServiceFields.Nfs, baseline.NfsEnabled),
            FtpEnabled = Switch(Ftp, NasFileServiceFields.Ftp, baseline.FtpEnabled),
            FtpsEnabled = Switch(Ftps, NasFileServiceFields.Ftps, baseline.FtpsEnabled), FtpPort = ftpPort,
            SftpEnabled = Switch(Sftp, NasFileServiceFields.Sftp, baseline.SftpEnabled), SftpPort = sftpPort,
            SsdpEnabled = Switch(Ssdp, NasFileServiceFields.Ssdp, baseline.SsdpEnabled),
            BonjourEnabled = Switch(Bonjour, NasFileServiceFields.Bonjour, baseline.BonjourEnabled),
            TimeMachineEnabled = Switch(TimeMachine, NasFileServiceFields.TimeMachine, baseline.TimeMachineEnabled),
        };
        _valid &= NasFileServiceSettingsRules.IsValidChange(baseline, desired);
        _changed = _valid && desired != baseline;
        if (_changed || !_valid) _saveFeedback = null;
        if (_valid) _reader.Draft = desired;
        RefreshFields();
        bool Switch(ToggleSwitch control, NasFileServiceFields field, bool fallback) =>
            available.HasFlag(field) ? control.IsOn : fallback;
        bool ReadPort(TextBox control, NasFileServiceFields field, ref int? port)
        {
            if (!available.HasFlag(field)) return true;
            if (!int.TryParse(control.Text, NumberStyles.None, CultureInfo.CurrentCulture, out var parsed) ||
                parsed is < 1 or > 65535) return false;
            port = parsed; return true;
        }
    }

    private void RefreshFields(bool synchronize = false)
    {
        if (_disposed || LoadingIndicator is null) return;
        var data = _reader.Draft;
        var available = data?.AvailableFields ?? NasFileServiceFields.None;
        var editing = _reader.State == NasSettingsEditState.Editing && WriteAvailable && !_pendingReview &&
            data?.FailedFields == NasFileServiceFields.None;
        LoadingIndicator.IsActive = IsBusy;
        LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        Fields.Visibility = !_reader.IsLoading && available != NasFileServiceFields.None ? Visibility.Visible : Visibility.Collapsed;
        ReadOnlyNotice.Visibility = Fields.Visibility == Visibility.Visible && !WriteAvailable ? Visibility.Visible : Visibility.Collapsed;
        RiskNotice.Visibility = RiskAcknowledgement.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
        RiskAcknowledgement.IsEnabled = editing && _valid && _changed;
        ValidationNotice.Visibility = editing && _baseline is not null && !_valid ? Visibility.Visible : Visibility.Collapsed;
        var error = _pendingReview ? L.Get("NasSettingsSaveNeedsReview") : _reader.ErrorMessage;
        var result = _saveFeedback ?? _reader.LastResult;
        if (result?.Status == MutationResultStatus.PartialSuccess && error is null) error = L.Get("NasFileServicePartialSave");
        if (data is not null && data.FailedFields != NasFileServiceFields.None)
            error = L.Get(available == NasFileServiceFields.None ? "NasSettingsLoadError" : "NasFileServicePartialRead");
        else if (data is not null && available == NasFileServiceFields.None) error = L.Get("NasSettingsUnavailable");
        var saved = result?.Status == MutationResultStatus.ConfirmedSuccess;
        StatusNotice.IsOpen = error is not null || saved;
        StatusNotice.Message = error ?? (saved ? L.Get("NasServiceSaved") : string.Empty);
        StatusNotice.Severity = saved && error is null ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        if (data is not null)
        {
            _synchronizing = true;
            try
            {
                Set(Smb, NasFileServiceFields.Smb, data.SmbEnabled); Set(Nfs, NasFileServiceFields.Nfs, data.NfsEnabled);
                Set(Ftp, NasFileServiceFields.Ftp, data.FtpEnabled); Set(Ftps, NasFileServiceFields.Ftps, data.FtpsEnabled);
                Set(Sftp, NasFileServiceFields.Sftp, data.SftpEnabled); Set(Ssdp, NasFileServiceFields.Ssdp, data.SsdpEnabled);
                Set(Bonjour, NasFileServiceFields.Bonjour, data.BonjourEnabled); Set(TimeMachine, NasFileServiceFields.TimeMachine, data.TimeMachineEnabled);
                Port(FtpPort, NasFileServiceFields.FtpPort, data.FtpPort); Port(SftpPort, NasFileServiceFields.SftpPort, data.SftpPort);
            }
            finally { _synchronizing = false; }
        }
        StateChanged?.Invoke();
        void Set(ToggleSwitch control, NasFileServiceFields field, bool enabled)
        {
            control.Visibility = available.HasFlag(field) ? Visibility.Visible : Visibility.Collapsed;
            control.IsEnabled = editing;
            if (synchronize) control.IsOn = enabled;
        }
        void Port(TextBox control, NasFileServiceFields field, int? value)
        {
            control.Visibility = available.HasFlag(field) ? Visibility.Visible : Visibility.Collapsed;
            control.IsReadOnly = !editing;
            if (synchronize) control.Text = value?.ToString(CultureInfo.CurrentCulture) ?? string.Empty;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; _reader.Dispose(); StateChanged = null;
    }
    private static LocalizationService L => LocalizationService.Current;
}
