using LanStash.App.Features.Files.Locations;
using LanStash.Domain;
using Microsoft.UI.Xaml;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private readonly IFileLocationsRepository? _isoRepository;
    private IsoMountDialog? _isoDialog;
    private async void IsoMounts_Click(object sender, RoutedEventArgs e)
    {
        if (_disposed || _isoRepository is null || _isoDialog is not null) return;
        if (!await ClosePreviewAsync()) return;
        var selected = _viewModel.SelectedItem;
        var source = selected is { IsDirectory: false } && selected.Name.EndsWith(".iso", StringComparison.OrdinalIgnoreCase) ? selected.Item : null;
        using var model = new IsoMountViewModel(_isoRepository, _copyMoveFolderSource, source);
        using var dialog = new IsoMountDialog(model, XamlRoot);
        _isoDialog = dialog; UpdateState();
        try { await dialog.ShowAsync(); }
        finally
        {
            _isoDialog = null;
            if (!_disposed)
            {
                if (model.HasAttemptedSave || model.Progress?.Outcome.Submitted == true)
                {
                    CancelAsyncSearch(); _activeSearchRequest = null; FilterBox.Text = "";
                    await RunAsync(_viewModel.RefreshAfterPermissionChangeAsync);
                    if (!_disposed) await _locationsViewModel.RefreshAsync();
                }
                if (!_disposed && dialog.OpenPath is { } path) await RunAsync(() => _viewModel.NavigateToBreadcrumbAsync(new(path, path)));
                if (!_disposed) UpdateState();
            }
        }
    }
    private void CloseIsoDialog() { _isoDialog?.Hide(); _isoDialog?.Dispose(); _isoDialog = null; }
}
