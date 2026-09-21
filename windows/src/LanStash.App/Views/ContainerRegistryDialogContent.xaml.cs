using LanStash.App.Features.Containers;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class ContainerRegistryDialogContent : UserControl, IDisposable
{
    private readonly ContainerRegistryViewModel _model = new();
    private readonly ContainerImagePullViewModel _pull = new();
    private readonly IContainerManagerRepository _repository;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _pullTimer;
    public bool NeedsParentRefresh => _pull.NeedsParentRefresh;
    private bool _disposed, _synchronizing = true;
    public ContainerRegistryDialogContent(IContainerManagerRepository repository)
    {
        _repository = repository;
        InitializeComponent(); ResultsList.ItemsSource = _model.Results; TagsList.ItemsSource = _model.Tags; PullTasksList.ItemsSource = _pull.Items;
        _model.PropertyChanged += (_, _) => { _pull.SetTarget(_model.SelectedImage?.Name, _model.SelectedTag); Refresh(); };
        _pull.PropertyChanged += (_, _) => Refresh();
        _pullTimer = DispatcherQueue.CreateTimer(); _pullTimer.Interval = TimeSpan.FromSeconds(5);
        _pullTimer.Tick += async (_, _) => { if (!_disposed && _pull.HasPollableTasks) await _pull.ReviewAsync(automatic: true); };
        _model.Activate(repository); _synchronizing = false; Refresh();
    }
    public async Task ActivateAsync() { await _pull.ActivateAsync(_repository); if (!_disposed) { _pullTimer.Start(); if (_pull.Items.Count > 0) ShowPullProgress(); } }
    private static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        QueryInput.IsEnabled = _model.IsAvailable && !_pull.IsSubmitting; SearchButton.IsEnabled = _model.CanSearch && !_pull.IsSubmitting;
        QueryNotice.Text = _model.QueryError ?? ""; QueryNotice.Visibility = Visible(_model.QueryError is not null);
        UnavailableNotice.Visibility = Visible(!_model.IsAvailable && !_model.RequiresReconnect);
        SearchErrorNotice.IsOpen = _model.SearchError is not null; SearchErrorNotice.Message = _model.SearchError ?? "";
        SearchProgress.IsActive = _model.IsSearching; SearchProgress.Visibility = Visible(_model.IsSearching);
        InitialNotice.Visibility = Visible(_model.IsAvailable && !_model.HasSearched && !_model.IsSearching);
        EmptyNotice.Visibility = Visible(_model.HasSearched && _model.Results.Count == 0 && _model.SearchError is null);
        LimitNotice.Visibility = Visible(_model.Results.Count > 0);
        ResultsList.IsEnabled = _model.CanSelect && !_pull.IsSubmitting; ResultsList.SelectedItem = _model.SelectedImage;
        TagsPanel.Visibility = Visible(_model.SelectedImage is not null);
        SelectedRepository.Text = _model.SelectedImage?.Name ?? "";
        TagFilterInput.Text = _model.TagFilter; TagFilterInput.IsEnabled = _model.HasLoadedTags && _model.IsAvailable && !_pull.IsSubmitting;
        ReloadTagsButton.IsEnabled = _model.CanReloadTags && !_pull.IsSubmitting;
        TagsProgress.IsActive = _model.IsLoadingTags; TagsProgress.Visibility = Visible(_model.IsLoadingTags);
        TagsErrorNotice.IsOpen = _model.TagsError is not null; TagsErrorNotice.Message = _model.TagsError ?? "";
        TagsEmptyNotice.Visibility = Visible(_model.HasLoadedTags && _model.Tags.Count == 0 && !_model.IsTagFilterEmpty);
        TagsFilteredNotice.Visibility = Visible(_model.IsTagFilterEmpty);
        TagsList.IsEnabled = _model.IsAvailable && !_model.IsLoadingTags && !_pull.IsSubmitting; TagsList.SelectedItem = _model.SelectedTag;
        SelectedReference.Text = _model.SelectedImage is { } image && _model.SelectedTag is { } tag ?
            LocalizationService.Current.Format("ContainerRegistryReference", image.Name, tag) : "";
        PullConfirmation.IsEnabled = _pull.CanConfirm; PullConfirmation.IsChecked = _pull.HasConfirmation;
        PullButton.IsEnabled = _pull.CanSubmit; ReviewPullsButton.IsEnabled = _pull.CanReview;
        PullUnavailableNotice.Visibility = Visible(!_pull.IsAvailable);
        PullErrorNotice.IsOpen = _pull.ErrorMessage is not null; PullErrorNotice.Message = _pull.ErrorMessage ?? "";
        PullProgress.IsActive = _pull.IsBusy; PullProgress.Visibility = Visible(_pull.IsBusy);
        PullTasksPanel.Visibility = Visible(_pull.Items.Count > 0);
        _synchronizing = false;
    }
    private void Query_Changed(object sender, TextChangedEventArgs e) { if (!_disposed && !_synchronizing) _model.SetQuery(QueryInput.Text); }
    private async void Query_KeyDown(object sender, KeyRoutedEventArgs e)
    { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; await SearchAsync(); } }
    private async void Search_Click(object sender, RoutedEventArgs e) => await SearchAsync();
    public async Task SearchAsync() { if (_disposed) return; _model.SetQuery(QueryInput.Text); await _model.SearchAsync(); }
    private async void Results_Changed(object sender, SelectionChangedEventArgs e)
    { if (!_disposed && !_synchronizing) await _model.SelectImageAsync(ResultsList.SelectedItem as ContainerRegistryItem); }
    private void TagFilter_Changed(object sender, TextChangedEventArgs e) { if (!_disposed && !_synchronizing) _model.SetTagFilter(TagFilterInput.Text); }
    private void Tags_Changed(object sender, SelectionChangedEventArgs e) { if (!_disposed && !_synchronizing) _model.SelectTag(TagsList.SelectedItem as string); }
    private async void ReloadTags_Click(object sender, RoutedEventArgs e) => await ReloadTagsAsync();
    public Task ReloadTagsAsync() => _model.ReloadTagsAsync();
    private void PullConfirmation_Changed(object sender, RoutedEventArgs e)
    { if (!_disposed && !_synchronizing) _pull.Confirm(PullConfirmation.IsChecked == true); }
    private async void Pull_Click(object sender, RoutedEventArgs e) => await PullAsync();
    public async Task PullAsync() { if (_disposed) return; await _pull.SubmitAsync(); if (!_disposed && _pull.Items.Count > 0) ShowPullProgress(); }
    private async void ReviewPulls_Click(object sender, RoutedEventArgs e) => await ReviewPullsAsync();
    public async Task ReviewPullsAsync() { await _pull.ReviewAsync(); if (!_disposed && _pull.Items.Count > 0) ShowPullProgress(); }
    public void ShowPullProgress() => DispatcherQueue.TryEnqueue(() =>
    {
        if (_disposed) return;
        // 列表更新完成后滚动到任务区，避免同步回执时进度仍留在可视区外。
        UpdateLayout(); RegistryScroll.ChangeView(null, RegistryScroll.ScrollableHeight, null, disableAnimation: true);
    });
    public void Dispose() { if (_disposed) return; _disposed = true; _synchronizing = true; _pullTimer.Stop(); _pull.Dispose(); _model.Dispose(); QueryInput.Text = ""; ResultsList.ItemsSource = TagsList.ItemsSource = PullTasksList.ItemsSource = null; }
}
