using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class PhotosPage
{
    private bool CanSharePhoto(PhotoItem item) =>
        !_disposed &&
        !_viewModel.IsLoading &&
        !IsSelectingPhotoBatch &&
        !_photoShareLinkDialog.IsOpen &&
        !_photoShareLinkDialog.IsClosing &&
        Guid.TryParse(_profileId, out var profileId) &&
        item.ProfileId == profileId &&
        item.Kind is PhotoItemKind.Image or PhotoItemKind.Video &&
        item.SizeBytes is >= 0 &&
        item.ModifiedAt is not null &&
        !HasRecyclePathSegment(item.Path);

    private async Task SharePhotoAsync(PhotoItem item)
    {
        if (!CanSharePhoto(item) || !Guid.TryParse(_profileId, out var profileId) ||
            item.SizeBytes is not { } size)
        {
            return;
        }

        var target = new FileShareLinkTarget(
            profileId,
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
}
