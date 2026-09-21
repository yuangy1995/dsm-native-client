using System.Globalization;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed record NasNetworkSettingsRow(string Name, string Mode, string StaticSettings, string Advanced, Visibility StaticVisibility)
{
    public NasEthernetInterface? Interface { get; init; }
}

public sealed partial class NasNetworkSettingsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasSettingsEditViewModel<NasEthernetSnapshot> _reader = new();
    private readonly NasSettingsEditViewModel<NasEthernetInterface> _editor = new();
    private NasEthernetInterface? _baseline;
    private NasEthernetRecoveryInfo? _recovery;
    private MutationResult? _feedback;
    private bool _disposed, _synchronizing, _valid, _changed;
    public event Action? StateChanged;
    public bool CanSave => !_disposed && _recovery is null && _valid && _changed &&
        RiskAcknowledgement.IsChecked == true && _editor.CanSave;
    public bool IsBusy => _reader.IsLoading || _editor.IsLoading || _editor.IsSaving;
    private bool Writable => _repository.WriteAvailability.CanSaveNetwork;

    public NasNetworkSettingsDialogContent(INasSettingsRepository repository)
    {
        _repository = repository;
        InitializeComponent();
        _reader.PropertyChanged += (_, args) => { if (args.PropertyName == "Draft") RefreshList(); Refresh(); };
        _editor.PropertyChanged += (_, args) => { if (args.PropertyName == "Draft") PopulateEditor(); Refresh(); };
    }
    public Task ActivateAsync() => _reader.ActivateAsync(_repository, L.Get("NasSettingsNetworkTitle"), async token =>
    {
        _recovery = await _repository.GetEthernetRecoveryAsync(token);
        // 尚未重新登录时不探测新地址，防止旧会话出现在任何新地址请求中。
        if (_recovery?.RequiresSignIn == true) return new NasEthernetSnapshot([], 0);
        if (_recovery is { RequiresSameNasConfirmation: false })
        {
            _feedback = await _repository.ReviewEthernetSettingsAsync(cancellationToken: token);
            _recovery = await _repository.GetEthernetRecoveryAsync(token);
        }
        await _repository.PrepareServiceSettingsAsync(token);
        return await _repository.LoadEthernetSnapshotAsync(token);
    }, (_, _) => Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "saveNetwork",
        false, false, new(0, 1, 0), MutationErrorCategory.Unsupported)));

    public async Task ReloadAsync()
    {
        if (_disposed || IsBusy) return;
        _feedback = null; _baseline = null; _editor.Deactivate();
        SameNasConfirmation.IsChecked = false;
        await _reader.LoadAsync();
    }
    public async Task SaveAsync()
    {
        if (!CanSave) return;
        await _editor.SaveAsync();
        if (_disposed) return;
        _feedback = _editor.LastResult;
        _recovery = await _repository.GetEthernetRecoveryAsync();
        if (_feedback?.Status == MutationResultStatus.ConfirmedSuccess)
        {
            _baseline = null; _editor.Deactivate(); await _reader.LoadAsync();
        }
        RiskAcknowledgement.IsChecked = false; Refresh();
    }
    private async void Review_Click(object sender, RoutedEventArgs args)
    {
        if (_disposed || IsBusy || _recovery?.RequiresSignIn == true || SameNasConfirmation.IsChecked != true) return;
        _feedback = await _repository.ReviewEthernetSettingsAsync(sameNasConfirmed: true);
        if (_disposed) return;
        SameNasConfirmation.IsChecked = false;
        await _reader.LoadAsync();
    }
    private async void Interface_Changed(object sender, SelectionChangedEventArgs args)
    {
        if (_synchronizing || IsBusy || !Writable || _recovery is not null) return;
        if (Interfaces.SelectedItem is not NasNetworkSettingsRow { Interface: { } item }) return;
        _baseline = null; _valid = false; _changed = false; _feedback = null;
        _editor.Deactivate();
        if (!NasEthernetSettingsRules.IsComplete(item)) { Refresh(); return; }
        await _editor.ActivateAsync(_repository, item.Name, _ => Task.FromResult(item),
            (_, _) => Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "saveNetwork", false, false, new(0, 1, 0))),
            (baseline, desired, id, token) => _repository.SaveEthernetSettingsAsync(new(_repository.ProfileId, baseline, desired, id, true), token));
        if (_disposed) return;
        _baseline = _editor.Draft; _valid = _baseline is not null && NasEthernetSettingsRules.IsValid(_baseline);
        RiskAcknowledgement.IsChecked = false; Refresh();
    }
    private void Fields_Changed(object sender, RoutedEventArgs args) => ReadFields();
    private void Text_Changed(object sender, TextChangedEventArgs args) => ReadFields();
    private void Acknowledgement_Changed(object sender, RoutedEventArgs args) { if (!_synchronizing) StateChanged?.Invoke(); }
    private void ReadFields()
    {
        if (_synchronizing || _disposed || _baseline is null || _editor.State != NasSettingsEditState.Editing || _recovery is not null) return;
        RiskAcknowledgement.IsChecked = false;
        _valid = int.TryParse(Mtu.Text, NumberStyles.None, CultureInfo.CurrentCulture, out var mtu);
        int? vlan = null;
        if (Vlan.IsChecked == true)
        {
            if (int.TryParse(VlanId.Text, NumberStyles.None, CultureInfo.CurrentCulture, out var parsed)) vlan = parsed;
            else _valid = false;
        }
        var desired = _baseline with
        {
            DhcpEnabled = Dhcp.IsOn, IpAddress = Address.Text.Trim(), SubnetMask = Mask.Text.Trim(),
            Gateway = Gateway.Text.Trim(), ReportedDns = Dns.Text.Trim(),
            DnsServers = Array.AsReadOnly(Dns.Text.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)),
            Mtu = mtu, IsDefaultGateway = DefaultGateway.IsChecked == true, VlanEnabled = Vlan.IsChecked == true, VlanId = vlan,
        };
        _valid &= NasEthernetSettingsRules.IsValid(desired);
        _changed = desired.DhcpEnabled != _baseline.DhcpEnabled || desired.Mtu != _baseline.Mtu ||
            desired.IsDefaultGateway != _baseline.IsDefaultGateway || desired.VlanEnabled != _baseline.VlanEnabled ||
            desired.VlanEnabled == true && desired.VlanId != _baseline.VlanId ||
            !desired.DhcpEnabled && (desired.IpAddress != _baseline.IpAddress || desired.SubnetMask != _baseline.SubnetMask ||
                desired.Gateway != _baseline.Gateway || desired.ReportedDns != _baseline.ReportedDns);
        if (_changed) _feedback = null;
        if (_valid && !SameFields(_editor.Draft, desired)) _editor.Draft = desired;
        Refresh();
    }
    private static bool SameFields(NasEthernetInterface? a, NasEthernetInterface b) => a is not null &&
        a.DhcpEnabled == b.DhcpEnabled && a.Mtu == b.Mtu && a.IsDefaultGateway == b.IsDefaultGateway &&
        a.VlanEnabled == b.VlanEnabled && a.VlanId == b.VlanId && a.IpAddress == b.IpAddress &&
        a.SubnetMask == b.SubnetMask && a.Gateway == b.Gateway && a.ReportedDns == b.ReportedDns;
    private void PopulateEditor()
    {
        if (_disposed || _editor.Draft is not { } item) return;
        _synchronizing = true;
        Dhcp.IsOn = item.DhcpEnabled; Address.Text = item.IpAddress ?? ""; Mask.Text = item.SubnetMask ?? "";
        Gateway.Text = item.Gateway ?? ""; Dns.Text = item.ReportedDns ?? "";
        DefaultGateway.IsChecked = item.IsDefaultGateway; Vlan.IsChecked = item.VlanEnabled;
        Mtu.Text = item.Mtu?.ToString(CultureInfo.CurrentCulture) ?? "";
        VlanId.Text = item.VlanId?.ToString(CultureInfo.CurrentCulture) ?? "";
        _synchronizing = false;
    }
    private void RefreshList()
    {
        if (_disposed) return;
        _synchronizing = true;
        Interfaces.ItemsSource = _reader.Draft?.Interfaces.Select(item => new NasNetworkSettingsRow(item.Name,
            L.Get(item.DhcpEnabled ? "NasNetworkAutomatic" : "NasNetworkStatic"),
            L.Format("NasNetworkStaticDetails", Provided(item.IpAddress), Provided(item.SubnetMask), Provided(item.Gateway), Provided(item.ReportedDns)),
            L.Format("NasNetworkAdvanced", item.Mtu?.ToString(CultureInfo.CurrentCulture) ?? L.Get("NasNetworkNotReported"),
                Flag(item.IsDefaultGateway), item.VlanEnabled == false ? L.Get("NasNetworkNo") :
                    item.VlanEnabled == true && item.VlanId is int vlan ? vlan.ToString(CultureInfo.CurrentCulture) : L.Get("NasNetworkNotReported")),
            item.DhcpEnabled ? Visibility.Collapsed : Visibility.Visible) { Interface = item }).ToArray();
        _synchronizing = false;
    }
    private void Refresh()
    {
        if (_disposed || LoadingIndicator is null) return;
        var data = _reader.Draft;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        var error = _reader.ErrorMessage ?? _editor.ErrorMessage;
        if (data?.FailedInterfaces > 0) error = L.Format("NasNetworkPartial", data.FailedInterfaces);
        if (_recovery is not null) error = L.Get(_recovery.RequiresSignIn ? "NasNetworkFreshSignIn" :
            _recovery.RequiresSameNasConfirmation ? "NasNetworkConfirmReconnect" : "NasNetworkUnverified");
        if (Interfaces.SelectedItem is NasNetworkSettingsRow { Interface: { } selected } && !NasEthernetSettingsRules.IsComplete(selected))
            error = L.Get("NasNetworkIncomplete");
        var saved = _feedback?.Status == MutationResultStatus.ConfirmedSuccess;
        StatusNotice.IsOpen = error is not null || saved;
        StatusNotice.Message = error ?? (saved ? L.Get("NasNetworkSaved") : string.Empty);
        StatusNotice.Severity = saved && error is null ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        ReadOnlyNotice.Visibility = data?.Interfaces.Count > 0 && !Writable ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Visibility = !IsBusy && _recovery is null && data is { Interfaces.Count: 0, FailedInterfaces: 0 } ? Visibility.Visible : Visibility.Collapsed;
        Interfaces.SelectionMode = Writable && _recovery is null ? ListViewSelectionMode.Single : ListViewSelectionMode.None;
        Interfaces.IsEnabled = !IsBusy;
        RecoveryPanel.Visibility = _recovery is { RequiresSignIn: false, RequiresSameNasConfirmation: true } ? Visibility.Visible : Visibility.Collapsed;
        Editor.Visibility = _baseline is not null && _recovery is null && Writable && _editor.State == NasSettingsEditState.Editing ? Visibility.Visible : Visibility.Collapsed;
        StaticFields.Visibility = Dhcp.IsOn ? Visibility.Collapsed : Visibility.Visible;
        VlanId.Visibility = Vlan.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        ValidationNotice.Visibility = _baseline is not null && !_valid ? Visibility.Visible : Visibility.Collapsed;
        RiskAcknowledgement.IsEnabled = _valid && _changed;
        StateChanged?.Invoke();
    }
    private static string Provided(string? value) => string.IsNullOrWhiteSpace(value) ? L.Get("NasNetworkNotReported") : value;
    private static string Flag(bool? value) => L.Get(value is true ? "NasNetworkYes" : value is false ? "NasNetworkNo" : "NasNetworkNotReported");
    public void Dispose() { if (_disposed) return; _disposed = true; _reader.Dispose(); _editor.Dispose(); StateChanged = null; }
    private static LocalizationService L => LocalizationService.Current;
}
