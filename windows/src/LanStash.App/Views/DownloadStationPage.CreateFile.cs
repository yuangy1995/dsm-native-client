using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.Windows.Storage.Pickers;
using WinRT.Interop;

namespace LanStash.App.Views;

public sealed partial class DownloadStationPage
{
    private static readonly string[] DownloadTaskFileTypeFilters =
    [
        ".torrent",
        ".nzb",
        ".txt",
    ];

    private async void CreateFileTask_Click(object sender, RoutedEventArgs e)
    {
        if (_disposed || !_viewModel.CanCreateTask)
        {
            return;
        }

        var filePath = await PickDownloadTaskFilePathAsync();
        if (string.IsNullOrWhiteSpace(filePath) || _disposed)
        {
            return;
        }

        await RunAsync(() => _viewModel.CreateTaskFromFileAsync(filePath));
    }

    private static async Task<string?> PickDownloadTaskFilePathAsync()
    {
        if ((Application.Current as App)?.MainWindow is not { } window)
        {
            return null;
        }

        var windowId = Win32Interop.GetWindowIdFromWindow(
            WindowNative.GetWindowHandle(window));
        var picker = new FileOpenPicker(windowId);
        foreach (var filter in DownloadTaskFileTypeFilters)
        {
            picker.FileTypeFilter.Add(filter);
        }

        var file = await picker.PickSingleFileAsync();
        return file?.Path;
    }
}
