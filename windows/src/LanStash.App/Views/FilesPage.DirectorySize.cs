using LanStash.App.Features.Files.DirectorySize;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private readonly IDirectorySizeRepository? _directorySizeRepository;
    private ContentDialog? _directorySizeDialog;
    private FileDirectorySizeViewModel? _directorySizeModel;

    private async void DirectorySize_Click(object sender, RoutedEventArgs e) =>
        await ShowDirectorySizeAsync();

    private async void DirectorySizeAccelerator_Invoked(
        Microsoft.UI.Xaml.Input.KeyboardAccelerator sender,
        Microsoft.UI.Xaml.Input.KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!CanShowDirectorySize())
        {
            return;
        }
        args.Handled = true;
        await ShowDirectorySizeAsync();
    }

    private bool CanShowDirectorySize() =>
        !_viewModel.IsLoading &&
        _directorySizeDialog is null &&
        _directorySizeRepository is not null &&
        _viewModel.SelectedItem is { IsDirectory: true };

    private async Task ShowDirectorySizeAsync()
    {
        if (!CanShowDirectorySize() ||
            _viewModel.SelectedItem?.Item is not { IsDirectory: true } folder ||
            _directorySizeRepository is not { } repository)
        {
            return;
        }

        var model = new FileDirectorySizeViewModel(repository, _profileId, folder);
        var content = new FileDirectorySizeDialogContent(model);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = LocalizationService.Current.Get("FileDirectorySizeTitle"),
            CloseButtonText = LocalizationService.Current.Get("FileDirectorySizeClose"),
            Content = content,
            DefaultButton = ContentDialogButton.Close,
        };
        _directorySizeModel = model;
        _directorySizeDialog = dialog;
        UpdateState();
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            await model.CancelAndWaitAsync();
            content.Detach();
            model.Dispose();
            _directorySizeModel = null;
            _directorySizeDialog = null;
            UpdateState();
        }
    }

    private async Task CloseDirectorySizeDialogAsync()
    {
        _directorySizeModel?.Cancel();
        _directorySizeDialog?.Hide();
        if (_directorySizeModel is { } model)
        {
            await model.CancelAndWaitAsync();
        }
    }

    private void CloseDirectorySizeDialog() =>
        _ = CloseDirectorySizeDialogAsync();
}
