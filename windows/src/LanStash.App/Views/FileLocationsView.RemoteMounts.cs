using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FileLocationsView
{
    private ContentDialog? _remoteManagementDialog;
    private RemoteMountManagementDialogContent? _remoteManagementContent;
    private IFileLocationsRepository? _remoteManagementRepository;
    private async void RemoteCreate_Click(object sender, RoutedEventArgs args) => await ShowRemoteManagementAsync();
    private async void RemoteEdit_Click(object sender, RoutedEventArgs args)
    {
        if ((sender as FrameworkElement)?.DataContext is FileRemoteLocation location && location.ProfileId == _viewModel?.ProfileId)
            await ShowRemoteManagementAsync(location.Path, RemoteMountAction.Update);
    }
    private async void RemoteDelete_Click(object sender, RoutedEventArgs args)
    {
        if ((sender as FrameworkElement)?.DataContext is FileRemoteLocation location && location.ProfileId == _viewModel?.ProfileId)
            await ShowRemoteManagementAsync(location.Path, RemoteMountAction.Disconnect);
    }
    private async Task ShowRemoteManagementAsync(string? path = null, RemoteMountAction action = RemoteMountAction.Create)
    {
        if (_disposed || _remoteManagementDialog is not null || XamlRoot is null || _viewModel?.RemoteMountRepository is not { } repository) return;
        var content = new RemoteMountManagementDialogContent(repository, path, action);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = LocalizationService.Current.Get("RemoteMountTitle"), Content = content,
            PrimaryButtonText = LocalizationService.Current.Get("RemoteMountConnect"), SecondaryButtonText = LocalizationService.Current.Get("RemoteMountRefresh"),
            CloseButtonText = LocalizationService.Current.Get("ActionClose"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false
        };
        _remoteManagementDialog = dialog; _remoteManagementContent = content; _remoteManagementRepository = repository;
        bool Current() => !_disposed && ReferenceEquals(_remoteManagementRepository, repository) && ReferenceEquals(_viewModel?.RemoteMountRepository, repository);
        void UpdateButtons()
        {
            dialog.IsPrimaryButtonEnabled = Current() && content.CanSave;
            dialog.IsSecondaryButtonEnabled = Current() && !content.IsBusy;
            dialog.PrimaryButtonText = LocalizationService.Current.Get(content.PrimaryButtonResourceKey!);
        }
        content.StateChanged += UpdateButtons;
        dialog.Opened += async (_, _) => { if (Current()) await content.ActivateAsync(); };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; var deferral = args.GetDeferral();
            try { if (Current()) await content.SaveAsync(); } finally { deferral.Complete(); }
        };
        dialog.SecondaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; var deferral = args.GetDeferral();
            try { if (Current()) await content.ReloadAsync(); } finally { deferral.Complete(); }
        };
        var needsRefresh = false;
        try { await dialog.ShowAsync(); }
        finally
        {
            needsRefresh = content.NeedsParentRefresh; content.StateChanged -= UpdateButtons; content.Dispose();
            if (ReferenceEquals(_remoteManagementDialog, dialog)) { _remoteManagementDialog = null; _remoteManagementContent = null; _remoteManagementRepository = null; }
        }
        if (!_disposed && needsRefresh && ReferenceEquals(_viewModel?.RemoteMountRepository, repository)) RemoteMountNeedsRefresh?.Invoke(this, EventArgs.Empty);
    }
    private void CloseRemoteManagement()
    {
        _remoteManagementContent?.Dispose(); _remoteManagementDialog?.Hide();
        _remoteManagementContent = null; _remoteManagementDialog = null; _remoteManagementRepository = null;
    }
}
