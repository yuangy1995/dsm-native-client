using LanStash.App.Features.Files.Settings;
using LanStash.Domain;
using Microsoft.UI.Xaml;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private readonly IFileStationSettingsRepository? _fileStationSettingsRepository;
    private FileStationSettingsDialog? _fileStationSettingsDialog;
    private async void FileStationSettings_Click(object sender, RoutedEventArgs e)
    {
        if (_disposed || _fileStationSettingsRepository is null || _fileStationSettingsDialog is not null) return;
        if (!await ClosePreviewAsync()) return; using var model = new FileStationSettingsViewModel(_fileStationSettingsRepository);
        using var dialog = new FileStationSettingsDialog(model, XamlRoot, _transfers.PickThemeImagePathAsync); _fileStationSettingsDialog = dialog; UpdateState();
        try { await dialog.ShowAsync(); } finally { _fileStationSettingsDialog = null; if (!_disposed) UpdateState(); }
    }
    private void CloseFileStationSettingsDialog() { _fileStationSettingsDialog?.Hide(); _fileStationSettingsDialog?.Dispose(); _fileStationSettingsDialog = null; }
}
