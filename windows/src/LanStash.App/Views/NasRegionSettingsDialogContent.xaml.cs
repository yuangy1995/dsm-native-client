using System.Globalization;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class NasRegionSettingsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasSettingsEditViewModel<NasRegionSettings> _reader = new();
    private NasRegionSettings? _baseline;
    private MutationResult? _feedback;
    private DateTime? _editedTime;
    private bool _disposed, _synchronizing, _valid, _changed, _pending;
    public event Action? StateChanged;
    public bool CanSave => !_disposed && !_pending && _valid && _changed && RiskAcknowledgement.IsChecked == true && _reader.CanSave;
    public bool IsBusy => _reader.IsLoading || _reader.IsSaving;
    private bool Writable => _repository.WriteAvailability.CanSaveRegion;

    public NasRegionSettingsDialogContent(INasSettingsRepository repository)
    {
        _repository = repository;
        InitializeComponent();
        _reader.PropertyChanged += (_, args) => Refresh(args.PropertyName == "Draft");
    }
    public async Task ActivateAsync()
    {
        await _reader.ActivateAsync(_repository, L.Get("NasSettingsRegionTitle"), async token =>
        {
            await _repository.PrepareServiceSettingsAsync(token);
            var pending = await _repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Region, token);
            _pending = pending is not null && (pending.Counts.Unknown > 0 || pending.ErrorCategory == MutationErrorCategory.Conflict ||
                pending.Status == MutationResultStatus.CancelledBeforeSubmission);
            return await _repository.LoadRegionSettingsAsync(token);
        }, _repository.SaveRegionSettingsAsync, (baseline, desired, id, token) =>
            _repository.SaveRegionSettingsAsync(new NasRegionSettingsSaveRequest(_repository.ProfileId, baseline, desired, id, true, _editedTime), token));
        CaptureBaseline();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || IsBusy) return;
        _feedback = null;
        await _reader.LoadAsync();
        CaptureBaseline();
    }
    public async Task SaveAsync()
    {
        if (!CanSave) return;
        _feedback = null;
        await _reader.SaveAsync();
        if (_disposed) return;
        var result = _reader.LastResult;
        // 校时无法独立查询，保留其部分反馈；重新读取只更新配置，不会再次发 sync。
        if (result is not null && (result.Counts.Unknown == 0 || result.DiagnosticTag is "region.sync.unverified" or "region.sync.failed"))
        {
            await _reader.LoadAsync();
            if (_disposed) return;
            CaptureBaseline(); _feedback = result;
        }
        RiskAcknowledgement.IsChecked = false;
        Refresh();
    }
    private void CaptureBaseline()
    {
        if (_disposed) return;
        _baseline = _reader.Draft; _editedTime = null; _changed = false;
        _valid = _baseline is not null && NasRegionSettingsRules.IsValid(_baseline, null);
        _synchronizing = true;
        EditClock.IsChecked = false; NewDate.SelectedDate = null; NewTime.SelectedTime = null;
        RiskAcknowledgement.IsChecked = false;
        _synchronizing = false; Refresh(true);
    }

    private void DatePattern_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_synchronizing) return;
        if (DatePatternChoice.SelectedItem is ComboBoxItem { Tag: string code }) DatePatternCode.Text = code;
        ReadFields();
    }
    private void TimePattern_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_synchronizing) return;
        if (TimePatternChoice.SelectedItem is ComboBoxItem { Tag: string code }) TimePatternCode.Text = code;
        ReadFields();
    }
    private void Selection_Changed(object sender, SelectionChangedEventArgs e) => ReadFields();
    private void Text_Changed(object sender, TextChangedEventArgs e) => ReadFields();
    private void Fields_Changed(object sender, RoutedEventArgs e) => ReadFields();
    private void Date_Changed(DatePicker sender, DatePickerSelectedValueChangedEventArgs e) => ReadFields();
    private void Time_Changed(TimePicker sender, TimePickerSelectedValueChangedEventArgs e) => ReadFields();
    private void Acknowledgement_Changed(object sender, RoutedEventArgs e) { if (!_synchronizing) StateChanged?.Invoke(); }

    private void ReadFields()
    {
        if (_synchronizing || _disposed || _pending || !Writable || _reader.State != NasSettingsEditState.Editing || _baseline is null) return;
        RiskAcknowledgement.IsChecked = false;
        var mode = (ModeChoice.SelectedItem as ComboBoxItem)?.Tag is NasRegionTimeMode selected ? selected : NasRegionTimeMode.Unknown;
        if (mode != NasRegionTimeMode.Manual)
        {
            _synchronizing = true; EditClock.IsChecked = false; NewDate.SelectedDate = null; NewTime.SelectedTime = null; _synchronizing = false;
        }
        _editedTime = null;
        var clockValid = true;
        if (EditClock.IsChecked == true)
        {
            if (NewDate.SelectedDate is { } date && NewTime.SelectedTime is { } time)
                _editedTime = new DateTime(date.Year, date.Month, date.Day, time.Hours, time.Minutes, time.Seconds, DateTimeKind.Unspecified);
            else clockValid = false;
        }
        var desired = NasRegionSettingsRules.Normalize(_baseline with
        {
            DateFormat = DatePatternCode.Text, TimeFormat = TimePatternCode.Text,
            Timezone = (TimezoneChoice.SelectedItem as ComboBoxItem)?.Tag as string,
            Mode = mode, NtpServers = ServersInput.Text.Split([',', '\r', '\n'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries),
        });
        _valid = clockValid && NasRegionSettingsRules.IsValid(desired, _editedTime) &&
            _baseline.TimeZones.Any(zone => zone.Id == desired.Timezone);
        _changed = _editedTime is not null || desired.DateFormat != _baseline.DateFormat ||
            desired.TimeFormat != _baseline.TimeFormat || desired.Timezone != _baseline.Timezone ||
            desired.Mode != _baseline.Mode || !desired.NtpServers.SequenceEqual(_baseline.NtpServers);
        if (_changed || !_valid) _feedback = null;
        // 记录中的集合按引用比较；相同内容不能反复替换，否则原生选择事件会循环刷新。
        if (_valid && !SameConfiguration(_reader.Draft, desired)) _reader.Draft = desired;
        ValidationNotice.Text = L.Get(!clockValid ? "NasRegionChooseClock" : "NasRegionInvalidInput");
        Refresh();
    }

    private void Refresh(bool synchronize = false)
    {
        if (_disposed || LoadingIndicator is null) return;
        var data = _reader.Draft;
        var known = data?.Mode is NasRegionTimeMode.Network or NasRegionTimeMode.Manual;
        var editing = known && Writable && !_pending && _reader.State == NasSettingsEditState.Editing;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        Fields.Visibility = !_reader.IsLoading && known && !editing ? Visibility.Visible : Visibility.Collapsed;
        ClockValue.Visibility = !_reader.IsLoading && known ? Visibility.Visible : Visibility.Collapsed;
        Editor.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
        var result = _feedback ?? _reader.LastResult;
        var error = _pending ? L.Get("NasSettingsSaveNeedsReview") : _reader.ErrorMessage;
        if (data is not null && !known) error = L.Get("NasSettingsUnavailable");
        if (result?.DiagnosticTag is "region.sync.unverified" or "region.sync.failed") error = L.Get("NasRegionSyncUnconfirmed");
        else if (result?.Status == MutationResultStatus.PartialSuccess && error is null) error = L.Get("NasFileServicePartialSave");
        var saved = result?.Status == MutationResultStatus.ConfirmedSuccess;
        StatusNotice.IsOpen = error is not null || saved;
        StatusNotice.Message = error ?? (saved ? L.Get(result?.DiagnosticTag == "region.sync.accepted" ? "NasRegionSyncAccepted" : "NasServiceSaved") : string.Empty);
        StatusNotice.Severity = saved && error is null ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        ValidationNotice.Visibility = editing && _baseline is not null && !_valid ? Visibility.Visible : Visibility.Collapsed;
        RiskAcknowledgement.IsEnabled = editing && _valid && _changed;
        if (data is not null && known)
        {
            DateFormatValue.Text = DateExample(data.DateFormat);
            TimeFormatValue.Text = TimeExample(data.TimeFormat);
            TimezoneValue.Text = data.TimeZones.FirstOrDefault(zone => zone.Id == data.Timezone)?.DisplayName ?? data.Timezone;
            ModeValue.Text = L.Get(data.Mode == NasRegionTimeMode.Network ? "NasRegionNetworkTime" : "NasRegionManualTime");
            ServersValue.Text = data.NtpServers.Count == 0 ? L.Get("NasRegionNoServers") : string.Join(Environment.NewLine, data.NtpServers);
            ClockValue.Text = data.NasLocalTime?.ToString("G", CultureInfo.CurrentCulture) ?? L.Get("NasRegionClockUnavailable");
            if (synchronize)
            {
                _synchronizing = true;
                DatePatternCode.Text = data.DateFormat; TimePatternCode.Text = data.TimeFormat;
                Populate(DatePatternChoice, new[] { "Y-m-d", "Y/m/d", "m/d/Y", "d/m/Y" }, data.DateFormat!, DateExample);
                Populate(TimePatternChoice, new[] { "H:i", "H:i:s", "h:i A", "g:i A" }, data.TimeFormat!, TimeExample);
                TimezoneChoice.Items.Clear();
                foreach (var zone in data.TimeZones) TimezoneChoice.Items.Add(new ComboBoxItem { Tag = zone.Id, Content = zone.DisplayName });
                TimezoneChoice.SelectedItem = TimezoneChoice.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (string)item.Tag == data.Timezone);
                ModeChoice.Items.Clear();
                ModeChoice.Items.Add(new ComboBoxItem { Tag = NasRegionTimeMode.Network, Content = L.Get("NasRegionNetworkTime") });
                ModeChoice.Items.Add(new ComboBoxItem { Tag = NasRegionTimeMode.Manual, Content = L.Get("NasRegionManualTime") });
                ModeChoice.SelectedItem = ModeChoice.Items.OfType<ComboBoxItem>().First(item => (NasRegionTimeMode)item.Tag == data.Mode);
                ServersInput.Text = string.Join(Environment.NewLine, data.NtpServers);
                _synchronizing = false;
            }
        }
        var manual = (ModeChoice.SelectedItem as ComboBoxItem)?.Tag is NasRegionTimeMode.Manual;
        EditClock.Visibility = manual ? Visibility.Visible : Visibility.Collapsed;
        ManualClockFields.Visibility = manual && EditClock.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        StateChanged?.Invoke();
    }
    private static void Populate(ComboBox box, string[] codes, string selected, Func<string?, string> label)
    {
        box.Items.Clear();
        foreach (var code in codes.Append(selected).Distinct()) box.Items.Add(new ComboBoxItem { Tag = code, Content = label(code) });
        box.SelectedItem = box.Items.OfType<ComboBoxItem>().First(item => (string)item.Tag == selected);
    }
    private static bool SameConfiguration(NasRegionSettings? left, NasRegionSettings right) =>
        left is not null && left.DateFormat == right.DateFormat && left.TimeFormat == right.TimeFormat &&
        left.Timezone == right.Timezone && left.Mode == right.Mode && left.NtpServers.SequenceEqual(right.NtpServers);
    private static string DateExample(string? value) => value switch
    { "Y-m-d" => "2001-02-03", "Y/m/d" => "2001/02/03", "m/d/Y" => "02/03/2001", "d/m/Y" => "03/02/2001", _ => L.Get("NasRegionOtherFormat") };
    private static string TimeExample(string? value) => value switch
    {
        "H:i" => "13:45", "H:i:s" => "13:45:06",
        "h:i A" or "h:i a" or "g:i A" or "g:i a" => new DateTime(2001, 2, 3, 13, 45, 6).ToString("h:mm tt", CultureInfo.CurrentCulture),
        _ => L.Get("NasRegionOtherFormat"),
    };
    public void Dispose() { if (_disposed) return; _disposed = true; _reader.Dispose(); StateChanged = null; }
    private static LocalizationService L => LocalizationService.Current;
}
