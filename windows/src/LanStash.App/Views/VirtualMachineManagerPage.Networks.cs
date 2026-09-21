using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineManagerPage
{
    private ContentDialog? _networksDialog;
    private VirtualMachineNetworksDialogContent? _networksContent;
    private async void ManageNetworks_Click(object sender, RoutedEventArgs e) => await ShowNetworksAsync();
    private async Task ShowNetworksAsync()
    {
        if (_disposed || _networksDialog is not null || _machineBatchDialog is not null || _creationDialog is not null ||
            _settingsDialog is not null || _powerDialog is not null || XamlRoot is null || _viewModel.IsLoading || _viewModel.RequiresReconnect ||
            _repository.ProfileId != _viewModel.ActiveProfileId) return;
        using var content = new VirtualMachineNetworksDialogContent(_repository);
        var l = LocalizationService.Current;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Content = content, Title = l.Get("VmNetworkTitle"),
            PrimaryButtonText = l.Get("VmNetworkApply"), SecondaryButtonText = l.Get("VmNetworkReview"),
            CloseButtonText = l.Get("ActionClose"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false, IsSecondaryButtonEnabled = false };
        _networksDialog = dialog; _networksContent = content;
        void UpdateButtons() { dialog.IsPrimaryButtonEnabled = content.CanSubmit; dialog.IsSecondaryButtonEnabled = content.CanReview; }
        content.StateChanged += UpdateButtons; dialog.Opened += async (_, _) => await content.ActivateAsync();
        dialog.PrimaryButtonClick += async (_, args) => { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.SubmitAsync(); } finally { deferral.Complete(); } };
        dialog.SecondaryButtonClick += async (_, args) => { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.ReviewAsync(); } finally { deferral.Complete(); } };
        try { await dialog.ShowAsync(); }
        finally { content.StateChanged -= UpdateButtons; if (ReferenceEquals(_networksDialog, dialog)) { _networksDialog = null; _networksContent = null; } }
        if (!_disposed && content.NeedsParentRefresh && _repository.ProfileId == _viewModel.ActiveProfileId) await RunAsync(_viewModel.RefreshAsync);
    }
    private void CloseNetworksDialog() { _networksContent?.Dispose(); _networksDialog?.Hide(); _networksContent = null; _networksDialog = null; }
}
