using LanStash.App.Features.Files.Permissions;
using LanStash.Domain;
using Microsoft.UI.Xaml;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private readonly IFilePermissionRepository? _permissionRepository;
    private FilePermissionDialog? _permissionDialog;

    private async void FilePermissions_Click(object sender, RoutedEventArgs e)
    {
        if (_disposed || _permissionRepository is null || _permissionDialog is not null || _viewModel.SelectedItem is not { } selected) return;
        if (!await ClosePreviewAsync()) return;
        using var model = new FilePermissionViewModel(_permissionRepository, selected.Path);
        using var dialog = new FilePermissionDialog(model, XamlRoot);
        _permissionDialog = dialog; UpdateState();
        try { await dialog.ShowAsync(); }
        finally
        {
            _permissionDialog = null;
            if (!_disposed)
            {
                if (model.HasAttemptedSave || model.Progress?.Outcome.Submitted == true)
                {
                    CancelAsyncSearch(); _activeSearchRequest = null; FilterBox.Text = string.Empty;
                    await RunAsync(_viewModel.RefreshAfterPermissionChangeAsync);
                }
                UpdateState();
            }
        }
    }
    private void ClosePermissionDialog()
    {
        _permissionDialog?.Hide(); _permissionDialog?.Dispose(); _permissionDialog = null;
    }
}
