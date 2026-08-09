using LanStash.App.Features.Photos.Import;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class PhotosPage
{
    private PhotoImportCoordinator? _photoImport;
    private bool _photoImportPageLoaded;

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
        ImportProgress.IsActive = _photoImport.Phase == PhotoImportPhase.Choosing;
        ImportProgress.Visibility = ImportProgress.IsActive
            ? Visibility.Visible
            : Visibility.Collapsed;

        var localization = LocalizationService.Current;
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
            not PhotoImportPhase.Choosing;
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
            _ => "PhotoImportFailureMessage",
        };
        ImportStatus.Message = localization.Get(key);
    }

    private void ActivatePhotoImportPage() => _photoImportPageLoaded = true;

    private void DeactivatePhotoImport()
    {
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
