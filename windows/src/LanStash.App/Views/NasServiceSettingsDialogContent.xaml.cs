using System.ComponentModel;
using System.Globalization;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class NasServiceSettingsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly bool _terminal;
    private readonly NasSettingsEditViewModel<NasTerminalSettings> _terminalEditor = new();
    private readonly NasSettingsEditViewModel<NasProxySettings> _proxyEditor = new();
    private NasTerminalSettings? _terminalBaseline;
    private NasProxySettings? _proxyBaseline;
    private bool _synchronizing;
    private bool _validInput;
    private bool _changed;
    private bool _disposed;
    private bool _activated;
    private bool _pendingReview;
    public event Action? StateChanged;

    public NasServiceSettingsDialogContent(INasSettingsRepository repository, bool terminal)
    {
        _repository = repository;
        _terminal = terminal;
        InitializeComponent();
        _terminalEditor.PropertyChanged += Editor_Changed;
        _proxyEditor.PropertyChanged += Editor_Changed;
        RiskNotice.Text = L.Get(terminal ? "NasServiceTerminalRisk" : "NasServiceProxyRisk");
        UpdateState();
    }

    private NasSettingsEditState State => _terminal ? _terminalEditor.State : _proxyEditor.State;
    public bool IsBusy => State is NasSettingsEditState.Loading or NasSettingsEditState.Saving;
    private bool WriteAvailable => _terminal ? _repository.WriteAvailability.CanSaveTerminal : _repository.WriteAvailability.CanSaveProxy;
    public bool CanSave => !_disposed && !_pendingReview && _validInput && _changed && RiskAcknowledgement.IsChecked == true &&
        (_terminal ? _terminalEditor.CanSave : _proxyEditor.CanSave);

    public async Task ActivateAsync()
    {
        if (_disposed || _activated) return;
        _activated = true;
        if (_terminal)
            await _terminalEditor.ActivateAsync(_repository, L.Get("NasSettingsTerminalTitle"),
                async token => { await PrepareAndReviewAsync(token); return await _repository.LoadTerminalSettingsAsync(token); },
                _repository.SaveTerminalSettingsAsync,
                (baseline, desired, id, token) => _repository.SaveTerminalSettingsAsync(
                    new NasServiceSettingsSaveRequest<NasTerminalSettings>(_repository.ProfileId, baseline, desired, id, true), token));
        else
            await _proxyEditor.ActivateAsync(_repository, L.Get("NasSettingsProxyTitle"),
                async token => { await PrepareAndReviewAsync(token); return await _repository.LoadProxySettingsAsync(token); },
                _repository.SaveProxySettingsAsync,
                (baseline, desired, id, token) => _repository.SaveProxySettingsAsync(
                    new NasServiceSettingsSaveRequest<NasProxySettings>(_repository.ProfileId, baseline, desired, id, true), token));
        CaptureBaseline();
    }

    public async Task ReloadAsync()
    {
        if (_disposed || IsBusy || !_activated) return;
        RiskAcknowledgement.IsChecked = false;
        if (_terminal) await _terminalEditor.LoadAsync();
        else await _proxyEditor.LoadAsync();
        CaptureBaseline();
    }

    public async Task SaveAsync()
    {
        if (!CanSave) return;
        if (_terminal) await _terminalEditor.SaveAsync();
        else await _proxyEditor.SaveAsync();
        if (_disposed) return;
        RiskAcknowledgement.IsChecked = false;
        UpdateState();
    }

    private void CaptureBaseline()
    {
        if (_disposed) return;
        _terminalBaseline = _terminalEditor.Draft;
        _proxyBaseline = _proxyEditor.Draft;
        _validInput = State == NasSettingsEditState.Editing;
        _changed = false;
        UpdateState();
    }

    private async Task PrepareAndReviewAsync(CancellationToken token)
    {
        await _repository.PrepareServiceSettingsAsync(token);
        var result = await _repository.ReviewServiceSettingsAsync(
            _terminal ? NasServiceSettingsKind.Terminal : NasServiceSettingsKind.Proxy, token);
        _pendingReview = result is not null && (result.Counts.Unknown > 0 ||
            result.ErrorCategory == MutationErrorCategory.Conflict ||
            result.Status == MutationResultStatus.CancelledBeforeSubmission);
    }

    private void Editor_Changed(object? sender, PropertyChangedEventArgs args)
    {
        if (_disposed) return;
        if (args.PropertyName == "Draft")
        {
            _synchronizing = true;
            try
            {
                if (_terminalEditor.Draft is { } terminal)
                {
                    SshToggle.IsOn = terminal.SshEnabled;
                    TelnetToggle.IsOn = terminal.TelnetEnabled;
                    SshPort.Text = terminal.SshPort?.ToString(CultureInfo.CurrentCulture) ?? string.Empty;
                    SshPort.Visibility = terminal.SshPort is null ? Visibility.Collapsed : Visibility.Visible;
                }
                if (_proxyEditor.Draft is { } proxy)
                {
                    ProxyToggle.IsOn = proxy.Enabled;
                    ProxyHost.Text = proxy.Host ?? string.Empty;
                    ProxyPort.Text = proxy.Port?.ToString(CultureInfo.CurrentCulture) ?? string.Empty;
                }
            }
            finally { _synchronizing = false; }
        }
        UpdateState();
    }

    private void Fields_Changed(object sender, RoutedEventArgs e) => ReadFields();
    private void Host_Changed(object sender, TextChangedEventArgs e) => ReadFields();
    private void Acknowledgement_Changed(object sender, RoutedEventArgs e)
    {
        if (!_synchronizing) StateChanged?.Invoke();
    }

    private void ReadFields()
    {
        if (_synchronizing || _disposed || _pendingReview || State != NasSettingsEditState.Editing || !WriteAvailable) return;
        RiskAcknowledgement.IsChecked = false;
        if (_terminal && _terminalBaseline is { } terminal)
        {
            _validInput = NasServiceSettingsInput.TryTerminal(terminal, SshToggle.IsOn, SshPort.Text,
                TelnetToggle.IsOn, out var draft);
            _changed = _validInput && draft != terminal;
            if (_validInput) _terminalEditor.Draft = draft;
        }
        else if (!_terminal && _proxyBaseline is { } proxy)
        {
            _validInput = NasServiceSettingsInput.TryProxy(proxy, ProxyToggle.IsOn, ProxyHost.Text, ProxyPort.Text, out var draft);
            _changed = _validInput && draft != proxy;
            if (_validInput) _proxyEditor.Draft = draft;
        }
        UpdateState();
    }

    private void UpdateState()
    {
        if (_disposed || LoadingIndicator is null) return;
        var hasDraft = _terminal ? _terminalEditor.Draft is not null : _proxyEditor.Draft is not null;
        var editing = State == NasSettingsEditState.Editing && WriteAvailable && !_pendingReview;
        LoadingIndicator.IsActive = IsBusy;
        LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        TerminalFields.Visibility = _terminal && hasDraft ? Visibility.Visible : Visibility.Collapsed;
        ProxyFields.Visibility = !_terminal && hasDraft ? Visibility.Visible : Visibility.Collapsed;
        SshToggle.IsEnabled = editing;
        TelnetToggle.IsEnabled = editing;
        SshPort.IsEnabled = editing;
        ProxyToggle.IsEnabled = editing;
        ProxyHost.IsEnabled = editing && ProxyToggle.IsOn;
        ProxyPort.IsEnabled = editing && ProxyToggle.IsOn;
        ReadOnlyNotice.Visibility = hasDraft && !WriteAvailable ? Visibility.Visible : Visibility.Collapsed;
        RiskNotice.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
        RiskAcknowledgement.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
        RiskAcknowledgement.IsEnabled = editing && _validInput && _changed;
        ValidationNotice.Visibility = editing && !_validInput && (_terminalBaseline is not null || _proxyBaseline is not null)
            ? Visibility.Visible : Visibility.Collapsed;
        var error = _pendingReview ? L.Get("NasSettingsSaveNeedsReview") :
            _terminal ? _terminalEditor.ErrorMessage : _proxyEditor.ErrorMessage;
        StatusNotice.IsOpen = error is not null || State is NasSettingsEditState.Saved or NasSettingsEditState.Unsupported;
        StatusNotice.Severity = State == NasSettingsEditState.Saved ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        StatusNotice.Message = error ?? (State == NasSettingsEditState.Saved ? L.Get("NasServiceSaved") : ReadOnlyNotice.Text);
        StateChanged?.Invoke();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _terminalEditor.PropertyChanged -= Editor_Changed;
        _proxyEditor.PropertyChanged -= Editor_Changed;
        _terminalEditor.Dispose();
        _proxyEditor.Dispose();
        StateChanged = null;
    }

    private static LocalizationService L => LocalizationService.Current;
}
