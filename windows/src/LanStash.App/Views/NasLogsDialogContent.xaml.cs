using System.Globalization;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed record NasLogRow(string Level, string Time, string Source, string Account, string Message)
{
    public override string ToString() => nameof(NasLogRow);
}

public sealed partial class NasLogsDialogContent : UserControl, INasSettingsDialogContent
{
    private static LocalizationService L => LocalizationService.Current;
    private readonly NasLogsViewModel _model;
    private bool _updating, _disposed;
    public bool CanSave => false;
    public bool IsBusy => _model.IsLoading;
    public string? PrimaryButtonResourceKey => null;
    public string ReloadButtonResourceKey => "NasLogsRefresh";
    public event Action? StateChanged;
    public NasLogsDialogContent(INasDetailsRepository repository)
    {
        _model = new(repository); InitializeComponent(); _updating = true;
        foreach (var filter in Enum.GetValues<NasLogLevelFilter>()) FilterChoice.Items.Add(new ComboBoxItem { Tag = filter });
        foreach (var size in new[] { 50, 100, 200 }) PageSizeChoice.Items.Add(new ComboBoxItem { Tag = size, Content = size.ToString(CultureInfo.CurrentCulture) });
        FilterChoice.SelectedIndex = 0; PageSizeChoice.SelectedIndex = 0; _updating = false;
        _model.Changed += Update; Update();
    }
    public Task ActivateAsync() => _model.RefreshAsync();
    public Task ReloadAsync() => _model.RefreshAsync();
    public Task SaveAsync() => Task.CompletedTask;
    private async void Previous_Click(object sender, RoutedEventArgs e) => await _model.PreviousAsync();
    private async void Next_Click(object sender, RoutedEventArgs e) => await _model.NextAsync();
    private async void PageSize_Changed(object sender, SelectionChangedEventArgs e)
    { if (!_updating && PageSizeChoice.SelectedItem is ComboBoxItem { Tag: int size }) await _model.ChangePageSizeAsync(size); }
    private void Filter_Changed(object sender, SelectionChangedEventArgs e) => ApplyFilter();
    private void Search_Changed(object sender, TextChangedEventArgs e) => ApplyFilter();
    private void ApplyFilter()
    { if (!_updating && SearchBox is not null && FilterChoice.SelectedItem is ComboBoxItem { Tag: NasLogLevelFilter filter }) _model.SetFilter(filter, SearchBox.Text); }
    private void Update()
    {
        if (_disposed) return;
        _updating = true;
        foreach (ComboBoxItem item in FilterChoice.Items)
        {
            var filter = (NasLogLevelFilter)item.Tag; var page = _model.Page;
            var count = filter switch { NasLogLevelFilter.All => page?.Total, NasLogLevelFilter.Error => page?.ErrorCount, NasLogLevelFilter.Warning => page?.WarningCount, _ => page?.InfoCount };
            var title = L.Get(filter switch { NasLogLevelFilter.All => "NasLogsAll", NasLogLevelFilter.Error => "NasLogsErrors", NasLogLevelFilter.Warning => "NasLogsWarnings", _ => "NasLogsInformation" });
            item.Content = count is { } number ? L.Format("NasLogsFilterCount", title, number.ToString("N0", CultureInfo.CurrentCulture)) : title;
        }
        PageSizeChoice.SelectedItem = PageSizeChoice.Items.Cast<ComboBoxItem>().First(item => (int)item.Tag == _model.PageSize);
        PageSizeChoice.IsEnabled = !_model.IsLoading && _model.IsAvailable;
        _updating = false;
        LoadingIndicator.IsActive = _model.IsLoading; LoadingIndicator.Visibility = _model.IsLoading ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.Message = _model.Error ?? ""; ErrorNotice.IsOpen = _model.Error is not null;
        ErrorNotice.Visibility = ErrorNotice.IsOpen ? Visibility.Visible : Visibility.Collapsed;
        var rows = _model.VisibleEntries;
        EntriesList.ItemsSource = rows.Select(entry => new NasLogRow(entry.Level ?? L.Get("NasLogsUnknownLevel"),
            entry.Time?.ToLocalTime().ToString("g", CultureInfo.CurrentCulture) ?? "", entry.Source ?? "", entry.Account ?? "", entry.Message)).ToArray();
        EntriesList.Visibility = rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyText.Text = L.Get(!_model.IsAvailable ? "NasLogsUnavailable" : _model.Page?.Entries.Count > 0 ? "NasLogsFilteredEmpty" : "NasLogsEmpty");
        EmptyText.Visibility = !_model.IsLoading && _model.Error is null && rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        PreviousButton.IsEnabled = _model.CanPrevious; NextButton.IsEnabled = _model.CanNext; PageText.Text = _model.PageText;
        StateChanged?.Invoke();
    }
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; _model.Changed -= Update; _model.Dispose();
        EntriesList.ItemsSource = null; SearchBox.Text = ""; ErrorNotice.Message = "";
    }
}
