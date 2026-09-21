using System.Globalization;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed record NasHardwareSettingsRow(string Title, string Value);
public sealed partial class NasHardwareSettingsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasSettingsEditViewModel<NasHardwareSettings> _reader = new();
    private bool _disposed;
    private bool _synchronizing, _valid, _changed, _pending;
    private NasHardwareSettings? _baseline;
    private MutationResult? _feedback;
    private Dictionary<Control, string>? _confirmedInputs;
    private readonly Dictionary<(NasHardwareSections Section, string Key), Control> _controls = [];
    public event Action? StateChanged;
    public bool CanSave => !_disposed && !_pending && _valid && _changed && RiskAcknowledgement.IsChecked == true &&
        InputsStillConfirmed() && _reader.CanSave;
    public bool IsBusy => _reader.IsLoading || _reader.IsSaving;
    public NasHardwareSettingsDialogContent(INasSettingsRepository repository)
    {
        _repository = repository; InitializeComponent();
        _reader.PropertyChanged += (_, _) => Refresh();
    }
    public async Task ActivateAsync()
    {
        await _reader.ActivateAsync(_repository, L.Get("NasSettingsHardwareTitle"), async token =>
        {
            await _repository.PrepareServiceSettingsAsync(token);
            var pending = await _repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Hardware, token);
            _pending = pending is not null && (pending.Counts.Unknown > 0 || pending.ErrorCategory == MutationErrorCategory.Conflict ||
                pending.Status == MutationResultStatus.CancelledBeforeSubmission);
            return await _repository.LoadHardwareSettingsAsync(token);
        }, _repository.SaveHardwareSettingsAsync, (baseline, desired, id, token) => _repository.SaveHardwareSettingsAsync(
            new NasServiceSettingsSaveRequest<NasHardwareSettings>(_repository.ProfileId, baseline, desired, id, true), token));
        CaptureBaseline();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || IsBusy) return;
        _feedback = null; await _reader.LoadAsync(); CaptureBaseline();
    }
    public async Task SaveAsync()
    {
        if (!InputsStillConfirmed())
        {
            RiskAcknowledgement.IsChecked = false; ReadFields(); return;
        }
        if (!CanSave) return;
        _feedback = null; await _reader.SaveAsync();
        if (_disposed) return;
        var result = _reader.LastResult;
        if (result?.Status is MutationResultStatus.ConfirmedSuccess or MutationResultStatus.PartialSuccess && result.Counts.Unknown == 0)
        {
            await _reader.LoadAsync(); if (_disposed) return;
            CaptureBaseline(); _feedback = result;
        }
        RiskAcknowledgement.IsChecked = false; Refresh();
    }
    private void CaptureBaseline()
    {
        if (_disposed) return;
        _baseline = _reader.Draft; _changed = false;
        _confirmedInputs = null;
        _valid = _baseline is not null && NasHardwareSettingsRules.IsValidChange(_baseline, _baseline);
        BuildEditors(); RiskAcknowledgement.IsChecked = false; Refresh();
    }
    private void BuildEditors()
    {
        _synchronizing = true; _controls.Clear(); EditorFields.Children.Clear();
        if (_baseline is not null)
        foreach (var section in Enum.GetValues<NasHardwareSections>().Where(item => item != NasHardwareSections.None && _baseline.AvailableSections.HasFlag(item)))
        foreach (var (key, value) in NasHardwareSettingsRules.Fields(_baseline, section))
        {
            var title = L.Get(FieldLabel(key));
            Control control;
            if (value is bool enabled)
            {
                var checkbox = new CheckBox { Content = title, IsChecked = enabled };
                checkbox.Checked += Fields_Changed; checkbox.Unchecked += Fields_Changed; control = checkbox;
            }
            else if (key is "dual_fan_speed" or "mode")
            {
                var choice = new ComboBox { Header = title, HorizontalAlignment = HorizontalAlignment.Stretch };
                var choices = key == "mode" ? new[] { "USB", "SNMP", "SLAVE" } : NasHardwareSettingsRules.FanModes;
                foreach (var item in choices.Append((string)value).Distinct())
                    choice.Items.Add(new ComboBoxItem { Tag = item, Content = ModeLabel(item) });
                choice.SelectedItem = choice.Items.OfType<ComboBoxItem>().First(item => (string)item.Tag == (string)value);
                choice.SelectionChanged += Selection_Changed; control = choice;
            }
            else
            {
                if (key == "led_brightness" && _baseline.LedMinimum is int minimum && _baseline.LedMaximum is int maximum)
                    title = L.Format("NasHardwareLedInput", minimum, maximum);
                var input = new TextBox { Header = title, Text = Convert.ToString(value, CultureInfo.CurrentCulture) ?? "" };
                input.TextChanged += Text_Changed; control = input;
            }
            control.Tag = key;
            _controls[(section, key)] = control; EditorFields.Children.Add(control);
        }
        _synchronizing = false;
    }
    private void Fields_Changed(object sender, RoutedEventArgs args) => ReadFields();
    private void Text_Changed(object sender, TextChangedEventArgs args) => ReadFields();
    private void Selection_Changed(object sender, SelectionChangedEventArgs args) => ReadFields();
    private void Acknowledgement_Changed(object sender, RoutedEventArgs args)
    {
        if (_synchronizing) return;
        if (RiskAcknowledgement.IsChecked == true)
        {
            ReadFields(resetConfirmation: false);
            _confirmedInputs = _controls.Values.ToDictionary(control => control, InputValue);
        }
        else _confirmedInputs = null;
        StateChanged?.Invoke();
    }
    private void ReadFields(bool resetConfirmation = true)
    {
        if (_synchronizing || _disposed || _pending || !_repository.WriteAvailability.CanSaveHardware ||
            _reader.State != NasSettingsEditState.Editing || _baseline is not { } baseline) return;
        if (resetConfirmation) { _confirmedInputs = null; RiskAcknowledgement.IsChecked = false; }
        _valid = true;
        var values = new Dictionary<(NasHardwareSections, string), object>();
        foreach (var (key, control) in _controls)
        {
            if (control is CheckBox checkbox) values[key] = checkbox.IsChecked == true;
            else if (control is ComboBox { SelectedItem: ComboBoxItem { Tag: string mode } }) values[key] = mode;
            else if (control is TextBox input)
            {
                if (NasHardwareSettingsRules.Fields(baseline, key.Section)[key.Key] is int)
                {
                    if (int.TryParse(input.Text, NumberStyles.Integer, CultureInfo.CurrentCulture, out var number)) values[key] = number;
                    else _valid = false;
                }
                else values[key] = input.Text;
            }
        }
        var desired = baseline with
        {
            PowerFailRestart = V(NasHardwareSections.PowerRecovery, "rc_power_config", baseline.PowerFailRestart),
            LedBrightness = V(NasHardwareSections.Led, "led_brightness", baseline.LedBrightness),
            FanMode = V(NasHardwareSections.Fan, "dual_fan_speed", baseline.FanMode),
        };
        if (baseline.Beep is { } beep) desired = desired with { Beep = beep with
        {
            FanFailure = V(NasHardwareSections.Beep, "fan_fail", beep.FanFailure),
            VolumeFailure = beep.VolumeFieldName is { } volume ? V(NasHardwareSections.Beep, volume, beep.VolumeFailure) : beep.VolumeFailure,
            PowerOn = V(NasHardwareSections.Beep, "poweron_beep", beep.PowerOn), PowerOff = V(NasHardwareSections.Beep, "poweroff_beep", beep.PowerOff),
            Reset = V(NasHardwareSections.Beep, "reset_beep", beep.Reset),
        } };
        if (baseline.Hibernation is { } sleep) desired = desired with { Hibernation = sleep with
        {
            ExternalDriveDeepSleep = V(NasHardwareSections.Hibernation, "eunit_deep_sleep", sleep.ExternalDriveDeepSleep),
            WakeUpLog = V(NasHardwareSections.Hibernation, "enable_log", sleep.WakeUpLog),
            SataSleep = V(NasHardwareSections.Hibernation, "sata_deep_sleep", sleep.SataSleep),
            IgnoreNetworkDiscovery = V(NasHardwareSections.Hibernation, "ignore_netbios_broadcast", sleep.IgnoreNetworkDiscovery),
            AutomaticPowerOff = V(NasHardwareSections.Hibernation, "auto_poweroff_enable", sleep.AutomaticPowerOff),
        } };
        if (baseline.Ups is { } ups) desired = desired with { Ups = ups with
        {
            Enabled = V(NasHardwareSections.Ups, "enable", ups.Enabled), Mode = V(NasHardwareSections.Ups, "mode", ups.Mode),
            DelaySeconds = V(NasHardwareSections.Ups, "delay_time", ups.DelaySeconds),
            WaitForLowBattery = V(NasHardwareSections.Ups, "ups_set_safemode_until_lowbatt", ups.WaitForLowBattery),
            ShutdownDevice = V(NasHardwareSections.Ups, "shutdown_device", ups.ShutdownDevice),
            NetworkServer = V(NasHardwareSections.Ups, "net_server_ip", ups.NetworkServer),
            SnmpServer = V(NasHardwareSections.Ups, "snmp_server_ip", ups.SnmpServer),
        } };
        _valid &= NasHardwareSettingsRules.IsValidChange(baseline, desired); _changed = desired != baseline;
        if (_changed || !_valid) _feedback = null;
        if (_valid) _reader.Draft = desired;
        Refresh();
        T V<T>(NasHardwareSections section, string key, T fallback) => values.TryGetValue((section, key), out var value) ? (T)value : fallback;
    }
    private void Refresh()
    {
        if (_disposed) return;
        var data = _reader.Draft; var rows = new List<NasHardwareSettingsRow>();
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        var error = _pending ? L.Get("NasSettingsSaveNeedsReview") : _reader.ErrorMessage;
        var result = _feedback ?? _reader.LastResult;
        if (data is not null)
        {
            if (data.FailedSections != NasHardwareSections.None) error = L.Get("NasHardwarePartial");
            else if (data.AvailableSections == NasHardwareSections.None) error = L.Get("NasSettingsUnavailable");
            Flag("NasHardwarePower", data.PowerFailRestart);
            if (data.LedBrightness is int brightness)
                Add("NasHardwareLed", data.LedMinimum is int min && data.LedMaximum is int max
                    ? L.Format("NasHardwareLedRange", brightness, min, max) : Number(brightness));
            if (data.FanMode is not null)
                Add("NasHardwareFan", L.Get(data.FanMode switch
                {
                    "highfan" => "NasHardwareFanHigh", "lowfan" => "NasHardwareFanLow",
                    "fullfan" => "NasHardwareFanFull", "coolfan" => "NasHardwareFanCool",
                    "quietfan" => "NasHardwareFanQuiet", "quietstopfan" => "NasHardwareFanStop",
                    _ => "NasHardwareFanOther",
                }));
            if (data.Beep is { } beep)
            {
                Flag("NasHardwareBeepFan", beep.FanFailure); Flag("NasHardwareBeepVolume", beep.VolumeFailure);
                Flag("NasHardwareBeepOn", beep.PowerOn); Flag("NasHardwareBeepOff", beep.PowerOff); Flag("NasHardwareBeepReset", beep.Reset);
            }
            if (data.Hibernation is { } hibernation)
            {
                Flag("NasHardwareExternalSleep", hibernation.ExternalDriveDeepSleep); Flag("NasHardwareWakeLog", hibernation.WakeUpLog);
                Flag("NasHardwareSataSleep", hibernation.SataSleep); Flag("NasHardwareIgnoreDiscovery", hibernation.IgnoreNetworkDiscovery);
                Flag("NasHardwareAutoOff", hibernation.AutomaticPowerOff);
            }
            if (data.Ups is { } ups)
            {
                Flag("NasHardwareUps", ups.Enabled);
                Add("NasHardwareUpsMode", L.Get(ups.Mode switch { "USB" => "NasHardwareUpsUsb", "SNMP" => "NasHardwareUpsSnmp", _ => "NasHardwareUpsSlave" }));
                if (ups.DelaySeconds is int delay) Add("NasHardwareUpsDelay", L.Format("NasHardwareSeconds", delay));
                Flag("NasHardwareUpsBattery", ups.WaitForLowBattery); Flag("NasHardwareUpsShutdown", ups.ShutdownDevice);
                if (ups.Mode == "SLAVE" && ups.NetworkServer is { } server) Add("NasHardwareUpsServer", server.Length == 0 ? L.Get("NasHardwareNotConfigured") : server);
                if (ups.Mode == "SNMP" && ups.SnmpServer is { } snmp) Add("NasHardwareUpsServer", snmp.Length == 0 ? L.Get("NasHardwareNotConfigured") : snmp);
            }
        }
        SettingsList.ItemsSource = rows;
        var editing = _repository.WriteAvailability.CanSaveHardware && !_pending && _reader.State == NasSettingsEditState.Editing &&
            _baseline is { FailedSections: NasHardwareSections.None };
        SettingsList.Visibility = editing ? Visibility.Collapsed : Visibility.Visible;
        Editor.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
        ReadOnlyNotice.Visibility = rows.Count > 0 && !_repository.WriteAvailability.CanSaveHardware ? Visibility.Visible : Visibility.Collapsed;
        if (result?.Status == MutationResultStatus.PartialSuccess && error is null) error = L.Get("NasFileServicePartialSave");
        var saved = result?.Status == MutationResultStatus.ConfirmedSuccess;
        StatusNotice.IsOpen = error is not null || saved; StatusNotice.Message = error ?? (saved ? L.Get("NasServiceSaved") : string.Empty);
        StatusNotice.Severity = saved && error is null ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        ValidationNotice.Visibility = editing && !_valid ? Visibility.Visible : Visibility.Collapsed;
        RiskAcknowledgement.IsEnabled = editing;
        StateChanged?.Invoke();
        void Add(string key, string value) => rows.Add(new(L.Get(key), value));
        void Flag(string key, bool? value) { if (value is bool known) Add(key, L.Get(known ? "NasSecurityEnabled" : "NasSecurityDisabled")); }
    }
    private static string Number(int value) => value.ToString(CultureInfo.CurrentCulture);
    private bool InputsStillConfirmed() => _confirmedInputs is not null &&
        _controls.Values.All(control => _confirmedInputs.TryGetValue(control, out var value) && value == InputValue(control));
    private static string InputValue(Control control) => control switch
    {
        CheckBox box => box.IsChecked == true ? "true" : "false",
        ComboBox { SelectedItem: ComboBoxItem { Tag: string value } } => value,
        TextBox text => text.Text,
        _ => string.Empty,
    };
    private static string FieldLabel(string key) => key switch
    {
        "rc_power_config" => "NasHardwarePower", "led_brightness" => "NasHardwareLed", "dual_fan_speed" => "NasHardwareFan",
        "fan_fail" => "NasHardwareBeepFan", "volume_crash" or "volume_or_cache_crash" => "NasHardwareBeepVolume",
        "poweron_beep" => "NasHardwareBeepOn", "poweroff_beep" => "NasHardwareBeepOff", "reset_beep" => "NasHardwareBeepReset",
        "eunit_deep_sleep" => "NasHardwareExternalSleep", "enable_log" => "NasHardwareWakeLog", "sata_deep_sleep" => "NasHardwareSataSleep",
        "ignore_netbios_broadcast" => "NasHardwareIgnoreDiscovery", "auto_poweroff_enable" => "NasHardwareAutoOff",
        "enable" => "NasHardwareUps", "mode" => "NasHardwareUpsMode", "delay_time" => "NasHardwareUpsDelay",
        "ups_set_safemode_until_lowbatt" => "NasHardwareUpsBattery", "shutdown_device" => "NasHardwareUpsShutdown",
        "net_server_ip" => "NasHardwareUpsNetworkServer", "snmp_server_ip" => "NasHardwareUpsSnmpServer",
        _ => "NasHardwareUpsServer",
    };
    private static string ModeLabel(string value) => L.Get(value switch
    {
        "USB" => "NasHardwareUpsUsb", "SNMP" => "NasHardwareUpsSnmp", "SLAVE" => "NasHardwareUpsSlave",
        "highfan" => "NasHardwareFanHigh", "lowfan" => "NasHardwareFanLow", "fullfan" => "NasHardwareFanFull",
        "coolfan" => "NasHardwareFanCool", "quietfan" => "NasHardwareFanQuiet", "quietstopfan" => "NasHardwareFanStop",
        _ => "NasHardwareFanOther",
    });
    public void Dispose() { if (_disposed) return; _disposed = true; _confirmedInputs = null; _reader.Dispose(); StateChanged = null; }
    private static LocalizationService L => LocalizationService.Current;
}
