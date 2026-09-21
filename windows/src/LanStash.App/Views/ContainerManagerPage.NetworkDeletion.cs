using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ContainerManagerPage
{
    private ContentDialog? _networkDeletionDialog;
    private ContainerNetworkDeleteDialogContent? _networkDeletionContent;
    private async void DeleteNetworks_Click(object sender, RoutedEventArgs e) => await ShowNetworkDeletionAsync();
    private async Task ShowNetworkDeletionAsync()
    {
        if (_disposed || _imageDeletionDialog is not null || _containerMutationDialog is not null || _registryDialog is not null || _networkCreationDialog is not null || _networkDeletionDialog is not null || XamlRoot is null || _viewModel.IsLoading || _viewModel.RequiresReconnect ||
            _repository.ProfileId != _viewModel.ActiveProfileId || !_repository.Availability.Features.Contains(ContainerManagerReadFeature.Networks)) return;
        using var content = new ContainerNetworkDeleteDialogContent(_repository);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = LocalizationService.Current.Get("ContainerDeleteTitle"), Content = content,
            PrimaryButtonText = LocalizationService.Current.Get("ContainerDeleteAction"), SecondaryButtonText = LocalizationService.Current.Get("ContainerCreateReview"),
            CloseButtonText = LocalizationService.Current.Get("ActionClose"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false
        };
        _networkDeletionDialog = dialog; _networkDeletionContent = content;
        void UpdateButtons() { dialog.IsPrimaryButtonEnabled = content.CanSave; dialog.IsSecondaryButtonEnabled = !content.IsBusy; }
        content.StateChanged += UpdateButtons;
        dialog.Opened += async (_, _) => await content.ActivateAsync();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; var deferral = args.GetDeferral();
            try { await content.SaveAsync(); } finally { deferral.Complete(); }
        };
        dialog.SecondaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; var deferral = args.GetDeferral();
            try { await content.ReloadAsync(); } finally { deferral.Complete(); }
        };
        try { await dialog.ShowAsync(); }
        finally
        {
            content.StateChanged -= UpdateButtons;
            if (ReferenceEquals(_networkDeletionDialog, dialog)) { _networkDeletionDialog = null; _networkDeletionContent = null; }
        }
        if (!_disposed && content.NeedsParentRefresh && _repository.ProfileId == _viewModel.ActiveProfileId) await RunAsync(_viewModel.RefreshAsync);
    }
    private void CloseNetworkDeletion()
    {
        _networkDeletionContent?.Dispose(); _networkDeletionDialog?.Hide();
        _networkDeletionContent = null; _networkDeletionDialog = null;
    }
}
