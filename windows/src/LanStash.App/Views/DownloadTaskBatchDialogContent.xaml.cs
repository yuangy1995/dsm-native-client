using System.ComponentModel;
using LanStash.App.Features.Downloads;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class DownloadTaskBatchDialogContent : UserControl, IDisposable
{
    private readonly DownloadTaskBatchViewModel _model;
    private readonly LocalizationService _l = LocalizationService.Current;
    private bool _rendering, _ready, _completed;
    private IReadOnlyList<DownloadBatchChoice>? _choices;
    internal event Action? StateChanged;
    internal Style ActionButtonStyle => (Style)Resources["BatchActionStyle"];
    internal DownloadTaskBatchDialogContent(DownloadTaskBatchViewModel model)
    {
        InitializeComponent(); _model = model;
        ActionPicker.Header = _l.Get("DownloadBatchAction");
        ActionPicker.ItemsSource = new[] { _l.Get("DownloadBatchPause"), _l.Get("DownloadBatchResume"), _l.Get("DownloadBatchRemove"), _l.Get("DownloadBatchFinish") };
        FilterBox.PlaceholderText = _l.Get("DownloadBatchFilter"); AutomationProperties.SetName(FilterBox, _l.Get("DownloadBatchFilter"));
        RefreshButton.Content = _l.Get("DownloadBatchRefresh"); SelectAllButton.Content = _l.Get("DownloadBatchSelectAll");
        StopButton.Content = _l.Get("DownloadBatchStopRemaining"); Confirmation.Content = _l.Get("DownloadBatchConfirm");
        AutomationProperties.SetName(TaskChoices, _l.Get("DownloadBatchChoose")); AutomationProperties.SetName(ResultList, _l.Get("DownloadBatchResults"));
        _model.PropertyChanged += ModelChanged; _ready = true; Render();
    }
    internal string PrimaryText => _l.Get(_model.RequiresReview ? "DownloadBatchReview" : _model.CanContinue ? "DownloadBatchContinue" : _model.Action switch
    { DownloadBatchAction.Pause => "DownloadBatchPause", DownloadBatchAction.Resume => "DownloadBatchResume", DownloadBatchAction.RemoveTask => "DownloadBatchRemove", _ => "DownloadBatchFinish" });
    internal bool CanSubmit => !_completed && !_model.IsLoading && !_model.IsBusy && _model.ErrorKey is null &&
        (_model.RequiresReview || (Confirmation.IsChecked == true && (_model.CanContinue || (!_model.HasPending && TaskChoices.SelectedItems.Count > 0))));
    internal async Task SubmitAsync()
    {
        if (!CanSubmit) return;
        if (_model.RequiresReview) await _model.ReviewAsync();
        else if (_model.CanContinue) await _model.ContinueAsync();
        else await _model.StartAsync(TaskChoices.SelectedItems.OfType<DownloadBatchChoice>().Select(item => item.Id).ToArray());
        Confirmation.IsChecked = false; _completed = !_model.HasPending; Render();
    }
    private void ModelChanged(object? sender, PropertyChangedEventArgs e) => Render();
    private void Render()
    {
        if (!_ready || _rendering) return;
        _rendering = true;
        ActionPicker.SelectedIndex = (int)_model.Action; ActionPicker.IsEnabled = !_model.IsBusy && !_model.HasPending;
        LoadingRing.IsActive = _model.IsLoading; LoadingRing.Visibility = Show(_model.IsLoading);
        ErrorText.Visibility = Show(_model.ErrorKey is not null); ErrorText.Text = _model.ErrorKey is { } error ? _l.Get(error) : "";
        RefreshButton.IsEnabled = !_model.IsBusy && !_model.HasPending;
        SelectionPanel.Visibility = Show(!_model.IsLoading && _model.ErrorKey is null && !_model.HasPending);
        if (!ReferenceEquals(_choices, _model.Choices)) { _choices = _model.Choices; ApplyFilter(); Confirmation.IsChecked = false; }
        ResultsPanel.Visibility = Show(_model.Results.Count > 0); SummaryText.Text = _model.Summary; ResultList.ItemsSource = _model.Results;
        StopButton.Visibility = Show(_model.CanStopRemaining);
        Confirmation.IsEnabled = !_model.IsBusy && !_model.IsLoading && !_model.RequiresReview;
        ImpactText.Text = _l.Get(_model.Action switch
        { DownloadBatchAction.RemoveTask => "DownloadBatchRemoveWarning", DownloadBatchAction.FinishIncomplete => "DownloadBatchFinishWarning", _ => "DownloadBatchControlWarning" });
        _rendering = false; StateChanged?.Invoke();
    }
    private void ApplyFilter()
    {
        var filtered = _model.Choices.Where(item => item.Title.Contains(FilterBox.Text.Trim(), StringComparison.CurrentCultureIgnoreCase)).ToArray();
        TaskChoices.ItemsSource = filtered;
        EmptyText.Visibility = Show(filtered.Length == 0);
        EmptyText.Text = _l.Get(FilterBox.Text.Trim().Length > 0 ? "DownloadBatchFilteredEmpty" : "DownloadBatchEmpty");
        SelectAllButton.IsEnabled = filtered.Length > 0;
    }
    private void Action_Changed(object sender, SelectionChangedEventArgs e)
    { if (_ready && !_rendering && ActionPicker.SelectedIndex >= 0) { _completed = false; Confirmation.IsChecked = false; _model.SetAction((DownloadBatchAction)ActionPicker.SelectedIndex); } }
    private void Selection_Changed(object sender, SelectionChangedEventArgs e)
    { if (_ready && !_rendering) { _completed = false; Confirmation.IsChecked = false; StateChanged?.Invoke(); } }
    private void Filter_Changed(object sender, TextChangedEventArgs e)
    { if (_ready && !_rendering) { ApplyFilter(); Confirmation.IsChecked = false; StateChanged?.Invoke(); } }
    private void SelectAll_Click(object sender, RoutedEventArgs e) { TaskChoices.SelectAll(); }
    private async void Refresh_Click(object sender, RoutedEventArgs e) { _completed = false; Confirmation.IsChecked = false; await _model.LoadAsync(); }
    private void Stop_Click(object sender, RoutedEventArgs e) { _model.StopRemaining(); _completed = !_model.HasPending; Render(); }
    private void Confirmation_Changed(object sender, RoutedEventArgs e) { if (_ready && !_rendering) StateChanged?.Invoke(); }
    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    public void Dispose() { _ready = false; _model.PropertyChanged -= ModelChanged; }
}
