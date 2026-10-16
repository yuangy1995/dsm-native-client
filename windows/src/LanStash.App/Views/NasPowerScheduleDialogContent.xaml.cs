using System.Globalization;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed record NasPowerScheduleRow(string Id, string Title, string Recurrence, string Status);
public sealed partial class NasPowerScheduleDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasPowerScheduleViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    private string? _selectedId, _editingId;
    private bool _editing;
    public event Action? StateChanged;
    public bool CanSave => !_editing && _model.CanSave;
    public bool IsBusy => _model.IsBusy;
    public string? PrimaryButtonResourceKey => "NasHardwareEditSave";
    public NasPowerScheduleDialogContent(INasSettingsRepository repository)
    {
        _repository = repository; InitializeComponent();
        foreach (var day in new[] { DayOfWeek.Monday, DayOfWeek.Tuesday, DayOfWeek.Wednesday, DayOfWeek.Thursday, DayOfWeek.Friday, DayOfWeek.Saturday, DayOfWeek.Sunday })
        {
            var check = new CheckBox { Content = Culture.DateTimeFormat.GetShortestDayName(day), Tag = day, MinWidth = 0 };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(check, Culture.DateTimeFormat.GetDayName(day)); DaysPanel.Children.Add(check);
        }
        _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false;
    }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task ReloadAsync() { CloseEditor(); return _model.ReloadAsync(); }
    public Task SaveAsync() => _model.SaveAsync();
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        UnsupportedNotice.Visibility = _model.IsUnsupported ? Visibility.Visible : Visibility.Collapsed;
        var snapshot = _model.Snapshot;
        TimeZoneText.Visibility = CountText.Visibility = snapshot is null ? Visibility.Collapsed : Visibility.Visible;
        TimeZoneText.Text = snapshot?.TimeZoneIdentifier is { } zone ? L.Format("NasPowerScheduleTimeZone", zone) : L.Get("NasPowerScheduleTimeZoneUnknown");
        CountText.Text = snapshot is null ? "" : L.Format("NasPowerScheduleCount", _model.Draft.Count, _model.HasChanges ? _model.Draft.Count : snapshot.Total);
        var incomplete = snapshot is not null && (snapshot.IsTruncated || snapshot.IgnoredEntries > 0);
        IncompleteNotice.Visibility = incomplete ? Visibility.Visible : Visibility.Collapsed;
        FilterChoice.SelectedIndex = (int)_model.Filter; FilterChoice.IsEnabled = snapshot is not null && !IsBusy;
        var visible = _model.VisibleEntries;
        var rows = visible.Select(item => new NasPowerScheduleRow(item.Id,
            L.Format("NasPowerScheduleRow", L.Get(item.Action switch { NasPowerScheduleAction.Startup => "NasPowerScheduleStartup",
                NasPowerScheduleAction.Shutdown => "NasPowerScheduleShutdown", NasPowerScheduleAction.Restart => "NasPowerScheduleRestart", _ => "NasPowerScheduleUnknownAction" }),
                new TimeOnly(item.Hour, item.Minute).ToString("t", Culture)),
            item.Recurrence switch
            {
                NasPowerScheduleRecurrence.Daily => L.Get("NasPowerScheduleDaily"),
                NasPowerScheduleRecurrence.Once when item.Date is { } date => L.Format("NasPowerScheduleOnce", date.ToString("d", Culture)),
                NasPowerScheduleRecurrence.Weekly => string.Join(L.Get("NasPowerScheduleDaySeparator"), item.Weekdays.Select(day => Culture.DateTimeFormat.GetDayName(day))),
                _ => L.Get("NasPowerScheduleUnknownRecurrence")
            },
            L.Get(item.IsEnabled switch { true => "NasPowerScheduleEnabled.Content", false => "NasPowerScheduleDisabled.Content", _ => "NasPowerScheduleUnknownStatus" }))).ToArray();
        ScheduleList.ItemsSource = rows; ScheduleList.SelectedItem = rows.FirstOrDefault(row => row.Id == _selectedId);
        var selected = _model.Draft.FirstOrDefault(entry => entry.Id == _selectedId);
        AddEntryButton.IsEnabled = _model.CanEdit && !_editing && _model.Draft.Count < NasPowerScheduleRules.MaximumEntries;
        EditEntryButton.IsEnabled = RemoveEntryButton.IsEnabled = _model.CanEdit && !_editing && selected is not null;
        ResetButton.IsEnabled = _model.CanEdit && _model.HasChanges && !_editing;
        SelectedEnabled.Visibility = selected?.IsEnabled is not null && !_editing ? Visibility.Visible : Visibility.Collapsed;
        SelectedEnabled.IsOn = selected?.IsEnabled == true; SelectedEnabled.IsEnabled = _model.CanEdit;
        EmptyNotice.Visibility = snapshot is not null && visible.Count == 0 && !_editing ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Text = L.Get(_model.Draft.Count == 0 ? incomplete ? "NasPowerScheduleNoReadableRows" : _model.CanEdit ? "NasPowerScheduleEmptyEditable" : "NasPowerScheduleEmpty" : "NasPowerScheduleNoMatches");
        RiskChoice.Visibility = _model.HasChanges && !_editing ? Visibility.Visible : Visibility.Collapsed; RiskChoice.IsChecked = _model.RiskConfirmed; RiskChoice.IsEnabled = !IsBusy;
        WriteUnavailable.Visibility = snapshot is not null && (!snapshot.CanEdit || !_model.IsWriteAvailable) ? Visibility.Visible : Visibility.Collapsed;
        ResultNotice.IsOpen = _model.StatusKey is not null; ResultNotice.Message = _model.StatusKey is { } status ? L.Get(status) : "";
        ResultNotice.Severity = _model.Recovery?.IsComplete == true ? InfoBarSeverity.Success : InfoBarSeverity.Informational;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void Filter_Changed(object sender, SelectionChangedEventArgs e)
    { if (!_disposed && !_synchronizing) _model.SetFilter((NasPowerScheduleFilter)FilterChoice.SelectedIndex); }
    private void Schedule_Changed(object sender, SelectionChangedEventArgs e)
    { if (!_disposed && !_synchronizing) { _selectedId = (ScheduleList.SelectedItem as NasPowerScheduleRow)?.Id; Refresh(); } }
    private void AddEntry_Click(object sender, RoutedEventArgs e) => OpenEditor(null);
    private void EditEntry_Click(object sender, RoutedEventArgs e) => OpenEditor(_model.Draft.FirstOrDefault(entry => entry.Id == _selectedId));
    private void RemoveEntry_Click(object sender, RoutedEventArgs e) { if (_selectedId is { } id) _model.RemoveEntry(id); }
    private void Reset_Click(object sender, RoutedEventArgs e) => _model.ResetDraft();
    private void SelectedEnabled_Changed(object sender, RoutedEventArgs e)
    { if (!_disposed && !_synchronizing && _selectedId is { } id) _model.SetEntryEnabled(id, SelectedEnabled.IsOn); }
    private void Risk_Changed(object sender, RoutedEventArgs e) { if (!_disposed && !_synchronizing) _model.ConfirmRisk(RiskChoice.IsChecked == true); }
    private void OpenEditor(NasPowerScheduleEntry? entry)
    {
        if (!_model.CanEdit || _editing) return; _editing = true; _editingId = entry?.Id;
        ActionChoice.SelectedIndex = entry?.Action == NasPowerScheduleAction.Shutdown ? 1 : 0;
        EntryTime.Time = new TimeSpan(entry?.Hour ?? 8, entry?.Minute ?? 0, 0); EntryEnabled.IsChecked = entry?.IsEnabled ?? true;
        var days = entry is null ? Enum.GetValues<DayOfWeek>() : NasPowerScheduleRules.Days(entry);
        foreach (CheckBox check in DaysPanel.Children) check.IsChecked = days.Contains((DayOfWeek)check.Tag);
        EntryError.IsOpen = false; EntryEditor.Visibility = Visibility.Visible; Refresh();
    }
    private void ApplyEntry_Click(object sender, RoutedEventArgs e)
    {
        if (!_editing || !_model.CanEdit) return;
        var days = DaysPanel.Children.Cast<CheckBox>().Where(check => check.IsChecked == true).Select(check => (DayOfWeek)check.Tag).ToArray();
        var entry = new NasPowerScheduleEntry(_editingId ?? "draft", ActionChoice.SelectedIndex == 1 ? NasPowerScheduleAction.Shutdown : NasPowerScheduleAction.Startup,
            EntryEnabled.IsChecked == true, EntryTime.Time.Hours, EntryTime.Time.Minutes,
            days.Length == 7 ? NasPowerScheduleRecurrence.Daily : NasPowerScheduleRecurrence.Weekly, null, days);
        if (!_model.PutEntry(entry, _editingId)) { EntryError.Message = L.Get("NasPowerScheduleEntryInvalid"); EntryError.IsOpen = true; return; }
        CloseEditor(); Refresh();
    }
    private void CancelEntry_Click(object sender, RoutedEventArgs e) { CloseEditor(); Refresh(); }
    private void CloseEditor() { _editing = false; _editingId = null; EntryEditor.Visibility = Visibility.Collapsed; }
    public void Dispose() { if (_disposed) return; _disposed = true; _model.Dispose(); ScheduleList.ItemsSource = null; StateChanged = null; }
    private static CultureInfo Culture => CultureInfo.GetCultureInfo(L.ResolvedLanguage);
    private static LocalizationService L => LocalizationService.Current;
}
