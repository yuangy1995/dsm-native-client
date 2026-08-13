using LanStash.App.Features.Files.Sharing;
using Microsoft.UI.Xaml;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private FileShareLinkManagementDialog? _shareManagementDialog;

    private async void ManageShareLinks_Click(object sender, RoutedEventArgs e)
    {
        if (_disposed || _shareRepository is null ||
            _shareManagementDialog?.IsOpen == true ||
            _shareLinkDialog is not null)
        {
            return;
        }

        var dialog = new FileShareLinkManagementDialog(
            _shareRepository,
            _profileId,
            _clipboard,
            DispatcherQueue);
        _shareManagementDialog = dialog;
        UpdateState();
        try
        {
            await dialog.ShowAsync(XamlRoot, UpdateState);
        }
        finally
        {
            if (ReferenceEquals(_shareManagementDialog, dialog))
            {
                _shareManagementDialog = null;
            }
            dialog.Dispose();
            UpdateState();
        }
    }

    private void CloseShareManagementDialog()
    {
        var dialog = _shareManagementDialog;
        _shareManagementDialog = null;
        dialog?.Close();
        dialog?.Dispose();
        UpdateState();
    }
}
