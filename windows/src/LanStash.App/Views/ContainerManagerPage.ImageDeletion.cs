using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ContainerManagerPage
{
    private ContentDialog? _imageDeletionDialog;
    private ContainerImageDeleteDialogContent? _imageDeletionContent;
    private async void DeleteImages_Click(object sender, RoutedEventArgs e) => await ShowImageDeletionAsync();
    private async Task ShowImageDeletionAsync()
    {
        if (_disposed || _networkDeletionDialog is not null || _containerMutationDialog is not null || _registryDialog is not null || _networkCreationDialog is not null || _imageDeletionDialog is not null || XamlRoot is null || _viewModel.IsLoading || _viewModel.RequiresReconnect ||
            _repository.ProfileId != _viewModel.ActiveProfileId || !_repository.Availability.Features.Contains(ContainerManagerReadFeature.Images)) return;
        using var content = new ContainerImageDeleteDialogContent(_repository);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = LocalizationService.Current.Get("ContainerImageDeleteTitle"), Content = content,
            PrimaryButtonText = LocalizationService.Current.Get("ContainerImageDeleteAction"), SecondaryButtonText = LocalizationService.Current.Get("ContainerCreateReview"),
            CloseButtonText = LocalizationService.Current.Get("ActionClose"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false
        };
        _imageDeletionDialog = dialog; _imageDeletionContent = content;
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
            if (ReferenceEquals(_imageDeletionDialog, dialog)) { _imageDeletionDialog = null; _imageDeletionContent = null; }
        }
        if (!_disposed && content.NeedsParentRefresh && _repository.ProfileId == _viewModel.ActiveProfileId) await RunAsync(_viewModel.RefreshAsync);
    }
    private void CloseImageDeletion()
    {
        _imageDeletionContent?.Dispose(); _imageDeletionDialog?.Hide();
        _imageDeletionContent = null; _imageDeletionDialog = null;
    }
}
