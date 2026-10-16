using LanStash.App.Features.Files.Locations;
using LanStash.Domain;
using Microsoft.UI.Xaml;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private readonly IFileVfsRepository? _vfsRepository;
    private FileVfsDialog? _vfsDialog;
    private FileVfsBrowserDialog? _vfsBrowserDialog;
    private bool _vfsFlowActive;
    private int _vfsGeneration;
    private async void Vfs_Click(object sender, RoutedEventArgs e)
    {
        if (_disposed || _vfsRepository is null || _vfsFlowActive) return;
        if (!await ClosePreviewAsync()) return;
        _vfsFlowActive = true; var generation = ++_vfsGeneration; UpdateState();
        try
        {
            while (!_disposed && generation == _vfsGeneration)
            {
                using var model = new FileVfsViewModel(_vfsRepository);
                using var dialog = new FileVfsDialog(model, XamlRoot);
                _vfsDialog = dialog; await dialog.ShowAsync(); _vfsDialog = null;
                if (_disposed || generation != _vfsGeneration || dialog.BrowseRequested is not { } profile || _vfsRepository is not IFileVfsBrowserRepository browser) break;
                using var browserModel = new FileVfsBrowserViewModel(browser, profile);
                using var browserDialog = new FileVfsBrowserDialog(browserModel, XamlRoot,
                    (source, current, token) => _transfers.PickAndStartVfsDownloadAsync(browser, source, () => !_disposed && generation == _vfsGeneration && current(), token));
                _vfsBrowserDialog = browserDialog; await browserDialog.ShowAsync(); _vfsBrowserDialog = null;
            }
        }
        finally { _vfsDialog = null; _vfsBrowserDialog = null; _vfsFlowActive = false; if (!_disposed) UpdateState(); }
    }
    private void CloseVfsDialog() { _vfsGeneration++; _vfsDialog?.Hide(); _vfsDialog?.Dispose(); _vfsDialog = null; _vfsBrowserDialog?.Hide(); _vfsBrowserDialog?.Dispose(); _vfsBrowserDialog = null; }
}
