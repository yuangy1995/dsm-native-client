using LanStash.App.Features.Downloads;
using LanStash.App.Features.Files;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class DownloadStationPage
{
    private DownloadSettingsViewModel? _settingsEditor;
    private ContentDialog? _settingsDialog;
    private async void Settings_Click(object sender, RoutedEventArgs e)
    {
        if (_disposed || _settingsDialog is not null || XamlRoot is null) return;
        _settingsEditor ??= new(_repository, _repository is IDsmRepository files && _repository is IFileLocationsRepository locations
            ? new RepositoryFileCopyMoveFolderSource(_repository.ProfileId, new RepositoryFileBrowserDataSource(files), locations) : null);
        var model = _settingsEditor;
        var load = model.LoadAsync();
        using var content = new DownloadSettingsDialogContent(model);
        var dialog = _settingsDialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Content = content,
            Title = LocalizationService.Current.Get("DownloadSettingsTitle"), PrimaryButtonText = content.PrimaryText,
            CloseButtonText = LocalizationService.Current.Get("DownloadSettingsClose"), DefaultButton = ContentDialogButton.Close,
            PrimaryButtonStyle = content.ActionButtonStyle, CloseButtonStyle = content.ActionButtonStyle,
        };
        void Update() { dialog.PrimaryButtonText = content.PrimaryText; dialog.IsPrimaryButtonEnabled = content.CanSubmit; }
        async void Submit(ContentDialog sender, ContentDialogButtonClickEventArgs args)
        {
            args.Cancel = true; var deferral = args.GetDeferral();
            try { await content.SubmitAsync(); } finally { Update(); deferral.Complete(); }
        }
        void Closing(ContentDialog sender, ContentDialogClosingEventArgs args) { if (model.IsBusy && !_disposed) args.Cancel = true; }
        content.StateChanged += Update; dialog.PrimaryButtonClick += Submit; dialog.Closing += Closing; Update();
        try { await dialog.ShowAsync(); }
        finally
        {
            content.StateChanged -= Update; dialog.PrimaryButtonClick -= Submit; dialog.Closing -= Closing;
            model.CancelLoad(); await load; _settingsDialog = null;
            if (!_disposed) await RunAsync(_viewModel.RefreshAsync);
        }
    }
    private void DisposeSettingsDialog() { _settingsDialog?.Hide(); _settingsDialog = null; _settingsEditor?.Dispose(); _settingsEditor = null; }
}
