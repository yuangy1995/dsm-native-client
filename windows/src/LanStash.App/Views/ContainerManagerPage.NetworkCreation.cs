using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ContainerManagerPage
{
    private ContentDialog? _networkCreationDialog;
    private ContainerNetworkCreateDialogContent? _networkCreationContent;
    private async void CreateNetwork_Click(object sender, RoutedEventArgs e) => await ShowNetworkCreationAsync();
    private async Task ShowNetworkCreationAsync()
    {
        if (_disposed || _imageDeletionDialog is not null || _containerMutationDialog is not null || _registryDialog is not null || _networkCreationDialog is not null || _networkDeletionDialog is not null || XamlRoot is null || _viewModel.IsLoading || _viewModel.RequiresReconnect ||
            _repository.ProfileId != _viewModel.ActiveProfileId || !_repository.Availability.Features.Contains(ContainerManagerReadFeature.Networks)) return;
        using var content = new ContainerNetworkCreateDialogContent(_repository);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = LocalizationService.Current.Get("ContainerCreateTitle"), Content = content,
            PrimaryButtonText = LocalizationService.Current.Get("ContainerCreateAction"), SecondaryButtonText = LocalizationService.Current.Get("ContainerCreateReview"),
            CloseButtonText = LocalizationService.Current.Get("ActionClose"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false
        };
        _networkCreationDialog = dialog; _networkCreationContent = content;
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
            if (ReferenceEquals(_networkCreationDialog, dialog)) { _networkCreationDialog = null; _networkCreationContent = null; }
        }
        if (!_disposed && content.NeedsParentRefresh && _repository.ProfileId == _viewModel.ActiveProfileId) await RunAsync(_viewModel.RefreshAsync);
    }
    private void CloseNetworkCreation()
    {
        _networkCreationContent?.Dispose(); _networkCreationDialog?.Hide();
        _networkCreationContent = null; _networkCreationDialog = null;
    }
}
