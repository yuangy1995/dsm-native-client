using System.Globalization;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed record NasPowerScheduleRow(string Title, string Recurrence, string Status);
public sealed partial class NasPowerScheduleDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasPowerScheduleViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    public event Action? StateChanged;
    public bool CanSave => false;
    public bool IsBusy => _model.IsLoading;
    public string? PrimaryButtonResourceKey => null;
    public NasPowerScheduleDialogContent(INasSettingsRepository repository)
    { _repository = repository; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task ReloadAsync() => _model.ReloadAsync();
    public Task SaveAsync() => Task.CompletedTask;
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        UnsupportedNotice.Visibility = _model.IsUnsupported ? Visibility.Visible : Visibility.Collapsed;
        var snapshot = _model.Snapshot;
        TimeZoneText.Visibility = CountText.Visibility = snapshot is null ? Visibility.Collapsed : Visibility.Visible;
        TimeZoneText.Text = snapshot?.TimeZoneIdentifier is { } zone ? L.Format("NasPowerScheduleTimeZone", zone) : L.Get("NasPowerScheduleTimeZoneUnknown");
        CountText.Text = snapshot is null ? "" : L.Format("NasPowerScheduleCount", snapshot.Entries.Count, snapshot.Total);
        var incomplete = snapshot is not null && (snapshot.IsTruncated || snapshot.IgnoredEntries > 0);
        IncompleteNotice.Visibility = incomplete ? Visibility.Visible : Visibility.Collapsed;
        FilterChoice.SelectedIndex = (int)_model.Filter; FilterChoice.IsEnabled = snapshot is not null && !IsBusy;
        var visible = _model.VisibleEntries;
        ScheduleList.ItemsSource = visible.Select(item => new NasPowerScheduleRow(
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
        EmptyNotice.Visibility = snapshot is not null && visible.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Text = L.Get(snapshot?.Entries.Count == 0 ? incomplete ? "NasPowerScheduleNoReadableRows" : "NasPowerScheduleEmpty" : "NasPowerScheduleNoMatches");
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void Filter_Changed(object sender, SelectionChangedEventArgs e)
    { if (!_disposed && !_synchronizing) _model.SetFilter((NasPowerScheduleFilter)FilterChoice.SelectedIndex); }
    public void Dispose() { if (_disposed) return; _disposed = true; _model.Dispose(); ScheduleList.ItemsSource = null; StateChanged = null; }
    private static CultureInfo Culture => CultureInfo.GetCultureInfo(L.ResolvedLanguage);
    private static LocalizationService L => LocalizationService.Current;
}
