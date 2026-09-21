using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ContainerManagerPage
{
    private ContentDialog? _registryDialog;
    private ContainerRegistryDialogContent? _registryContent;
    private async void BrowseRegistry_Click(object sender, RoutedEventArgs e) => await ShowRegistryAsync();
    private async Task ShowRegistryAsync()
    {
        if (_disposed || _imageDeletionDialog is not null || _containerMutationDialog is not null || _registryDialog is not null || _networkCreationDialog is not null || _networkDeletionDialog is not null || XamlRoot is null ||
            _viewModel.IsLoading || _viewModel.RequiresReconnect || _repository.ProfileId != _viewModel.ActiveProfileId) return;
        using var content = new ContainerRegistryDialogContent(_repository);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = LocalizationService.Current.Get("ContainerRegistryTitle"),
            Content = content, CloseButtonText = LocalizationService.Current.Get("ActionClose"), DefaultButton = ContentDialogButton.Close };
        _registryDialog = dialog; _registryContent = content;
        dialog.Opened += async (_, _) => await content.ActivateAsync();
        dialog.Closed += (_, _) => content.Dispose();
        try { await dialog.ShowAsync(); }
        finally { content.Dispose(); if (ReferenceEquals(_registryDialog, dialog)) { _registryDialog = null; _registryContent = null; } }
        if (!_disposed && content.NeedsParentRefresh && _repository.ProfileId == _viewModel.ActiveProfileId) await RunAsync(_viewModel.RefreshAsync);
    }
    private void CloseRegistry() { _registryContent?.Dispose(); _registryDialog?.Hide(); _registryContent = null; _registryDialog = null; }
}
