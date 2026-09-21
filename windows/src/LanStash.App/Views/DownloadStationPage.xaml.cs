using LanStash.App.Features.Downloads;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class DownloadStationPage : Page, IDisposable
{
    private const double CompactWidth = 760;

    private readonly IDownloadStationRepository _repository;
    private readonly DownloadStationViewModel _viewModel;
    private bool _initialized;
    private bool _compactShowsTaskList = true;
    private bool _updatingFilter;
    private bool _disposed;

    internal DownloadStationPage(
        IDownloadStationRepository repository,
        ForegroundTransferCoordinator? activityCoordinator = null)
        : this(repository, new DownloadStationViewModel(
            activityCoordinator: activityCoordinator))
    {
    }

    internal DownloadStationPage(
        IDownloadStationRepository repository,
        DownloadStationViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(viewModel);
        _repository = repository;
        _viewModel = viewModel;
        InitializeComponent();
        DataContext = viewModel;
        viewModel.PropertyChanged += ViewModel_PropertyChanged;
        Loaded += DownloadStationPage_Loaded;
        UpdateState();
    }

    private async void DownloadStationPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_initialized)
        {
            return;
        }
        _initialized = true;
        await RunAsync(() => _viewModel.ActivateAsync(_repository));
    }

    private void ViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(UpdateState);

    private async void Refresh_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.RefreshAsync);

    private async void CreateTask_Click(object sender, RoutedEventArgs e) =>
        await ShowCreateTaskDialogAsync();

    private async void LoadMore_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.LoadMoreAsync);

    private async void Pause_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(() => _viewModel.ControlSelectedTaskAsync(DownloadTaskControlAction.Pause));

    private async void Resume_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(() => _viewModel.ControlSelectedTaskAsync(DownloadTaskControlAction.Resume));

    private async void Delete_Click(object sender, RoutedEventArgs e) =>
        await ShowDeleteTaskDialogAsync();

    private void SearchBox_TextChanged(
        AutoSuggestBox sender,
        AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
        {
            _viewModel.SetSearchText(sender.Text);
        }
    }

    private void FilterPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingFilter || sender is not Pivot { SelectedItem: PivotItem { Tag: string tag } } ||
            !Enum.TryParse<DownloadTaskFilter>(tag, out var filter))
        {
            return;
        }
        _viewModel.SetFilter(filter);
    }

    private void TaskList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is DownloadTaskItem task)
        {
            _compactShowsTaskList = false;
            _viewModel.SelectTask(task);
            UpdateState();
        }
    }

    private void TaskStatus_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is TextBlock { DataContext: DownloadTaskItem item } status && item.State == DownloadTaskState.Finished)
            status.Style = (Style)Application.Current.Resources["WorkspaceSuccessTextStyle"];
    }

    private void Back_Click(object sender, RoutedEventArgs e) => ShowTaskList();

    private void ShowAll_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.ShowAll();
        SearchBox.Text = string.Empty;
        SyncFilterPicker();
        SearchBox.Focus(FocusState.Keyboard);
    }

    private void Page_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateAdaptiveLayout();

    private void BackAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_viewModel.HasSelection)
        {
            return;
        }
        args.Handled = true;
        ShowTaskList();
    }

    private void SearchAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (TaskPane.Visibility == Visibility.Visible)
        {
            args.Handled = true;
            SearchBox.Focus(FocusState.Keyboard);
        }
    }

    private async void RefreshAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await RunAsync(_viewModel.RefreshAsync);
    }

    private async void CreateTaskAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_viewModel.CanCreateTask)
        {
            return;
        }
        args.Handled = true;
        await ShowCreateTaskDialogAsync();
    }

    private ContentDialog? _linkCreateDialog;
    private async Task ShowCreateTaskDialogAsync()
    {
        if (_disposed || !_viewModel.CanCreateTask || _linkCreateDialog is not null || XamlRoot is null) return;
        var uriBox = new TextBox
        {
            Header = LocalizationService.Current.Get("DownloadStationCreateUriLabel"),
            PlaceholderText = LocalizationService.Current.Get("DownloadStationCreateUriPlaceholder"),
            MinHeight = 44, TextWrapping = TextWrapping.Wrap,
        };
        AutomationProperties.SetName(uriBox, LocalizationService.Current.Get("DownloadStationCreateUriAutomationName"));
        LanStash.App.Features.Files.CopyMove.IFileCopyMoveFolderSource? folders =
            _repository.Availability.SupportsCreateDestination && _repository is IDsmRepository files && _repository is IFileLocationsRepository locations
                ? new LanStash.App.Features.Files.CopyMove.RepositoryFileCopyMoveFolderSource(_repository.ProfileId,
                    new LanStash.App.Features.Files.RepositoryFileBrowserDataSource(files), locations) : null;
        using var optionsModel = new DownloadCreateOptionsViewModel(folders);
        using var options = new DownloadCreateOptionsDialogContent(optionsModel, "", taskFile: false);
        var content = new StackPanel { Spacing = 12, MinWidth = 280, MaxWidth = 540 };
        content.Children.Add(uriBox); content.Children.Add(options);
        var dialog = _linkCreateDialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme,
            Title = LocalizationService.Current.Get("DownloadStationCreateTitle"), Content = content,
            PrimaryButtonText = LocalizationService.Current.Get("DownloadStationCreateSubmit"),
            CloseButtonText = LocalizationService.Current.Get("ActionCancel"), DefaultButton = ContentDialogButton.Close,
            PrimaryButtonStyle = options.ActionButtonStyle, CloseButtonStyle = options.ActionButtonStyle,
            IsPrimaryButtonEnabled = false,
        };
        void Update() => dialog.IsPrimaryButtonEnabled = options.CanSubmit && !string.IsNullOrWhiteSpace(uriBox.Text) && !_viewModel.IsCreatingTask;
        void TextChanged(object sender, TextChangedEventArgs args) => Update();
        async void Submit(ContentDialog sender, ContentDialogButtonClickEventArgs args)
        {
            if (!options.CanSubmit || string.IsNullOrWhiteSpace(uriBox.Text)) { args.Cancel = true; return; }
            var deferral = args.GetDeferral(); options.BeginSubmission(); uriBox.IsEnabled = false;
            try { await _viewModel.CreateTaskAsync(uriBox.Text, optionsModel.Destination); }
            finally { deferral.Complete(); }
        }
        void Closing(ContentDialog sender, ContentDialogClosingEventArgs args) { if (_viewModel.IsCreatingTask && !_disposed) args.Cancel = true; }
        uriBox.TextChanged += TextChanged; options.StateChanged += Update;
        dialog.PrimaryButtonClick += Submit; dialog.Closing += Closing;
        try { await dialog.ShowAsync(); }
        finally
        {
            uriBox.TextChanged -= TextChanged; options.StateChanged -= Update;
            dialog.PrimaryButtonClick -= Submit; dialog.Closing -= Closing;
            uriBox.Text = ""; _linkCreateDialog = null; if (!_disposed) UpdateState();
        }
    }

    private async Task ShowDeleteTaskDialogAsync()
    {
        if (!_viewModel.CanDeleteSelectedTask)
        {
            return;
        }

        var content = new TextBlock
        {
            Text = LocalizationService.Current.Get("DownloadStationDeleteConfirmMessage"),
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 520,
        };

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = LocalizationService.Current.Get("DownloadStationDeleteConfirmTitle"),
            Content = content,
            PrimaryButtonText = LocalizationService.Current.Get("DownloadStationDeleteConfirmSubmit"),
            CloseButtonText = LocalizationService.Current.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Close,
        };

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            await RunAsync(_viewModel.DeleteSelectedTaskAsync);
        }
        else
        {
            UpdateState();
        }
    }

    private async Task RunAsync(Func<Task> operation)
    {
        try
        {
            await operation();
        }
        finally
        {
            UpdateState();
        }
    }

    private void UpdateState()
    {
        if (_disposed)
        {
            return;
        }
        LoadingState.Visibility = Visible(
            _viewModel.ContentState == DownloadStationContentState.Loading);
        EmptyState.Visibility = Visible(_viewModel.IsEmpty);
        FilteredEmptyState.Visibility = Visible(_viewModel.IsFilteredEmpty);
        ErrorState.Visibility = Visible(_viewModel.HasError);
        UnavailableState.Visibility = Visible(_viewModel.IsUnavailable);
        ContentState.Visibility = Visible(_viewModel.HasContent);

        RefreshButton.IsEnabled = !_viewModel.IsLoading && !_viewModel.IsUnavailable;
        SettingsButton.Visibility = Visible(_repository.Availability.SupportedFeatures.Contains(DownloadStationReadFeature.ServerSettings));
        SettingsButton.IsEnabled = !_viewModel.IsLoading;
        BatchButton.IsEnabled = !_viewModel.IsUnavailable && !_viewModel.IsLoading && !_viewModel.IsControllingTask && !_viewModel.IsDeletingTask;
        CreateTaskButton.IsEnabled = _viewModel.CanCreateTask;
        CreateFileTaskButton.IsEnabled = _viewModel.CanCreateTask;
        DownloadCreateNotice.IsOpen = _viewModel.HasCreateNotice;
        DownloadCreateNotice.Severity = _viewModel.CreateNoticeKind switch
        {
            DownloadTaskCreateNoticeKind.Success => InfoBarSeverity.Success,
            DownloadTaskCreateNoticeKind.NeedsReview or
                DownloadTaskCreateNoticeKind.Conflict or
                DownloadTaskCreateNoticeKind.Permission or
                DownloadTaskCreateNoticeKind.Unsupported => InfoBarSeverity.Warning,
            DownloadTaskCreateNoticeKind.Failure => InfoBarSeverity.Error,
            _ => InfoBarSeverity.Informational,
        };
        RefreshErrorNotice.IsOpen = _viewModel.HasRefreshError && !_viewModel.HasError;
        ActivitySummary.Visibility = Visible(_viewModel.HasActivity);
        ActivityErrorNotice.IsOpen = _viewModel.HasActivityError;
        AdvancedSummary.Visibility = Visible(_viewModel.HasAdvancedSummary);
        StationSettingsSummary.Visibility = Visible(_viewModel.HasSettings);
        DownloadRssSummary.Visibility = Visible(_viewModel.HasRss);
        AdvancedSummaryErrorNotice.IsOpen =
            _viewModel.HasSettingsError || _viewModel.HasRssError;
        LoadMoreErrorNotice.IsOpen = _viewModel.HasLoadMoreError;
        LoadMoreButton.IsEnabled = _viewModel.CanLoadMore;
        LoadMoreButton.Visibility = Visible(
            _viewModel.CanLoadMore || _viewModel.HasLoadMoreError);
        LoadMoreProgress.IsActive = _viewModel.IsLoadingMore;
        LoadMoreProgress.Visibility = Visible(_viewModel.IsLoadingMore);
        NoSelectionState.Visibility = Visible(!_viewModel.HasSelection);
        TaskDetailState.Visibility = Visible(_viewModel.HasSelection);
        PauseButton.Visibility = Visible(_viewModel.CanPauseSelectedTask);
        PauseButton.IsEnabled = _viewModel.CanPauseSelectedTask;
        ResumeButton.Visibility = Visible(_viewModel.CanResumeSelectedTask);
        ResumeButton.IsEnabled = _viewModel.CanResumeSelectedTask;
        DeleteButton.Visibility = Visible(_viewModel.CanDeleteSelectedTask);
        DeleteButton.IsEnabled = _viewModel.CanDeleteSelectedTask;
        if (_taskBatch?.HasPending == true) { PauseButton.IsEnabled = false; ResumeButton.IsEnabled = false; DeleteButton.IsEnabled = false; }
        BatchPendingNotice.IsOpen = _taskBatch?.HasPending == true;
        ControlProgress.IsActive = _viewModel.IsControllingTask || _viewModel.IsDeletingTask;
        ControlProgress.Visibility = Visible(_viewModel.IsControllingTask || _viewModel.IsDeletingTask);
        AutomationProperties.SetName(
            ControlProgress,
            LocalizationService.Current.Get(_viewModel.IsDeletingTask
                ? "DownloadStationDeleteInProgressMessage"
                : "DownloadStationControlInProgressMessage"));
        DownloadControlNotice.IsOpen = _viewModel.HasControlNotice;
        DownloadControlNotice.Severity = _viewModel.ControlNoticeKind switch
        {
            DownloadTaskControlNoticeKind.Success => InfoBarSeverity.Success,
            DownloadTaskControlNoticeKind.NeedsReview or
                DownloadTaskControlNoticeKind.Conflict or
                DownloadTaskControlNoticeKind.Permission or
                DownloadTaskControlNoticeKind.Unsupported => InfoBarSeverity.Warning,
            DownloadTaskControlNoticeKind.Failure => InfoBarSeverity.Error,
            _ => InfoBarSeverity.Informational,
        };
        DownloadDeleteNotice.IsOpen = _viewModel.HasDeleteNotice;
        DownloadDeleteNotice.Severity = _viewModel.DeleteNoticeKind switch
        {
            DownloadTaskDeleteNoticeKind.Success => InfoBarSeverity.Success,
            DownloadTaskDeleteNoticeKind.NeedsReview or
                DownloadTaskDeleteNoticeKind.Conflict or
                DownloadTaskDeleteNoticeKind.Permission or
                DownloadTaskDeleteNoticeKind.Unsupported => InfoBarSeverity.Warning,
            DownloadTaskDeleteNoticeKind.Failure => InfoBarSeverity.Error,
            _ => InfoBarSeverity.Informational,
        };
        TaskList.SelectedItem = _viewModel.SelectedTask;
        if (!string.Equals(SearchBox.Text, _viewModel.SearchText, StringComparison.Ordinal))
        {
            SearchBox.Text = _viewModel.SearchText;
        }
        SyncFilterPicker();
        UpdateBtSearchUi();
        foreach (var notice in ((Grid)Content).Children.OfType<InfoBar>())
            notice.Visibility = Visible(notice.IsOpen);
        UpdateAdaptiveLayout();
    }

    private void SyncFilterPicker()
    {
        _updatingFilter = true;
        FilterPicker.SelectedIndex = _viewModel.Filter switch
        {
            DownloadTaskFilter.All => 0,
            DownloadTaskFilter.Active => 1,
            DownloadTaskFilter.Finished => 2,
            DownloadTaskFilter.Paused => 3,
            _ => 0,
        };
        _updatingFilter = false;
    }

    private void UpdateAdaptiveLayout()
    {
        TaskColumn.Width = new GridLength(1, GridUnitType.Star);
        DetailColumn.Width = new GridLength(1, GridUnitType.Star);
        var showDetail = _viewModel.HasSelection && !_compactShowsTaskList;
        TaskColumn.Width = showDetail ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        DetailColumn.Width = showDetail ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        TaskPane.Visibility = Visible(!showDetail);
        DetailPane.Visibility = Visible(showDetail);
        BackButton.Visibility = Visible(showDetail);
    }

    private void ShowTaskList()
    {
        _compactShowsTaskList = true;
        _viewModel.SelectTask(null);
        TaskList.SelectedItem = null;
        UpdateAdaptiveLayout();
        TaskList.Focus(FocusState.Keyboard);
    }

    private static Visibility Visible(bool value) =>
        value ? Visibility.Visible : Visibility.Collapsed;

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        CloseBtSearchDialog();
        _disposed = true;
        DisposeSettingsDialog();
        DisposeTaskBatch();
        _fileCreateDialog?.Hide(); _fileCreateDialog = null;
        _linkCreateDialog?.Hide(); _linkCreateDialog = null;
        _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        _viewModel.Dispose();
    }
}
