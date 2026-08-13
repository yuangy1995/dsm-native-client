using LanStash.App.Features.Files.Sharing;
using LanStash.App.Features.Photos.Timeline;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class PhotosPage
{
    private bool IsShareablePhotoMedia(PhotoItem item) =>
        item.ProfileId == _profileGuid &&
        _viewModel.SelectedSpace is { } space &&
        PhotoTimelineViewModel.ContainsCanonicalPath(space.RootPath, item.Path) &&
        item.Kind is PhotoItemKind.Image or PhotoItemKind.Video &&
        item.SizeBytes is >= 0 &&
        item.ModifiedAt is not null &&
        !HasRecyclePathSegment(item.Path);

    private bool CanSharePhoto(PhotoItem item) =>
        !_disposed &&
        !_viewModel.IsLoading &&
        !IsSelectingPhotoBatch &&
        _photoShareManagementDialog?.IsOpen != true &&
        !_photoShareLinkDialog.IsOpen &&
        !_photoShareLinkDialog.IsClosing &&
        IsShareablePhotoMedia(item);

    private async Task SharePhotoAsync(PhotoItem item)
    {
        if (!CanSharePhoto(item) || item.SizeBytes is not { } size)
        {
            return;
        }

        var target = new FileShareLinkTarget(
            _profileGuid,
            item.Path,
            item.Name,
            IsDirectory: false,
            size,
            item.ModifiedAt,
            Owner: null,
            CanWrite: false,
            CanDelete: false,
            FileShareLinkTargetBaseline.PhotoMedia);
        await _photoShareLinkDialog.ShowAsync(XamlRoot, target, RefreshPhotoShareState);
    }

    private bool CanManagePhotoShareLinks(PhotoItem item) =>
        !_disposed &&
        !_viewModel.IsLoading &&
        !IsSelectingPhotoBatch &&
        _photoShareRepository is not null &&
        _photoShareManagementDialog?.IsOpen != true &&
        !_photoShareLinkDialog.IsOpen &&
        !_photoShareLinkDialog.IsClosing &&
        IsShareablePhotoMedia(item);

    private async Task ManagePhotoShareLinksAsync(PhotoItem item)
    {
        if (!CanManagePhotoShareLinks(item) || _photoShareRepository is null)
        {
            return;
        }

        var dialog = new FileShareLinkManagementDialog(
            _photoShareRepository,
            _profileGuid,
            _photoShareClipboard,
            DispatcherQueue,
            FileShareLinkManagementDialogOptions.ForPhoto(new(item.Path)));
        _photoShareManagementDialog = dialog;
        RefreshPhotoShareState();
        try
        {
            await dialog.ShowAsync(XamlRoot, RefreshPhotoShareState);
        }
        finally
        {
            if (ReferenceEquals(_photoShareManagementDialog, dialog))
            {
                _photoShareManagementDialog = null;
            }
            dialog.Dispose();
            RefreshPhotoShareState();
        }
    }

    private void ClosePhotoShareManagementDialog()
    {
        var dialog = _photoShareManagementDialog;
        _photoShareManagementDialog = null;
        dialog?.Close();
        dialog?.Dispose();
        RefreshPhotoShareState();
    }

    private void RefreshPhotoShareState()
    {
        if (_disposed)
        {
            return;
        }
        UpdateState();
        TimelineView.RefreshActionState();
        UpdatePhotoViewerState();
    }

    private async void PhotoShareLink_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.SelectedItem is { IsMedia: true } selected)
        {
            await SharePhotoAsync(selected.Item);
        }
    }

    private async void PhotoViewerShareLink_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPhotoViewerItem() is { } item)
        {
            await SharePhotoAsync(item);
        }
    }

    private async void PhotoManageShareLinks_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.SelectedItem is { IsMedia: true } selected)
        {
            await ManagePhotoShareLinksAsync(selected.Item);
        }
    }

    private async void PhotoViewerManageShareLinks_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPhotoViewerItem() is { } item)
        {
            await ManagePhotoShareLinksAsync(item);
        }
    }

    private async void PhotoShareLinkAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (CurrentPhotoViewerItem() is { } viewerItem && CanSharePhoto(viewerItem))
        {
            args.Handled = true;
            await SharePhotoAsync(viewerItem);
            return;
        }
        if (TimelineMode.IsChecked == true && TimelineView.CanShareSelected)
        {
            args.Handled = true;
            await TimelineView.ShareSelectedAsync();
            return;
        }
        if (_viewModel.SelectedItem is { IsMedia: true } selected && CanSharePhoto(selected.Item))
        {
            args.Handled = true;
            await SharePhotoAsync(selected.Item);
        }
    }

    private async void PhotoManageShareLinksAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (CurrentPhotoViewerItem() is { } viewerItem && CanManagePhotoShareLinks(viewerItem))
        {
            args.Handled = true;
            await ManagePhotoShareLinksAsync(viewerItem);
            return;
        }
        if (TimelineMode.IsChecked == true && TimelineView.CanManageShareLinksSelected)
        {
            args.Handled = true;
            await TimelineView.ManageShareLinksSelectedAsync();
            return;
        }
        if (_viewModel.SelectedItem is { IsMedia: true } selected &&
            CanManagePhotoShareLinks(selected.Item))
        {
            args.Handled = true;
            await ManagePhotoShareLinksAsync(selected.Item);
        }
    }
}
