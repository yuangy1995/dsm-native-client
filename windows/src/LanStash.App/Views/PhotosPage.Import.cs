using LanStash.App.Features.Photos.Import;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace LanStash.App.Views;

public sealed partial class PhotosPage
{
    private PhotoImportCoordinator? _photoImport;
    private bool _photoImportPageLoaded;
    private long _photoDragGeneration;

    private void InitializePhotoImport()
    {
        _photoImport = new PhotoImportCoordinator(_transfers);
        _photoImport.Changed += PhotoImport_Changed;
    }

    private async void Import_Click(object sender, RoutedEventArgs e) =>
        await StartPhotoImportAsync();

    private async void ImportAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_photoImport?.CanStart != true)
        {
            return;
        }
        args.Handled = true;
        await StartPhotoImportAsync();
    }

    private async Task StartPhotoImportAsync()
    {
        if (_disposed || _photoImport is null)
        {
            return;
        }
        UpdatePhotoImportContext();
        await _photoImport.StartAsync();
        UpdatePhotoImportPresentation();
    }

    private async void PhotoImport_DragOver(object sender, DragEventArgs e)
    {
        var generation = Interlocked.Increment(ref _photoDragGeneration);
        e.AcceptedOperation = DataPackageOperation.None;
        var deferral = e.GetDeferral();
        try
        {
            UpdatePhotoImportContext();
            var sourcePath = await TryGetSingleDroppedMediaPathAsync(e.DataView);
            if (generation != Volatile.Read(ref _photoDragGeneration) ||
                !CanAcceptPhotoDrop() || sourcePath is null)
            {
                if (generation == Volatile.Read(ref _photoDragGeneration))
                {
                    PhotoImportDropOverlay.Visibility = Visibility.Collapsed;
                }
                return;
            }
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = LocalizationService.Current.Get(
                "PhotoImportDropCaption");
            e.DragUIOverride.IsCaptionVisible = true;
            PhotoImportDropOverlay.Visibility = Visibility.Visible;
        }
        finally
        {
            deferral.Complete();
        }
    }

    private void PhotoImport_DragLeave(object sender, DragEventArgs e)
    {
        Interlocked.Increment(ref _photoDragGeneration);
        PhotoImportDropOverlay.Visibility = Visibility.Collapsed;
    }

    private async void PhotoImport_Drop(object sender, DragEventArgs e)
    {
        Interlocked.Increment(ref _photoDragGeneration);
        PhotoImportDropOverlay.Visibility = Visibility.Collapsed;
        var deferral = e.GetDeferral();
        try
        {
            UpdatePhotoImportContext();
            var sourcePath = await TryGetSingleDroppedMediaPathAsync(e.DataView);
            if (!CanAcceptPhotoDrop() || sourcePath is null)
            {
                _photoImport?.ReportInvalidDrop();
                UpdatePhotoImportPresentation();
                return;
            }
            await _photoImport!.StartDroppedAsync(sourcePath);
            UpdatePhotoImportPresentation();
        }
        finally
        {
            deferral.Complete();
        }
    }

    private bool CanAcceptPhotoDrop() =>
        !_disposed &&
        !_viewModel.IsLoading &&
        PhotoViewerHost.Visibility != Visibility.Visible &&
        _photoImport?.CanStart == true;

    private static async Task<string?> TryGetSingleDroppedMediaPathAsync(
        DataPackageView dataView)
    {
        try
        {
            if (!dataView.Contains(StandardDataFormats.StorageItems))
            {
                return null;
            }
            var items = await dataView.GetStorageItemsAsync();
            if (items.Count != 1 ||
                items[0] is not StorageFile file ||
                string.IsNullOrWhiteSpace(file.Path) ||
                !WindowsTransferPickerService.IsSupportedMediaPath(file.Path))
            {
                return null;
            }
            return file.Path;
        }
        catch
        {
            return null;
        }
    }

    private void PhotoImport_Changed()
    {
        DispatcherQueue.TryEnqueue(async () =>
        {
            if (_disposed || _photoImport is null)
            {
                return;
            }
            UpdatePhotoImportContext();
            UpdatePhotoImportPresentation();
            if (_photoImport.TryConsumeCurrentConfirmedCompletion(out var target))
            {
                if (target?.Mode == PhotoImportMode.Timeline)
                {
                    await TimelineView.RefreshAsync();
                }
                else
                {
                    await RunLocationChangeAsync(_viewModel.RefreshAsync);
                }
            }
            else
            {
                UpdatePhotoImportPresentation();
            }
        });
    }

    private void UpdatePhotoImportState()
    {
        if (_photoImport is null || ImportButton is null)
        {
            return;
        }
        UpdatePhotoImportContext();
        UpdatePhotoImportPresentation();
    }

    private void UpdatePhotoImportContext()
    {
        if (_photoImport is null || _disposed)
        {
            return;
        }
        var context = _photoImportPageLoaded &&
            _viewModel.ActiveProfileId == _dataSource.ProfileId &&
            _viewModel.SelectedSpace is { } space
            ? new PhotoImportContext(
                _dataSource.ProfileId,
                _dataSource,
                space,
                _viewModel.CurrentPath,
                TimelineMode.IsChecked == true
                    ? PhotoImportMode.Timeline
                    : PhotoImportMode.Folder)
            : null;
        _photoImport.UpdateContext(context);
    }

    private void UpdatePhotoImportPresentation()
    {
        if (_photoImport is null || ImportButton is null)
        {
            return;
        }
        ImportButton.Visibility = _photoImport.HasEligibleTarget
            ? Visibility.Visible
            : Visibility.Collapsed;
        ImportButton.IsEnabled = !_viewModel.IsLoading && _photoImport.CanStart;
        ImportProgress.IsActive = _photoImport.Phase is
            PhotoImportPhase.Choosing or PhotoImportPhase.PreparingDrop;
        ImportProgress.Visibility = ImportProgress.IsActive
            ? Visibility.Visible
            : Visibility.Collapsed;

        var localization = LocalizationService.Current;
        AutomationProperties.SetName(
            ImportProgress,
            localization.Get(
                _photoImport.Phase == PhotoImportPhase.PreparingDrop
                    ? "PhotoImportPreparingDrop"
                    : "PhotoImportChoosing.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        if (_viewModel.SelectedSpace is { } space)
        {
            var targetText = TimelineMode.IsChecked == true
                ? localization.Format(
                    "PhotoImportTimelineTargetMessage",
                    LocalizedSpaceName(space.Id),
                    space.RootPath)
                : localization.Format(
                    "PhotoImportFolderTargetMessage",
                    _viewModel.CurrentPath);
            PhotoImportTargetText.Text = targetText;
            AutomationProperties.SetName(PhotoImportTargetText, targetText);
        }
        else
        {
            PhotoImportTargetText.Text = string.Empty;
            AutomationProperties.SetName(
                PhotoImportTargetText,
                localization.Get("PhotoImportTarget.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        }

        ImportStatus.IsOpen = _photoImport.Phase is not PhotoImportPhase.Idle and
            not PhotoImportPhase.Choosing and not PhotoImportPhase.PreparingDrop;
        ImportStatus.Severity = _photoImport.Phase switch
        {
            PhotoImportPhase.Confirmed or PhotoImportPhase.ConfirmedElsewhere =>
                InfoBarSeverity.Success,
            PhotoImportPhase.Activity => InfoBarSeverity.Informational,
            PhotoImportPhase.NeedsReview => InfoBarSeverity.Warning,
            _ => InfoBarSeverity.Error,
        };
        var key = _photoImport.Phase switch
        {
            PhotoImportPhase.Activity => "PhotoImportActivityMessage",
            PhotoImportPhase.Confirmed => "PhotoImportSuccessMessage",
            PhotoImportPhase.ConfirmedElsewhere => "PhotoImportSuccessElsewhereMessage",
            PhotoImportPhase.NeedsReview => "PhotoImportNeedsReviewMessage",
            PhotoImportPhase.Cancelled => "PhotoImportCancelledMessage",
            PhotoImportPhase.PermissionDenied => "PhotoImportPermissionMessage",
            PhotoImportPhase.Unsupported => "PhotoImportUnsupportedMessage",
            PhotoImportPhase.InvalidDrop => "PhotoImportInvalidDropMessage",
            _ => "PhotoImportFailureMessage",
        };
        ImportStatus.Message = localization.Get(key);
    }

    private void ActivatePhotoImportPage() => _photoImportPageLoaded = true;

    private void DeactivatePhotoImport()
    {
        Interlocked.Increment(ref _photoDragGeneration);
        PhotoImportDropOverlay.Visibility = Visibility.Collapsed;
        _photoImportPageLoaded = false;
        _photoImport?.Deactivate();
    }

    private void DisposePhotoImport()
    {
        if (_photoImport is null)
        {
            return;
        }
        _photoImport.Changed -= PhotoImport_Changed;
        _photoImport.Dispose();
        _photoImport = null;
    }
}
