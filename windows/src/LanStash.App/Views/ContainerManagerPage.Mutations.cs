using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ContainerManagerPage
{
    private ContentDialog? _containerMutationDialog;
    private ContainerMutationDialogContent? _containerMutationContent;
    private async void ManageContainers_Click(object sender, RoutedEventArgs e) => await ShowContainerMutationsAsync();
    private async Task ShowContainerMutationsAsync()
    {
        if (_disposed || _imageDeletionDialog is not null || XamlRoot is null || _containerMutationDialog is not null || _registryDialog is not null ||
            _networkCreationDialog is not null || _networkDeletionDialog is not null || _viewModel.IsLoading || _viewModel.RequiresReconnect ||
            _repository.ProfileId != _viewModel.ActiveProfileId || !_repository.Availability.Features.Contains(ContainerManagerReadFeature.Containers)) return;
        using var content = new ContainerMutationDialogContent(_repository);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = LocalizationService.Current.Get("ContainerOpsTitle"), Content = content,
            PrimaryButtonText = LocalizationService.Current.Get(content.PrimaryButtonResourceKey!), IsPrimaryButtonEnabled = false,
            SecondaryButtonText = LocalizationService.Current.Get("ContainerOpsReview"), CloseButtonText = LocalizationService.Current.Get("ActionClose"),
            DefaultButton = ContentDialogButton.Close,
        };
        _containerMutationDialog = dialog; _containerMutationContent = content;
        void UpdateButtons()
        { dialog.PrimaryButtonText = LocalizationService.Current.Get(content.PrimaryButtonResourceKey!); dialog.IsPrimaryButtonEnabled = content.CanSave; dialog.IsSecondaryButtonEnabled = !content.IsBusy; }
        content.StateChanged += UpdateButtons;
        dialog.Opened += async (_, _) => await content.ActivateAsync();
        dialog.PrimaryButtonClick += async (_, args) =>
        { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.SaveAsync(); } finally { deferral.Complete(); } };
        dialog.SecondaryButtonClick += async (_, args) =>
        { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.ReloadAsync(); } finally { deferral.Complete(); } };
        dialog.Closing += (_, _) => content.Dispose();
        try { await dialog.ShowAsync(); }
        finally
        {
            content.StateChanged -= UpdateButtons;
            if (ReferenceEquals(_containerMutationDialog, dialog)) { _containerMutationDialog = null; _containerMutationContent = null; }
        }
        if (!_disposed && content.NeedsParentRefresh && _repository.ProfileId == _viewModel.ActiveProfileId) await RunAsync(_viewModel.RefreshAsync);
    }
    private void CloseContainerMutations()
    { _containerMutationContent?.Dispose(); _containerMutationDialog?.Hide(); _containerMutationContent = null; _containerMutationDialog = null; }
}
