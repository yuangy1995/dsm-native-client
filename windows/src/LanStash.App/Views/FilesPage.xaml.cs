using LanStash.App.Features.Files;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Files.Mutations;
using LanStash.App.Features.Files.Preview;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Features.Files.Sharing;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.App.Platform.Sharing;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;

namespace LanStash.App.Views;

public sealed partial class FilesPage : Page, IDisposable
{
    private readonly FileBrowserViewModel _viewModel;
    private readonly FilePreviewViewModel _previewViewModel;
    private readonly FileTextEditViewModel _textEditViewModel;
    private readonly IFilePreviewRepository _previewRepository;
    private readonly IFileShareLinkRepository? _shareRepository;
    private readonly IFileArchiveCompressionRepository? _archiveCompressionRepository;
    private readonly IFileArchiveExtractionRepository? _archiveExtractionRepository;
    private readonly Guid _profileId;
    private readonly WindowsTransferPickerService _transfers;
    private readonly WindowsClipboard _clipboard = new();
    private readonly WindowsSystemShare _systemShare;
    private readonly FileShareLinkReviewBlocker _shareReviewBlocker;
    private readonly FileLocationsViewModel _locationsViewModel = new();
    private FileShareLinkViewModel? _shareLinkModel;
    private ContentDialog? _shareLinkDialog;
    private bool _isClosingShareLink;
    private bool _initialized;
    private bool _isChoosingUpload;
    private bool _selectionNeedsScroll;
    private DragMoveUndo? _dragMoveUndo;
    private CancellationTokenSource? _dragMoveUndoCts;
    private readonly IFileSearchRepository? _searchRepository;
    private CancellationTokenSource? _searchCancellation;
    private bool? _locationsAreWide;
    private bool _disposed;

    internal FilesPage(
        IDsmRepository repository,
        IFilePreviewRepository previewRepository,
        string profileId,
        WindowsTransferPickerService transfers,
        IFileShareLinkRepository? shareRepository = null,
        FileShareLinkReviewBlocker? shareReviewBlocker = null,
        IFileLocationsRepository? locationsRepository = null,
        IFileMutationRepository? mutationRepository = null,
        FileMutationReviewBlocker? mutationReviewBlocker = null,
        IFileCopyMoveRepository? copyMoveRepository = null,
        FileCopyMoveReviewBlocker? copyMoveReviewBlocker = null,
        IFileCopyMoveFolderSource? copyMoveFolderSource = null,
        IFileRecycleRepository? recycleRepository = null,
        FileRecycleReviewBlocker? recycleReviewBlocker = null,
        IDirectorySizeRepository? directorySizeRepository = null,
        IFileArchiveCompressionRepository? archiveCompressionRepository = null,
        IFileArchiveExtractionRepository? archiveExtractionRepository = null)
        : this(
            new FileBrowserViewModel(new RepositoryFileBrowserDataSource(repository)),
            previewRepository,
            profileId,
            transfers,
            shareRepository ?? repository as IFileShareLinkRepository,
            shareReviewBlocker,
            locationsRepository ?? repository as IFileLocationsRepository,
            mutationRepository ?? repository as IFileMutationRepository,
            mutationReviewBlocker,
            copyMoveRepository ?? repository as IFileCopyMoveRepository,
            copyMoveReviewBlocker,
            copyMoveFolderSource ?? CreateCopyMoveFolderSource(
                profileId, repository, locationsRepository ?? repository as IFileLocationsRepository),
            recycleRepository ?? repository as IFileRecycleRepository,
            recycleReviewBlocker,
            directorySizeRepository ?? repository as IDirectorySizeRepository,
            archiveCompressionRepository ?? repository as IFileArchiveCompressionRepository,
            archiveExtractionRepository ?? repository as IFileArchiveExtractionRepository)
    {
    }

    internal FilesPage(
        FileBrowserViewModel viewModel,
        IFilePreviewRepository previewRepository,
        string profileId,
        WindowsTransferPickerService transfers,
        IFileShareLinkRepository? shareRepository = null,
        FileShareLinkReviewBlocker? shareReviewBlocker = null,
        IFileLocationsRepository? locationsRepository = null,
        IFileMutationRepository? mutationRepository = null,
        FileMutationReviewBlocker? mutationReviewBlocker = null,
        IFileCopyMoveRepository? copyMoveRepository = null,
        FileCopyMoveReviewBlocker? copyMoveReviewBlocker = null,
        IFileCopyMoveFolderSource? copyMoveFolderSource = null,
        IFileRecycleRepository? recycleRepository = null,
        FileRecycleReviewBlocker? recycleReviewBlocker = null,
        IDirectorySizeRepository? directorySizeRepository = null,
        IFileArchiveCompressionRepository? archiveCompressionRepository = null,
        IFileArchiveExtractionRepository? archiveExtractionRepository = null)
    {
        InitializeComponent();
        _viewModel = viewModel;
        _previewViewModel = new FilePreviewViewModel();
        _textEditViewModel = new FileTextEditViewModel();
        _previewRepository = previewRepository;
        _profileId = Guid.Parse(profileId);
        _shareRepository = shareRepository?.ProfileId == _profileId
            ? shareRepository
            : null;
        _mutationRepository = mutationRepository?.ProfileId == _profileId
            ? mutationRepository
            : null;
        _shareReviewBlocker = shareReviewBlocker ?? FileShareLinkReviewBlocker.Current;
        _mutationReviewBlocker = mutationReviewBlocker ?? FileMutationReviewBlocker.Current;
        _copyMoveRepository = copyMoveRepository?.ProfileId == _profileId
            ? copyMoveRepository
            : null;
        _copyMoveFolderSource = copyMoveFolderSource?.ProfileId == _profileId
            ? copyMoveFolderSource
            : null;
        _copyMoveReviewBlocker = copyMoveReviewBlocker ?? FileCopyMoveReviewBlocker.Current;
        _recycleRepository = recycleRepository?.ProfileId == _profileId
            ? recycleRepository
            : null;
        _recycleReviewBlocker = recycleReviewBlocker ?? FileRecycleReviewBlocker.Current;
        _directorySizeRepository = directorySizeRepository?.ProfileId == _profileId
            ? directorySizeRepository
            : null;
        _archiveCompressionRepository = archiveCompressionRepository?.ProfileId == _profileId
            ? archiveCompressionRepository
            : null;
        _archiveExtractionRepository = archiveExtractionRepository?.ProfileId == _profileId
            ? archiveExtractionRepository
            : null;
        _searchRepository = (previewRepository as IFileSearchRepository)?.ProfileId == _profileId
            ? (previewRepository as IFileSearchRepository)
            : null;
        SearchSubfoldersToggle.Visibility = _searchRepository?.IsSearchAvailable == true
            ? Visibility.Visible : Visibility.Collapsed;
        _transfers = transfers;
        _systemShare = new WindowsSystemShare(
            () => (Application.Current as App)?.MainWindow);
        if (locationsRepository?.ProfileId == _profileId)
        {
            _locationsViewModel.Activate(_profileId, locationsRepository, _viewModel);
        }
        _transfers.UploadFinished += Transfers_UploadFinished;
        _transfers.UploadBatchFinished += Transfers_UploadBatchFinished;
        _transfers.FolderUploadBatchFinished += Transfers_FolderUploadBatchFinished;
        _transfers.DownloadBatchFinished += Transfers_DownloadBatchFinished;
        DataContext = _viewModel;
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        _locationsViewModel.PropertyChanged += LocationsViewModel_PropertyChanged;
        _previewViewModel.PropertyChanged += PreviewViewModel_PropertyChanged;
        PreviewPane.Attach(_previewViewModel);
        PreviewPane.AttachTextEdit(_textEditViewModel);
        PreviewPane.CloseRequested += PreviewPane_CloseRequested;
        PreviewPane.RetryRequested += PreviewPane_RetryRequested;
        PreviewPane.SaveCopyRequested += PreviewPane_SaveCopyRequested;
        PreviewPane.UnsavedDiscardRequested += PreviewPane_UnsavedDiscardRequested;
        LocationsPane.Attach(_locationsViewModel, OpenLocationAsync, RefreshLocationsAsync);
        LocationsPane.LocationOpened += LocationsPane_LocationOpened;
        Loaded += FilesPage_Loaded;
        UpdateState();
    }

    private void PreviewViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(UpdatePreviewLayout);

    private async void FilesPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_initialized)
        {
            return;
        }

        _initialized = true;
        await RunAsync(_viewModel.InitializeAsync);
        await LocationsPane.LoadAsync();
    }

    private void ViewModel_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(FileBrowserViewModel.SelectedItem))
        {
            _selectionNeedsScroll = true;
        }
        DispatcherQueue.TryEnqueue(UpdateState);
    }

    private void LocationsViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(UpdateState);

    private async void PathBreadcrumbs_ItemClicked(BreadcrumbBar sender, BreadcrumbBarItemClickedEventArgs args)
    {
        ExitDownloadSelectionMode();
        await RunAsync(() => _viewModel.NavigateToBreadcrumbAsync(args.Item as FileBrowserBreadcrumb));
    }

    private void Locations_Click(object sender, RoutedEventArgs e)
    {
        if (!_locationsViewModel.IsActive)
        {
            return;
        }
        if (_locationsAreWide == true)
        {
            LocationsPane.FocusFirstLocation();
            return;
        }
        LocationsSplitView.IsPaneOpen = !LocationsSplitView.IsPaneOpen;
        if (LocationsSplitView.IsPaneOpen)
        {
            LocationsPane.FocusFirstLocation();
        }
        else
        {
            LocationsPane.CancelOpening();
            LocationsButton.Focus(FocusState.Programmatic);
        }
    }

    private async Task RefreshLocationsAsync(CancellationToken cancellationToken)
    {
        if (_disposed || !_locationsViewModel.IsActive)
        {
            return;
        }
        try
        {
            await _locationsViewModel.RefreshAsync(cancellationToken);
        }
        catch (ObjectDisposedException) when (_disposed || !_locationsViewModel.IsActive)
        {
        }
        catch (InvalidOperationException) when (_disposed || !_locationsViewModel.IsActive)
        {
        }
    }

    private async Task<bool> OpenLocationAsync(
        string path,
        FileLocationSource source,
        CancellationToken cancellationToken)
    {
        if (_disposed || !_locationsViewModel.IsActive)
        {
            return false;
        }
        ExitDownloadSelectionMode();
        try
        {
            var opened = await _locationsViewModel.OpenLocationAsync(path, source, cancellationToken);
            if (!opened || _disposed || !_locationsViewModel.IsActive)
            {
                return false;
            }

            CloseShareLinkDialog();
            CloseMutationDialog();
            CloseCopyMoveDialog();
            CloseRecycleDialog();
            CloseArchiveExtractionDialog();
            await ClosePreviewAsync();
            if (_disposed || !_locationsViewModel.IsActive)
            {
                return false;
            }
            FilterBox.Text = string.Empty;
            UploadNeedsReview.IsOpen = false;
            UpdateState();
            return true;
        }
        catch (ObjectDisposedException) when (_disposed || !_locationsViewModel.IsActive)
        {
            return false;
        }
        catch (InvalidOperationException) when (_disposed || !_locationsViewModel.IsActive)
        {
            return false;
        }
    }

    private void LocationsPane_LocationOpened(object? sender, EventArgs e)
    {
        if (_locationsAreWide != true)
        {
            LocationsSplitView.IsPaneOpen = false;
        }
        if (_viewModel.HasContent && _viewModel.IsListLayout)
        {
            FileList.Focus(FocusState.Programmatic);
        }
        else if (_viewModel.HasContent)
        {
            FileGrid.Focus(FocusState.Programmatic);
        }
        else
        {
            PathBreadcrumbs.Focus(FocusState.Programmatic);
        }
    }

    private void LocationsSplitView_PaneClosed(SplitView sender, object args)
    {
        if (_locationsAreWide == true)
        {
            return;
        }
        LocationsPane.CancelOpening();
        LocationsButton.Focus(FocusState.Programmatic);
    }

    private void FilterBox_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput)
        {
            return;
        }
        ExitDownloadSelectionMode();
        if (SearchSubfoldersToggle.IsOn && _searchRepository is not null)
        {
            _ = PerformAsyncSearchAsync(sender.Text);
        }
        else
        {
            _viewModel.SetFilter(sender.Text);
            UpdateState();
        }
    }

    private void SearchSubfolders_Toggled(object sender, RoutedEventArgs e)
    {
        if (!SearchSubfoldersToggle.IsOn)
        {
            _viewModel.SetFilter(FilterBox.Text);
            UpdateState();
            return;
        }
        if (!string.IsNullOrWhiteSpace(FilterBox.Text) && _searchRepository is not null)
        {
            _ = PerformAsyncSearchAsync(FilterBox.Text);
        }
    }

    private async Task PerformAsyncSearchAsync(string query)
    {
        _searchCancellation?.Cancel();
        _searchCancellation?.Dispose();
        _searchCancellation = new CancellationTokenSource();
        var token = _searchCancellation.Token;

        if (_searchRepository is null)
        {
            return;
        }

        if (string.IsNullOrWhiteSpace(query))
        {
            _viewModel.SetFilter(query);
            UpdateState();
            return;
        }

        _viewModel.BeginAsyncSearch();
        UpdateState();

        try
        {
            var currentPath = _viewModel.CurrentPath ?? string.Empty;
            var request = new FileSearchRequest(currentPath, query, Recursive: true);
            var result = await _searchRepository.SearchAsync(request, token);

            if (token.IsCancellationRequested)
            {
                return;
            }

            _viewModel.SetAsyncSearchResults(result.Items, result.TotalCount, result.IsTruncated);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception)
        {
            if (!token.IsCancellationRequested)
            {
                _viewModel.SetAsyncSearchError();
            }
        }
        finally
        {
            UpdateState();
        }
    }

    private async void SearchRetry_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(FilterBox.Text))
        {
            await PerformAsyncSearchAsync(FilterBox.Text);
        }
    }

    private async void Files_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (_isSelectingItems)
        {
            return;
        }
        if (sender is not ListViewBase itemsControl ||
            e.OriginalSource is not DependencyObject source)
        {
            return;
        }

        var container = FindItemContainer(itemsControl, source);
        if (container is not ListViewItem && container is not GridViewItem)
        {
            return;
        }

        if (itemsControl.ItemFromContainer(container) is not FileBrowserEntry entry)
        {
            return;
        }

        e.Handled = true;
        _viewModel.SelectedItem = entry;
        if (entry.IsDirectory)
        {
            FilterBox.Text = string.Empty;
            await ClosePreviewAsync();
            await RunAsync(() => _viewModel.OpenAsync(entry));
            return;
        }
        await OpenPreviewAsync(entry);
    }

    private static DependencyObject? FindItemContainer(
        ListViewBase owner,
        DependencyObject source)
    {
        for (var current = source; current is not null && current != owner;
             current = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(current))
        {
            if (current is ListViewItem or GridViewItem)
            {
                return current;
            }
        }
        return null;
    }

    private async void Back_Click(object sender, RoutedEventArgs e)
    {
        ExitDownloadSelectionMode();
        if (_previewViewModel.IsOpen)
        {
            await ClosePreviewAsync();
            return;
        }
        FilterBox.Text = string.Empty;
        await RunAsync(_viewModel.GoBackAsync);
    }

    private async void BackAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        ExitDownloadSelectionMode();
        if (_previewViewModel.IsOpen)
        {
            await ClosePreviewAsync();
            return;
        }
        FilterBox.Text = string.Empty;
        await RunAsync(_viewModel.GoBackAsync);
    }

    private async void OpenSelectedAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_isSelectingItems)
        {
            return;
        }
        if (_viewModel.SelectedItem is not { } selected)
        {
            return;
        }

        args.Handled = true;
        if (!selected.IsDirectory)
        {
            await OpenPreviewAsync(selected);
            return;
        }
        FilterBox.Text = string.Empty;
        await ClosePreviewAsync();
        await RunAsync(() => _viewModel.OpenAsync(selected));
    }

    private async void Up_Click(object sender, RoutedEventArgs e)
    {
        ExitDownloadSelectionMode();
        await ClosePreviewAsync();
        FilterBox.Text = string.Empty;
        await RunAsync(_viewModel.GoUpAsync);
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        ExitDownloadSelectionMode();
        await ClosePreviewAsync();
        await RunAsync(_viewModel.RefreshAsync);
        UploadNeedsReview.IsOpen = false;
    }

    private async void LoadMore_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.LoadMoreAsync);

    private async void Files_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isSelectingItems && sender is ListViewBase source)
        {
            HandleDownloadSelectionChanged(source, e);
            return;
        }
        PreviewPane.SetSaveCopyEnabled(false);
        if (_previewViewModel.IsOpen &&
            !string.Equals(
                _previewViewModel.Snapshot.Item?.Path,
                _viewModel.SelectedItem?.Path,
                StringComparison.Ordinal))
        {
            await ClosePreviewAsync();
        }
        UpdateState();
    }

    private async void Preview_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.SelectedItem is { IsDirectory: false } selected)
        {
            await OpenPreviewAsync(selected);
        }
    }


    private async void ShareLink_Click(object sender, RoutedEventArgs e) =>
        await ShowShareLinkAsync();

    private async void ShareLinkAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (IsReadOnlyLocation() || !CanOpenShareLink())
        {
            return;
        }
        args.Handled = true;
        await ShowShareLinkAsync();
    }

    private async void Download_Click(object sender, RoutedEventArgs e) =>
        await DownloadSelectedAsync();

    private async void Upload_Click(object sender, RoutedEventArgs e) =>
        await UploadToCurrentFolderAsync();

    private async void UploadAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_viewModel.IsLoading ||
            _isChoosingUpload ||
            _downloadBatchId is not null ||
            IsReadOnlyLocation() ||
            string.IsNullOrWhiteSpace(_viewModel.CurrentPath))
        {
            return;
        }

        args.Handled = true;
        await UploadToCurrentFolderAsync();
    }

    private async void DownloadAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_isSelectingItems || _isChoosingDownloadTarget ||
            _viewModel.SelectedItem is null)
        {
            return;
        }

        args.Handled = true;
        await DownloadSelectedAsync();
    }

    private async Task DownloadSelectedAsync()
    {
        if (_isSelectingItems || _isChoosingDownloadTarget)
        {
            return;
        }
        if (_viewModel.SelectedItem is not { } entry)
        {
            return;
        }

        await DownloadItemAsync(_profileId, entry.Item);
    }

    private async Task DownloadItemAsync(Guid profileId, FileItem item)
    {
        DownloadButton.IsEnabled = false;
        try
        {
            await _transfers.PickAndStartDownloadAsync(
                profileId.ToString(),
                new FileBrowserEntry(item));
        }
        catch (ObjectDisposedException)
        {
        }
        catch
        {
            var localization = LocalizationService.Current;
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = localization.Get("TransferSaveErrorTitle"),
                Content = localization.Get("TransferSaveErrorMessage"),
                CloseButtonText = localization.Get("ActionClose"),
                DefaultButton = ContentDialogButton.Close,
            };
            await dialog.ShowAsync();
        }
        finally
        {
            UpdateState();
        }
    }

    private async Task UploadToCurrentFolderAsync()
    {
        var folderPath = _viewModel.CurrentPath;
        if (_isChoosingUpload || IsReadOnlyLocation() || string.IsNullOrWhiteSpace(folderPath))
        {
            return;
        }

        _isChoosingUpload = true;
        UpdateState();
        try
        {
            var overwrite = UploadOverwriteToggle.IsChecked == true;
            var start = await _transfers.PickAndStartUploadBatchAsync(
                _profileId.ToString(),
                folderPath,
                overwrite);
            ShowFileUploadBatchStart(start.Status, start.SelectedCount);
        }
        catch (ObjectDisposedException)
        {
        }
        catch
        {
            var localization = LocalizationService.Current;
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = localization.Get("TransferUploadOpenErrorTitle"),
                Content = localization.Get("TransferUploadOpenErrorMessage"),
                CloseButtonText = localization.Get("ActionClose"),
                DefaultButton = ContentDialogButton.Close,
            };
            await dialog.ShowAsync();
        }
        finally
        {
            _isChoosingUpload = false;
            UpdateState();
        }
    }

    private void Transfers_UploadFinished(ForegroundUploadFinished finished)
    {
        if (!string.Equals(finished.ProfileId, _profileId.ToString(), StringComparison.Ordinal))
        {
            return;
        }

        DispatcherQueue.TryEnqueue(async () =>
        {
            if (_disposed ||
                !string.Equals(
                    _viewModel.CurrentPath,
                    finished.FolderPath,
                    StringComparison.Ordinal))
            {
                return;
            }

            if (finished.Result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                UploadNeedsReview.IsOpen = false;
                await RunAsync(_viewModel.RefreshAsync);
                return;
            }
            if (finished.Result.Status is
                MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission or
                MutationResultStatus.PartialSuccess)
            {
                UploadNeedsReview.IsOpen = true;
            }
        });
    }

    private void Transfers_UploadBatchFinished(ForegroundUploadBatchFinished finished)
    {
        if (!string.Equals(finished.ProfileId, _profileId.ToString(), StringComparison.Ordinal))
        {
            return;
        }

        DispatcherQueue.TryEnqueue(async () =>
        {
            if (_disposed ||
                !string.Equals(
                    _viewModel.CurrentPath,
                    finished.FolderPath,
                    StringComparison.Ordinal))
            {
                return;
            }

            ShowFileUploadBatchSummary(finished.Summary);
            UploadNeedsReview.IsOpen = finished.Summary.NeedsReviewCount > 0;
            if (finished.Summary.ConfirmedCount > 0)
            {
                await RunAsync(_viewModel.RefreshAsync);
            }
        });
    }

    private async void ClearFilter_Click(object sender, RoutedEventArgs e)
    {
        ExitDownloadSelectionMode();
        FilterBox.Text = string.Empty;
        await RunAsync(_viewModel.ClearFiltersAsync);
        UpdateState();
    }

    private async void SortName_Click(object sender, RoutedEventArgs e)
    {
        ExitDownloadSelectionMode();
        await RunAsync(() => _viewModel.SetSortFieldAsync(FileListSortField.Name));
    }

    private async void SortModified_Click(object sender, RoutedEventArgs e)
    {
        ExitDownloadSelectionMode();
        await RunAsync(() => _viewModel.SetSortFieldAsync(FileListSortField.ModifiedTime));
    }

    private async void SortSize_Click(object sender, RoutedEventArgs e)
    {
        ExitDownloadSelectionMode();
        await RunAsync(() => _viewModel.SetSortFieldAsync(FileListSortField.Size));
    }

    private async void SortAscending_Click(object sender, RoutedEventArgs e)
    {
        ExitDownloadSelectionMode();
        await RunAsync(() => _viewModel.SetSortDirectionAsync(FileListSortDirection.Ascending));
    }

    private async void SortDescending_Click(object sender, RoutedEventArgs e)
    {
        ExitDownloadSelectionMode();
        await RunAsync(() => _viewModel.SetSortDirectionAsync(FileListSortDirection.Descending));
    }

    private async void TypeAll_Click(object sender, RoutedEventArgs e)
    {
        ExitDownloadSelectionMode();
        await RunAsync(() => _viewModel.SetTypeFilterAsync(FileListTypeFilter.All));
    }

    private async void TypeFiles_Click(object sender, RoutedEventArgs e)
    {
        ExitDownloadSelectionMode();
        await RunAsync(() => _viewModel.SetTypeFilterAsync(FileListTypeFilter.Files));
    }

    private async void TypeFolders_Click(object sender, RoutedEventArgs e)
    {
        ExitDownloadSelectionMode();
        await RunAsync(() => _viewModel.SetTypeFilterAsync(FileListTypeFilter.Folders));
    }

    private void ListLayout_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.Layout = FileBrowserLayout.List;
        _selectionNeedsScroll = true;
        UpdateState();
        SynchronizeDownloadSelectionAfterLayoutChange();
    }

    private void GridLayout_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.Layout = FileBrowserLayout.Grid;
        _selectionNeedsScroll = true;
        UpdateState();
        SynchronizeDownloadSelectionAfterLayoutChange();
    }


    private bool CanOpenShareLink() =>
        !_disposed &&
        !IsReadOnlyLocation() &&
        !_isClosingShareLink &&
        _shareLinkDialog is null &&
        !_viewModel.IsLoading &&
        _viewModel.SelectedItem is not null;

    private async Task ShowShareLinkAsync()
    {
        if (IsReadOnlyLocation() || !CanOpenShareLink() || _viewModel.SelectedItem is not { } selected)
        {
            return;
        }

        var localization = LocalizationService.Current;
        if (_shareRepository is null)
        {
            var unavailable = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = localization.Get("FileShareLinkUnsupportedTitle"),
                Content = localization.Get("FileShareLinkUnsupportedMessage"),
                CloseButtonText = localization.Get("ActionClose"),
                DefaultButton = ContentDialogButton.Close,
            };
            await unavailable.ShowAsync();
            return;
        }

        _shareLinkModel = new FileShareLinkViewModel(
            _shareRepository,
            _profileId,
            selected.Item,
            _systemShare.IsAvailable,
            initialNeedsReview: _shareReviewBlocker.Contains(_profileId, selected.Path));
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            CloseButtonText = localization.Get("ActionClose"),
            DefaultButton = ContentDialogButton.None,
        };
        _shareLinkDialog = dialog;

        void Render()
        {
            if (_shareLinkModel is not { } model || _shareLinkDialog != dialog)
            {
                return;
            }
            dialog.Title = ShareDialogTitle(model.State, localization);
            dialog.Content = BuildShareDialogContent(model, localization, Render);
        }

        dialog.Closing += (_, args) =>
        {
            if (_isClosingShareLink || _shareLinkDialog != dialog)
            {
                return;
            }
            if (_shareLinkModel?.State != FileShareLinkPresentationState.Creating)
            {
                return;
            }
            args.Cancel = true;
            _shareLinkModel.RequestCancellation();
            Render();
        };

        Render();
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            _shareLinkModel?.Dispose();
            _shareLinkModel = null;
            if (ReferenceEquals(_shareLinkDialog, dialog))
            {
                _shareLinkDialog = null;
            }
            _isClosingShareLink = false;
            if (!_disposed)
            {
                UpdateState();
            }
        }
    }

    private bool IsReadOnlyLocation() =>
        _locationsViewModel.SelectedSource is FileLocationSource.Remote or FileLocationSource.Recycle ||
        ContainsRecycleSegment(_viewModel.CurrentPath) ||
        (_viewModel.SelectedItem is { } selected && ContainsRecycleSegment(selected.Path));

    private FrameworkElement BuildShareDialogContent(
        FileShareLinkViewModel model,
        LocalizationService localization,
        Action render)
    {
        var panel = new StackPanel
        {
            Width = 440,
            MaxWidth = 440,
            Spacing = 12,
        };
        var target = new TextBlock
        {
            Text = localization.Format("FileShareLinkTarget", model.TargetName),
            TextWrapping = TextWrapping.Wrap,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        AutomationProperties.SetHeadingLevel(target, AutomationHeadingLevel.Level2);
        panel.Children.Add(target);

        if (model.State == FileShareLinkPresentationState.Form)
        {
            panel.Children.Add(new TextBlock
            {
                Text = localization.Get("FileShareLinkAccessNote"),
                TextWrapping = TextWrapping.Wrap,
            });
            var create = new Button
            {
                Content = localization.Get("FileShareLinkCreateAction"),
                IsEnabled = model.CanCreate,
                MinHeight = 44,
                HorizontalAlignment = HorizontalAlignment.Right,
                AccessKey = "C",
            };
            var passwordError = new InfoBar
            {
                IsOpen = true,
                IsClosable = false,
                Severity = InfoBarSeverity.Error,
                Message = localization.Get("FileShareLinkPasswordError"),
                Visibility = model.HasPasswordError
                    ? Visibility.Visible
                    : Visibility.Collapsed,
            };
            AutomationProperties.SetLiveSetting(passwordError, AutomationLiveSetting.Assertive);
            var password = new PasswordBox
            {
                Header = localization.Get("FileShareLinkPasswordLabel"),
                Password = model.Password,
                MinHeight = 44,
            };
            AutomationProperties.SetHelpText(
                password,
                localization.Get("FileShareLinkPasswordHelp"));
            password.PasswordChanged += (_, _) =>
            {
                model.Password = password.Password;
                AutomationProperties.SetHelpText(
                    password,
                    model.HasPasswordError
                        ? string.Concat(
                            localization.Get("FileShareLinkPasswordHelp"),
                            " ",
                            localization.Get("FileShareLinkPasswordError"))
                        : localization.Get("FileShareLinkPasswordHelp"));
                passwordError.Visibility = model.HasPasswordError
                    ? Visibility.Visible
                    : Visibility.Collapsed;
                create.IsEnabled = model.CanCreate;
            };
            panel.Children.Add(password);
            panel.Children.Add(new TextBlock
            {
                Text = localization.Get("FileShareLinkPasswordHelp"),
                TextWrapping = TextWrapping.Wrap,
                Style = Application.Current.Resources["CaptionTextBlockStyle"] as Style,
            });
            panel.Children.Add(passwordError);

            var expiration = new ComboBox
            {
                Header = localization.Get("FileShareLinkExpirationLabel"),
                MinHeight = 44,
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            AddExpirationItem(expiration, localization.Get("FileShareLinkExpirationNever"), FileShareLinkExpiration.Never);
            AddExpirationItem(expiration, localization.Get("FileShareLinkExpiration7Days"), FileShareLinkExpiration.SevenDays);
            AddExpirationItem(expiration, localization.Get("FileShareLinkExpiration30Days"), FileShareLinkExpiration.ThirtyDays);
            AddExpirationItem(expiration, localization.Get("FileShareLinkExpiration90Days"), FileShareLinkExpiration.NinetyDays);
            expiration.SelectedIndex = (int)model.Expiration;
            expiration.SelectionChanged += (_, _) =>
            {
                if (expiration.SelectedItem is ComboBoxItem { Tag: FileShareLinkExpiration value })
                {
                    model.Expiration = value;
                }
            };
            panel.Children.Add(expiration);

            create.Click += async (_, _) =>
            {
                var creation = model.CreateAsync();
                render();
                await creation;
                if (model.State == FileShareLinkPresentationState.NeedsReview)
                {
                    _shareReviewBlocker.Block(_profileId, model.TargetPath);
                }
                render();
            };
            panel.Children.Add(create);
            return panel;
        }

        if (model.State == FileShareLinkPresentationState.Creating)
        {
            panel.Children.Add(new ProgressRing
            {
                IsActive = true,
                Width = 32,
                Height = 32,
                HorizontalAlignment = HorizontalAlignment.Left,
            });
            var message = new TextBlock
            {
                Text = localization.Get(model.IsCancellationRequested
                    ? "FileShareLinkCancellingMessage"
                    : "FileShareLinkCreatingMessage"),
                TextWrapping = TextWrapping.Wrap,
            };
            AutomationProperties.SetLiveSetting(message, AutomationLiveSetting.Polite);
            panel.Children.Add(message);
            var cancel = new Button
            {
                Content = localization.Get("ActionCancel"),
                MinHeight = 44,
                IsEnabled = !model.IsCancellationRequested,
            };
            cancel.Click += (_, _) =>
            {
                model.RequestCancellation();
                render();
            };
            panel.Children.Add(cancel);
            return panel;
        }

        var stateMessage = new InfoBar
        {
            IsOpen = true,
            IsClosable = false,
            Severity = model.State == FileShareLinkPresentationState.Success
                ? InfoBarSeverity.Success
                : model.State == FileShareLinkPresentationState.NeedsReview
                    ? InfoBarSeverity.Warning
                    : InfoBarSeverity.Error,
            Message = ShareDialogMessage(model.State, localization),
        };
        AutomationProperties.SetLiveSetting(stateMessage, AutomationLiveSetting.Polite);
        panel.Children.Add(stateMessage);

        if (model.State == FileShareLinkPresentationState.Success && model.ConfirmedUrl is { } url)
        {
            var confirmedUrl = new TextBox
            {
                Text = url.AbsoluteUri,
                IsReadOnly = true,
                TextWrapping = TextWrapping.Wrap,
                MinHeight = 44,
            };
            AutomationProperties.SetName(
                confirmedUrl,
                localization.Get("FileShareLinkConfirmedUrlAutomationName"));
            panel.Children.Add(confirmedUrl);
            if (model.ConfirmedLink?.HasPassword == true)
            {
                panel.Children.Add(new TextBlock
                {
                    Text = localization.Get("FileShareLinkProtectedNote"),
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            if (model.ConfirmedLink?.ExpiresOn is { } expiresOn)
            {
                panel.Children.Add(new TextBlock
                {
                    Text = localization.Format(
                        "FileShareLinkExpiresOn",
                        expiresOn.ToString("d", System.Globalization.CultureInfo.CurrentCulture)),
                    TextWrapping = TextWrapping.Wrap,
                });
            }

            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
            };
            var copyStatus = new TextBlock
            {
                VerticalAlignment = VerticalAlignment.Center,
                Visibility = Visibility.Collapsed,
            };
            AutomationProperties.SetLiveSetting(copyStatus, AutomationLiveSetting.Polite);
            var copy = new Button
            {
                Content = localization.Get("FileShareLinkCopyAction"),
                MinHeight = 44,
                AccessKey = "C",
            };
            copy.Click += (_, _) =>
            {
                if (model.ConfirmedUrl is not { } confirmed)
                {
                    return;
                }
                try
                {
                    copyStatus.Text = _clipboard.SetUri(confirmed)
                        ? localization.Get("FileShareLinkCopiedMessage")
                        : localization.Get("FileShareLinkCopyFailedMessage");
                }
                catch
                {
                    copyStatus.Text = localization.Get("FileShareLinkCopyFailedMessage");
                }
                copyStatus.Visibility = Visibility.Visible;
            };
            actions.Children.Add(copy);
            var share = new Button
            {
                Content = localization.Get("FileShareLinkSystemShareAction"),
                MinHeight = 44,
                IsEnabled = model.CanSystemShare,
            };
            ToolTipService.SetToolTip(
                share,
                _systemShare.IsAvailable
                    ? localization.Get("FileShareLinkSystemShareAction")
                    : localization.Get("FileShareLinkSystemShareUnavailable"));
            share.Click += (_, _) =>
            {
                if (model.ConfirmedUrl is { } confirmed)
                {
                    _systemShare.TryShow(confirmed);
                }
            };
            actions.Children.Add(share);
            actions.Children.Add(copyStatus);
            panel.Children.Add(actions);
            if (!_systemShare.IsAvailable)
            {
                panel.Children.Add(new TextBlock
                {
                    Text = localization.Get("FileShareLinkSystemShareUnavailable"),
                    TextWrapping = TextWrapping.Wrap,
                });
            }
        }
        else if (model.CanRetry || model.State == FileShareLinkPresentationState.Cancelled)
        {
            var retry = new Button
            {
                Content = localization.Get("FileShareLinkTryAgainAction"),
                MinHeight = 44,
            };
            retry.Click += (_, _) =>
            {
                model.Retry();
                render();
            };
            panel.Children.Add(retry);
        }
        return new ScrollViewer
        {
            Content = panel,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            MaxHeight = 600,
        };
    }

    private static void AddExpirationItem(
        ComboBox comboBox,
        string text,
        FileShareLinkExpiration expiration) =>
        comboBox.Items.Add(new ComboBoxItem { Content = text, Tag = expiration, MinHeight = 44 });

    private static string ShareDialogTitle(
        FileShareLinkPresentationState state,
        LocalizationService localization) => state switch
    {
        FileShareLinkPresentationState.Success => localization.Get("FileShareLinkSuccessTitle"),
        FileShareLinkPresentationState.NeedsReview => localization.Get("FileShareLinkReviewTitle"),
        FileShareLinkPresentationState.TargetChanged => localization.Get("FileShareLinkChangedTitle"),
        FileShareLinkPresentationState.PermissionDenied => localization.Get("FileShareLinkPermissionTitle"),
        FileShareLinkPresentationState.Unsupported => localization.Get("FileShareLinkUnsupportedTitle"),
        FileShareLinkPresentationState.Failure => localization.Get("FileShareLinkFailureTitle"),
        FileShareLinkPresentationState.Cancelled => localization.Get("FileShareLinkCancelledTitle"),
        _ => localization.Get("FileShareLinkTitle"),
    };

    private static string ShareDialogMessage(
        FileShareLinkPresentationState state,
        LocalizationService localization) => localization.Get(state switch
    {
        FileShareLinkPresentationState.Success => "FileShareLinkSuccessMessage",
        FileShareLinkPresentationState.NeedsReview => "FileShareLinkReviewMessage",
        FileShareLinkPresentationState.TargetChanged => "FileShareLinkChangedMessage",
        FileShareLinkPresentationState.PermissionDenied => "FileShareLinkPermissionMessage",
        FileShareLinkPresentationState.Unsupported => "FileShareLinkUnsupportedMessage",
        FileShareLinkPresentationState.Cancelled => "FileShareLinkCancelledMessage",
        _ => "FileShareLinkFailureMessage",
    });

    private static async Task RunAsync(Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (ObjectDisposedException)
        {
            // 页面离开时取消中的操作不再回写界面。
        }
    }

    private void UpdateState()
    {
        if (ContentState is null)
        {
            return;
        }

        LoadingState.Visibility = _viewModel.ContentState == FileBrowserContentState.Loading
            ? Visibility.Visible
            : Visibility.Collapsed;
        EmptyState.Visibility = _viewModel.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
        FilteredEmptyState.Visibility = _viewModel.IsFilteredEmpty ? Visibility.Visible : Visibility.Collapsed;
        ErrorState.Visibility = _viewModel.HasError ? Visibility.Visible : Visibility.Collapsed;
        ContentState.Visibility = _viewModel.HasContent ? Visibility.Visible : Visibility.Collapsed;
        StorageLoadingState.Visibility = _viewModel.IsLoadingStorageSpace
            ? Visibility.Visible
            : Visibility.Collapsed;
        StorageAvailableState.Visibility = _viewModel.HasStorageSpace
            ? Visibility.Visible
            : Visibility.Collapsed;
        StorageUnavailableState.Visibility = _viewModel.IsStorageSpaceUnavailable
            ? Visibility.Visible
            : Visibility.Collapsed;

        FileList.Visibility = _viewModel.HasContent && _viewModel.IsListLayout
            ? Visibility.Visible
            : Visibility.Collapsed;
        FileGrid.Visibility = _viewModel.HasContent && _viewModel.IsGridLayout
            ? Visibility.Visible
            : Visibility.Collapsed;
        ListLayoutButton.IsChecked = _viewModel.IsListLayout;
        GridLayoutButton.IsChecked = _viewModel.IsGridLayout;
        SortNameItem.IsChecked = _viewModel.SortField == FileListSortField.Name;
        SortModifiedItem.IsChecked = _viewModel.SortField == FileListSortField.ModifiedTime;
        SortSizeItem.IsChecked = _viewModel.SortField == FileListSortField.Size;
        SortAscendingItem.IsChecked =
            _viewModel.SortDirection == FileListSortDirection.Ascending;
        SortDescendingItem.IsChecked =
            _viewModel.SortDirection == FileListSortDirection.Descending;
        TypeAllItem.IsChecked = _viewModel.TypeFilter == FileListTypeFilter.All;
        TypeFilesItem.IsChecked = _viewModel.TypeFilter == FileListTypeFilter.Files;
        TypeFoldersItem.IsChecked = _viewModel.TypeFilter == FileListTypeFilter.Folders;

        SortModifiedItem.IsEnabled = _viewModel.CanChooseNonNameSort;
        SortSizeItem.IsEnabled = _viewModel.CanChooseNonNameSort;
        SortButton.IsEnabled = !_viewModel.IsLoading;
        TypeFilterButton.IsEnabled =
            _viewModel.CanChooseTypeFilter && !_viewModel.IsLoading;

        BackButton.IsEnabled = _viewModel.CanGoBack && !_viewModel.IsLoading;
        UpButton.IsEnabled = _viewModel.CanGoUp && !_viewModel.IsLoading;
        RefreshButton.IsEnabled = !_viewModel.IsLoading && !_viewModel.IsLoadingMore;
        DownloadButton.IsEnabled =
            !_viewModel.IsLoading && _viewModel.SelectedItem is not null;
        PreviewButton.IsEnabled =
            !_viewModel.IsLoading && _viewModel.SelectedItem?.IsDirectory == false;
        UpdateMutationControls();
        UpdateCopyMoveControls();
        UpdateRecycleControls();
        ShareLinkButton.IsEnabled =
            !_viewModel.IsLoading &&
            !_isClosingShareLink &&
            _shareLinkDialog is null &&
            _viewModel.SelectedItem is not null;
        ShareLinkButton.Visibility = IsReadOnlyLocation()
            ? Visibility.Collapsed
            : Visibility.Visible;
        ManageShareLinksButton.IsEnabled =
            _shareRepository is not null &&
            _shareManagementDialog?.IsOpen != true &&
            _shareLinkDialog is null &&
            !_isClosingShareLink;
        DirectorySizeButton.IsEnabled = CanShowDirectorySize();
        UploadButton.IsEnabled =
            !_viewModel.IsLoading &&
            !_isChoosingUpload &&
            !IsReadOnlyLocation() &&
            !string.IsNullOrWhiteSpace(_viewModel.CurrentPath);
        UploadButton.Visibility = IsReadOnlyLocation()
            ? Visibility.Collapsed
            : Visibility.Visible;
        UploadFolderButton.IsEnabled = CanUploadFolder();
        UploadFolderButton.Visibility =
            IsReadOnlyLocation() ||
                _mutationRepository?.FileMutationAvailability.CanCreateFolder != true
                ? Visibility.Collapsed
                : Visibility.Visible;
        UpdateBatchDownloadControls();
        UpdateBatchCopyMoveControls();
        UpdateBatchRecycleControls();
        UpdateArchiveCompressionControls();
        UpdateArchiveExtractionControls();
        var canCrossNasCopy = CanCrossNasCopyMove();
        CrossNasCopyButton.IsEnabled = canCrossNasCopy;
        CrossNasCopyButton.Visibility = canCrossNasCopy
            ? Visibility.Visible
            : Visibility.Collapsed;
        CrossNasMoveButton.IsEnabled = false;
        CrossNasMoveButton.Visibility = Visibility.Collapsed;
        LocationsButton.IsEnabled = _locationsViewModel.IsActive;
        FilterBox.IsEnabled = !_viewModel.IsLoading;
        SearchProgressState.Visibility = _viewModel.IsSearching
            ? Visibility.Visible
            : Visibility.Collapsed;
        SearchStatus.IsOpen = _viewModel.HasSearchError ||
            _viewModel.HasSearchTruncationNotice;
        SearchStatus.Visibility = SearchStatus.IsOpen
            ? Visibility.Visible
            : Visibility.Collapsed;
        SearchStatus.Severity = _viewModel.HasSearchError
            ? InfoBarSeverity.Error
            : InfoBarSeverity.Warning;
        SearchStatus.Title = _viewModel.HasSearchError
            ? LocalizationService.Current.Get("FileBrowserSearchErrorTitle")
            : LocalizationService.Current.Get("FileBrowserSearchTruncatedTitle");
        SearchStatus.Message = _viewModel.HasSearchError
            ? LocalizationService.Current.Get("FileBrowserSearchErrorMessage")
            : LocalizationService.Current.Format(
                "FileBrowserSearchTruncatedMessage",
                _viewModel.SearchResultCount);
        if (SearchStatus.ActionButton is Button searchRetry)
        {
            searchRetry.Visibility = _viewModel.HasSearchError
                ? Visibility.Visible
                : Visibility.Collapsed;
        }

        if (_selectionNeedsScroll)
        {
            _selectionNeedsScroll = false;
            if (_viewModel.SelectedItem is { } selected)
            {
                if (_viewModel.IsListLayout)
                {
                    FileList.ScrollIntoView(selected);
                }
                else
                {
                    FileGrid.ScrollIntoView(selected);
                }
            }
        }

        LoadMoreButton.Visibility = _viewModel.CanLoadMore || _viewModel.HasLoadMoreError
            ? Visibility.Visible
            : Visibility.Collapsed;
        LoadMoreButton.IsEnabled = _viewModel.CanLoadMore;
        LoadMoreProgress.IsActive = _viewModel.IsLoadingMore;
        LoadMoreProgress.Visibility = _viewModel.IsLoadingMore
            ? Visibility.Visible
            : Visibility.Collapsed;
        LoadMoreError.IsOpen = _viewModel.HasLoadMoreError;
        UpdatePreviewLayout();
    }

    private async Task OpenPreviewAsync(FileBrowserEntry entry)
    {
        if (PreviewPane.HasUnsavedTextEdits)
        {
            var discard = await ShowUnsavedDiscardDialogAsync();
            if (!discard)
            {
                return;
            }
            PreviewPane.ConfirmDiscardTextEdits();
        }
        await PreviewPane.CloseAsync();
        await _previewViewModel.OpenAsync(_previewRepository, _profileId, entry.Item);
        _textEditViewModel.Attach(_previewRepository, entry.Item);
        PreviewPane.SetSaveCopyEnabled(
            _previewViewModel.TryGetSaveCopyTarget(entry.Item, out _));
        UpdatePreviewLayout();
        PreviewPane.FocusHeading();
    }

    private async Task ClosePreviewAsync()
    {
        if (!_previewViewModel.IsOpen)
        {
            return;
        }
        if (PreviewPane.HasUnsavedTextEdits)
        {
            var discard = await ShowUnsavedDiscardDialogAsync();
            if (!discard)
            {
                return;
            }
            PreviewPane.ConfirmDiscardTextEdits();
        }
        await PreviewPane.CloseAsync();
        await _previewViewModel.CloseAsync();
        UpdatePreviewLayout();
        if (_viewModel.SelectedItem is { } selected)
        {
            if (_viewModel.IsListLayout)
            {
                FileList.ScrollIntoView(selected);
                FileList.Focus(FocusState.Programmatic);
            }
            else
            {
                FileGrid.ScrollIntoView(selected);
                FileGrid.Focus(FocusState.Programmatic);
            }
        }
    }

    private async Task<bool> ShowUnsavedDiscardDialogAsync()
    {
        var localization = LocalizationService.Current;
        var dialog = new ContentDialog
        {
            Title = localization.Get("FileTextEdit_UnsavedTitle"),
            Content = localization.Get("FileTextEdit_UnsavedMessage"),
            PrimaryButtonText = localization.Get("FileTextEdit_Discard"),
            CloseButtonText = localization.Get("FileTextEdit_KeepEditing"),
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot,
        };
        var result = await dialog.ShowAsync();
        return result == ContentDialogResult.Primary;
    }

    private async void PreviewPane_CloseRequested(object? sender, EventArgs e) =>
        await ClosePreviewAsync();

    private void PreviewPane_UnsavedDiscardRequested(object? sender, EventArgs e)
    {
        _ = ShowUnsavedDiscardDialogAndMaybeDiscardAsync();
    }

    private async Task ShowUnsavedDiscardDialogAndMaybeDiscardAsync()
    {
        var discard = await ShowUnsavedDiscardDialogAsync();
        if (discard)
        {
            PreviewPane.ConfirmDiscardTextEdits();
        }
    }

    private async void PreviewPane_RetryRequested(object? sender, EventArgs e)
    {
        if (_previewViewModel.Snapshot.Item is { } item)
        {
            await _previewViewModel.OpenAsync(_previewRepository, _profileId, item);
        }
    }

    private async void PreviewPane_SaveCopyRequested(
        object? sender,
        FilePreviewSaveCopyRequestedEventArgs e)
    {
        if (e.Target.ProfileId != _profileId ||
            !_previewViewModel.TryGetSaveCopyTarget(
                _viewModel.SelectedItem?.Item,
                out var current) ||
            current is null ||
            current.ProfileId != e.Target.ProfileId ||
            !string.Equals(current.Item.Path, e.Target.Item.Path, StringComparison.Ordinal))
        {
            return;
        }
        await DownloadItemAsync(e.Target.ProfileId, e.Target.Item);
    }

    private void FilesPage_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateLocationsLayout();
        UpdatePreviewLayout();
    }

    private void UpdateLocationsLayout()
    {
        if (LocationsSplitView is null)
        {
            return;
        }
        var isWide = ActualWidth >= 900;
        if (_locationsAreWide == isWide)
        {
            return;
        }
        _locationsAreWide = isWide;
        LocationsSplitView.DisplayMode = isWide
            ? SplitViewDisplayMode.Inline
            : SplitViewDisplayMode.Overlay;
        LocationsSplitView.IsPaneOpen = isWide;
        if (!isWide)
        {
            LocationsPane.CancelOpening();
        }
    }

    private void UpdatePreviewLayout()
    {
        if (PreviewPane is null)
        {
            return;
        }
        var isOpen = _previewViewModel.IsOpen;
        var isWide = ActualWidth >= (_locationsAreWide == true ? 1280 : 1000);
        PreviewPane.Visibility = isOpen ? Visibility.Visible : Visibility.Collapsed;
        PreviewColumn.Width = isOpen
            ? isWide ? new GridLength(420) : new GridLength(1, GridUnitType.Star)
            : new GridLength(0);
        BrowserColumn.Width = isOpen && !isWide
            ? new GridLength(0)
            : new GridLength(1, GridUnitType.Star);
        BrowserSurface.Visibility = isOpen && !isWide
            ? Visibility.Collapsed
            : Visibility.Visible;
        BackButton.IsEnabled = _previewViewModel.IsOpen ||
            (_viewModel.CanGoBack && !_viewModel.IsLoading);
    }

    public async Task CloseAsync()
    {
        if (_disposed)
        {
            return;
        }
        DeactivateFileUploadDrop();
        LocationsPane.CancelOpening();
        _locationsViewModel.Deactivate();
        CloseShareManagementDialog();
        CloseShareLinkDialog();
        CloseMutationDialog();
        CloseCopyMoveDialog();
        CloseBatchCopyMoveDialog();
        CloseBatchRecycleDialog();
        CloseArchiveCompressionDialog();
        CloseArchiveExtractionDialog();
        CloseRecycleDialog();
        await CloseDirectorySizeDialogAsync();
        await PreviewPane.CloseAsync();
        if (_previewViewModel.IsOpen)
        {
            await _previewViewModel.CloseAsync();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        CloseDirectorySizeDialog();
        DeactivateFileUploadDrop();
        CloseShareManagementDialog();
        CloseShareLinkDialog();
        CloseMutationDialog();
        CloseCopyMoveDialog();
        CloseBatchCopyMoveDialog();
        CloseBatchRecycleDialog();
        CloseArchiveCompressionDialog();
        CloseArchiveExtractionDialog();
        CloseRecycleDialog();
        Loaded -= FilesPage_Loaded;
        _transfers.UploadFinished -= Transfers_UploadFinished;
        _transfers.UploadBatchFinished -= Transfers_UploadBatchFinished;
        _transfers.FolderUploadBatchFinished -= Transfers_FolderUploadBatchFinished;
        _transfers.DownloadBatchFinished -= Transfers_DownloadBatchFinished;
        _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        _locationsViewModel.PropertyChanged -= LocationsViewModel_PropertyChanged;
        _previewViewModel.PropertyChanged -= PreviewViewModel_PropertyChanged;
        PreviewPane.CloseRequested -= PreviewPane_CloseRequested;
        PreviewPane.RetryRequested -= PreviewPane_RetryRequested;
        PreviewPane.SaveCopyRequested -= PreviewPane_SaveCopyRequested;
        LocationsPane.LocationOpened -= LocationsPane_LocationOpened;
        LocationsPane.Dispose();
        _locationsViewModel.Dispose();
        PreviewPane.Dispose();
        _previewViewModel.Dispose();
        _viewModel.Dispose();
    }

    private static IFileCopyMoveFolderSource? CreateCopyMoveFolderSource(
        string profileId, IDsmRepository repository, IFileLocationsRepository? locations) =>
        locations is null ? null : new RepositoryFileCopyMoveFolderSource(
            Guid.Parse(profileId), new RepositoryFileBrowserDataSource(repository), locations);

    private void CloseShareLinkDialog()
    {
        var dialog = _shareLinkDialog;
        var model = _shareLinkModel;
        _shareLinkDialog = null;
        _shareLinkModel = null;
        if (model?.State == FileShareLinkPresentationState.Creating)
        {
            _shareReviewBlocker.Block(_profileId, model.TargetPath);
        }
        model?.RequestCancellation();
        model?.Dispose();
        if (dialog is null)
        {
            return;
        }
        _isClosingShareLink = true;
        dialog.Hide();
    }

    private void FileList_DragItemsStarting(object sender, DragItemsStartingEventArgs args)
    {
        if (IsReadOnlyLocation() || _copyMoveRepository is null)
        {
            args.Cancel = true;
            return;
        }
        var entries = args.Items
            .OfType<FileBrowserEntry>()
            .Where(e => FileCopyMoveViewModel.IsDestination(e.Path))
            .ToArray();
        if (entries.Length == 0)
        {
            args.Cancel = true;
            return;
        }
        var paths = string.Join("\n", entries.Select(e => e.Path));
        args.Data.SetText(paths);
        args.Data.RequestedOperation = DataPackageOperation.Move;
    }

    private void FileList_DragOver(object sender, DragEventArgs args)
    {
        if (IsReadOnlyLocation() || _copyMoveRepository is null ||
            !args.DataView.Contains(StandardDataFormats.Text))
        {
            args.AcceptedOperation = DataPackageOperation.None;
            return;
        }
        var target = FindDropTargetFolder(args);
        args.AcceptedOperation = target is not null
            ? DataPackageOperation.Move
            : DataPackageOperation.None;
    }

    private async void FileList_Drop(object sender, DragEventArgs args)
    {
        if (IsReadOnlyLocation() || _copyMoveRepository is null) return;

        var target = FindDropTargetFolder(args);
        if (target is null) return;

        var paths = await args.DataView.GetTextAsync();
        if (string.IsNullOrWhiteSpace(paths)) return;

        var sourcePaths = paths.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        var sources = _viewModel.Items
            .Where(e => sourcePaths.Contains(e.Path))
            .Select(e => e.Item)
            .Where(item => item.CanDelete && FileCopyMoveViewModel.IsDestination(item.Path))
            .ToArray();
        if (sources.Length == 0) return;

        if (FileCopyMoveBatchViewModel.Validate(sources, FileCopyMoveOperation.Move) !=
            FileCopyMoveBatchValidationStatus.Valid) return;

        var sourceFolder = MutationParent(sources[0].Path);
        if (string.Equals(sourceFolder, target, StringComparison.Ordinal)) return;

        var batch = new FileCopyMoveBatchViewModel(
            _copyMoveRepository,
            _copyMoveFolderSource!,
            _profileId,
            sources,
            FileCopyMoveOperation.Move,
            _copyMoveReviewBlocker!);
        await batch.LoadFoldersAsync(target, destinationCanWrite: true);
        if (!batch.CanSubmit) return;

        await batch.SubmitAsync();
        if (batch.State != FileCopyMoveBatchState.Completed) return;
        if (batch.Summary.ConfirmedCount <= 0) return;

        await ClosePreviewAsync();
        await RunAsync(_viewModel.RefreshAsync);
        UpdateState();
        ShowDragMoveUndo(sources, sourceFolder, target);
    }

    private string? FindDropTargetFolder(DragEventArgs args)
    {
        var list = VisibleFilesControl();
        if (list is null) return null;

        var position = args.GetPosition(list);
        var element = list.ContainerFromIndex(0) as UIElement;
        var container = list.ContainerFromIndex(-1);
        // 从当前位置沿可视树向上查找容器元素。
        foreach (var item in _viewModel.Items)
        {
            if (!item.Item.IsDirectory) continue;
            var itemContainer = list.ContainerFromItem(item) as UIElement;
            if (itemContainer is null) continue;
            var bounds = itemContainer.TransformToVisual(list).TransformBounds(
                new Windows.Foundation.Rect(
                    0,
                    0,
                    itemContainer.RenderSize.Width,
                    itemContainer.RenderSize.Height));
            if (bounds.Contains(position))
            {
                return item.Path;
            }
        }
        return null;
    }

    private void ShowDragMoveUndo(IReadOnlyList<FileItem> sources, string sourceFolder, string destinationFolder)
    {
        _dragMoveUndoCts?.Cancel();
        _dragMoveUndoCts?.Dispose();
        _dragMoveUndoCts = new CancellationTokenSource();

        var undo = new DragMoveUndo(
            Guid.NewGuid(),
            sources,
            sourceFolder,
            destinationFolder,
            DateTime.UtcNow.AddSeconds(10));
        _dragMoveUndo = undo;

        var localization = LocalizationService.Current;
        FileMoveUndoStatus.Message = localization.Format(
            "FileMoveUndoMessage", sources.Count, destinationFolder);
        var undoButton = new Button
        {
            Content = localization.Get("FileMoveUndoButton.Text"),
            MinHeight = 44,
        };
        undoButton.Click += async (_, _) => await UndoDragMoveAsync(undo);
        FileMoveUndoStatus.ActionButton = undoButton;
        FileMoveUndoStatus.Severity = InfoBarSeverity.Success;
        FileMoveUndoStatus.IsOpen = true;

        _ = DismissUndoAfterDelay(undo, _dragMoveUndoCts.Token);
    }

    private async Task DismissUndoAfterDelay(DragMoveUndo undo, CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(10_000, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (!cancellationToken.IsCancellationRequested &&
            ReferenceEquals(_dragMoveUndo, undo))
        {
            _dragMoveUndo = null;
            FileMoveUndoStatus.IsOpen = false;
        }
    }

    private async Task UndoDragMoveAsync(DragMoveUndo undo)
    {
        _dragMoveUndoCts?.Cancel();
        _dragMoveUndo = null;
        FileMoveUndoStatus.IsOpen = false;

        if (_copyMoveRepository is null || _copyMoveFolderSource is null ||
            _copyMoveReviewBlocker is null || _disposed) return;

        var batch = new FileCopyMoveBatchViewModel(
            _copyMoveRepository,
            _copyMoveFolderSource,
            _profileId,
            undo.Items.ToArray(),
            FileCopyMoveOperation.Move,
            _copyMoveReviewBlocker);
        await batch.LoadFoldersAsync(undo.SourceFolder, destinationCanWrite: true);
        if (!batch.CanSubmit) return;

        await batch.SubmitAsync();
        await RunAsync(_viewModel.RefreshAsync);
        UpdateState();
    }

    private static string MutationParent(string path)
    {
        var separator = path.LastIndexOf('/');
        return separator <= 0 ? string.Empty : path[..separator];
    }

    private sealed record DragMoveUndo(
        Guid Id,
        IReadOnlyList<FileItem> Items,
        string SourceFolder,
        string DestinationFolder,
        DateTime ExpiresAt);

}
