using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private long _fileUploadDragGeneration;
    private long _fileUploadDropGeneration;

    private async void FileUpload_DragOver(object sender, DragEventArgs e)
    {
        var generation = Interlocked.Increment(ref _fileUploadDragGeneration);
        e.AcceptedOperation = DataPackageOperation.None;
        var deferral = e.GetDeferral();
        try
        {
            var sourcePath = await TryGetSingleDroppedFilePathAsync(e.DataView);
            if (generation != Volatile.Read(ref _fileUploadDragGeneration) ||
                !CanAcceptFileUploadDrop() || sourcePath is null)
            {
                if (generation == Volatile.Read(ref _fileUploadDragGeneration))
                {
                    FileUploadDropOverlay.Visibility = Visibility.Collapsed;
                }
                return;
            }

            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = LocalizationService.Current.Get(
                "FileUploadDropCaption");
            e.DragUIOverride.IsCaptionVisible = true;
            FileUploadDropStatus.IsOpen = false;
            FileUploadDropOverlay.Visibility = Visibility.Visible;
        }
        finally
        {
            deferral.Complete();
        }
    }

    private void FileUpload_DragLeave(object sender, DragEventArgs e)
    {
        Interlocked.Increment(ref _fileUploadDragGeneration);
        FileUploadDropOverlay.Visibility = Visibility.Collapsed;
    }

    private async void FileUpload_Drop(object sender, DragEventArgs e)
    {
        Interlocked.Increment(ref _fileUploadDragGeneration);
        var generation = Interlocked.Increment(ref _fileUploadDropGeneration);
        FileUploadDropOverlay.Visibility = Visibility.Collapsed;
        var targetPath = _viewModel.CurrentPath;
        var deferral = e.GetDeferral();
        try
        {
            var sourcePath = await TryGetSingleDroppedFilePathAsync(e.DataView);
            if (generation != Volatile.Read(ref _fileUploadDropGeneration))
            {
                return;
            }
            if (!CanAcceptFileUploadDrop() || sourcePath is null ||
                !string.Equals(targetPath, _viewModel.CurrentPath, StringComparison.Ordinal))
            {
                ShowFileUploadDropError("FileUploadDropInvalidMessage");
                return;
            }

            _isChoosingUpload = true;
            FileUploadDropStatus.IsOpen = false;
            UpdateState();
            try
            {
                if (!await _transfers.StartUploadAsync(
                    _profileId.ToString(),
                    targetPath,
                    sourcePath))
                {
                    ShowFileUploadDropError("FileUploadDropFailureMessage");
                }
            }
            catch (ObjectDisposedException)
            {
            }
            catch
            {
                ShowFileUploadDropError("FileUploadDropFailureMessage");
            }
            finally
            {
                _isChoosingUpload = false;
                UpdateState();
            }
        }
        finally
        {
            deferral.Complete();
        }
    }

    private bool CanAcceptFileUploadDrop() =>
        !_disposed &&
        !_viewModel.IsLoading &&
        !_isChoosingUpload &&
        !IsReadOnlyLocation() &&
        !string.IsNullOrWhiteSpace(_viewModel.CurrentPath);

    private static async Task<string?> TryGetSingleDroppedFilePathAsync(
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
                string.IsNullOrWhiteSpace(file.Path))
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

    private void ShowFileUploadDropError(string resourceKey)
    {
        FileUploadDropStatus.Message = LocalizationService.Current.Get(resourceKey);
        FileUploadDropStatus.IsOpen = true;
    }

    private void DeactivateFileUploadDrop()
    {
        Interlocked.Increment(ref _fileUploadDragGeneration);
        Interlocked.Increment(ref _fileUploadDropGeneration);
        FileUploadDropOverlay.Visibility = Visibility.Collapsed;
        FileUploadDropStatus.IsOpen = false;
    }
}
