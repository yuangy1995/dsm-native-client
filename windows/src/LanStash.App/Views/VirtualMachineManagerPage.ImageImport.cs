using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineManagerPage
{
    private ContentDialog? _imageImportDialog;
    private VirtualMachineImageImportDialogContent? _imageImportContent;
    private async void ImportImage_Click(object sender, RoutedEventArgs e) => await ShowImageImportAsync();
    private async Task ShowImageImportAsync()
    {
        if (_disposed || _imageImportDialog is not null || _machineBatchDialog is not null || _creationDialog is not null || _powerDialog is not null ||
            _settingsDialog is not null || _networksDialog is not null || XamlRoot is null || _viewModel.RequiresReconnect || _repository.ProfileId != _viewModel.ActiveProfileId) return;
        using var content = new VirtualMachineImageImportDialogContent(_repository);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Content = content,
            Title = LocalizationService.Current.Get("VmImageImportTitle"), PrimaryButtonText = LocalizationService.Current.Get("VmImageImportSubmit"),
            SecondaryButtonText = LocalizationService.Current.Get("VmImageImportRefresh"), CloseButtonText = LocalizationService.Current.Get("ActionClose"),
            DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false };
        _imageImportDialog = dialog; _imageImportContent = content;
        void Update() { dialog.IsPrimaryButtonEnabled = content.CanSubmit; dialog.IsSecondaryButtonEnabled = content.CanRefresh; }
        content.StateChanged += Update; dialog.Opened += async (_, _) => await content.ActivateAsync();
        dialog.PrimaryButtonClick += async (_, args) => { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.SubmitAsync(); } finally { deferral.Complete(); } };
        dialog.SecondaryButtonClick += async (_, args) => { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.RefreshAsync(); } finally { deferral.Complete(); } };
        try { await dialog.ShowAsync(); }
        finally { content.StateChanged -= Update; if (ReferenceEquals(_imageImportDialog, dialog)) { _imageImportDialog = null; _imageImportContent = null; } }
        if (!_disposed && content.NeedsParentRefresh && _repository.ProfileId == _viewModel.ActiveProfileId) await RunAsync(_viewModel.RefreshAsync);
    }
    private void CloseImageImportDialog() { _imageImportContent?.Dispose(); _imageImportDialog?.Hide(); _imageImportContent = null; _imageImportDialog = null; }
}
