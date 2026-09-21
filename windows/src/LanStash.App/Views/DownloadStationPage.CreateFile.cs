using Microsoft.UI;
using LanStash.App.Features.Downloads;
using LanStash.App.Features.Files;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using WinRT.Interop;

namespace LanStash.App.Views;

public sealed partial class DownloadStationPage
{
    private bool _selectingTaskFile;
    private ContentDialog? _fileCreateDialog;
    private static readonly string[] DownloadTaskFileTypeFilters =
    [
        ".torrent",
        ".nzb",
        ".txt",
    ];

    private async void CreateFileTask_Click(object sender, RoutedEventArgs e)
    {
        if (_disposed || !_viewModel.CanCreateTask || _selectingTaskFile || _fileCreateDialog is not null)
        {
            return;
        }

        _selectingTaskFile = true;
        string? filePath;
        try { filePath = await PickDownloadTaskFilePathAsync(); }
        finally { _selectingTaskFile = false; }
        if (string.IsNullOrWhiteSpace(filePath) || _disposed)
        {
            return;
        }

        await ShowFileCreateOptionsAsync(filePath);
    }

    private async Task ShowFileCreateOptionsAsync(string filePath)
    {
        if (XamlRoot is null || _disposed) return;
        IFileCopyMoveFolderSource? folders = _repository.Availability.SupportsCreateDestination && _repository is IDsmRepository files && _repository is IFileLocationsRepository locations
            ? new RepositoryFileCopyMoveFolderSource(_repository.ProfileId, new RepositoryFileBrowserDataSource(files), locations) : null;
        using var model = new DownloadCreateOptionsViewModel(folders);
        using var content = new DownloadCreateOptionsDialogContent(model, System.IO.Path.GetFileName(filePath));
        var dialog = _fileCreateDialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Content = content,
            Title = LocalizationService.Current.Get("DownloadCreateFileTitle"), PrimaryButtonText = LocalizationService.Current.Get("DownloadStationCreateSubmit"),
            CloseButtonText = LocalizationService.Current.Get("ActionCancel"), DefaultButton = ContentDialogButton.Close,
            PrimaryButtonStyle = content.ActionButtonStyle, CloseButtonStyle = content.ActionButtonStyle, IsPrimaryButtonEnabled = content.CanSubmit };
        void Update() => dialog.IsPrimaryButtonEnabled = content.CanSubmit;
        async void Submit(ContentDialog sender, ContentDialogButtonClickEventArgs args)
        {
            if (!content.CanSubmit) { args.Cancel = true; return; }
            var deferral = args.GetDeferral();
            var password = content.TakePassword(); var destination = model.Destination;
            content.BeginSubmission();
            try { await RunAsync(() => _viewModel.CreateTaskFromFileAsync(filePath, destination, password)); }
            finally { password = null; deferral.Complete(); }
        }
        void Closing(ContentDialog sender, ContentDialogClosingEventArgs args) { if (_viewModel.IsCreatingTask && !_disposed) args.Cancel = true; }
        content.StateChanged += Update; dialog.PrimaryButtonClick += Submit; dialog.Closing += Closing;
        try { await dialog.ShowAsync(); }
        finally { content.StateChanged -= Update; dialog.PrimaryButtonClick -= Submit; dialog.Closing -= Closing; _fileCreateDialog = null; }
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
