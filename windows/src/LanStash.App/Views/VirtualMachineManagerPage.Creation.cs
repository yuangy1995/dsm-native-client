using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineManagerPage
{
    private ContentDialog? _creationDialog;
    private VirtualMachineCreationDialogContent? _creationContent;
    private async void CreateMachine_Click(object sender, RoutedEventArgs e) => await ShowCreationAsync();
    private async Task ShowCreationAsync()
    {
        if (_disposed || _machineBatchDialog is not null || _creationDialog is not null || _powerDialog is not null || _settingsDialog is not null || XamlRoot is null || _viewModel.RequiresReconnect || _repository.ProfileId != _viewModel.ActiveProfileId) return;
        using var content = new VirtualMachineCreationDialogContent(_repository);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Content = content, Title = LocalizationService.Current.Get("VmCreateTitle"),
            PrimaryButtonText = content.PrimaryText, SecondaryButtonText = content.RefreshText, CloseButtonText = LocalizationService.Current.Get("ActionClose"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false };
        _creationDialog = dialog; _creationContent = content;
        void UpdateButtons() { dialog.PrimaryButtonText = content.PrimaryText; dialog.SecondaryButtonText = content.RefreshText; dialog.IsPrimaryButtonEnabled = content.CanSubmit; dialog.IsSecondaryButtonEnabled = content.CanRefresh; }
        content.StateChanged += UpdateButtons; dialog.Opened += async (_, _) => await content.ActivateAsync();
        dialog.PrimaryButtonClick += async (_, args) => { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.SubmitAsync(); } finally { deferral.Complete(); } };
        dialog.SecondaryButtonClick += async (_, args) => { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.RefreshAsync(); } finally { deferral.Complete(); } };
        try { await dialog.ShowAsync(); }
        finally { content.StateChanged -= UpdateButtons; if (ReferenceEquals(_creationDialog, dialog)) { _creationDialog = null; _creationContent = null; } }
        if (!_disposed && content.NeedsParentRefresh && _repository.ProfileId == _viewModel.ActiveProfileId) await RunAsync(_viewModel.RefreshAsync);
    }
    private void CloseCreationDialog() { _creationContent?.Dispose(); _creationDialog?.Hide(); _creationContent = null; _creationDialog = null; }
}
