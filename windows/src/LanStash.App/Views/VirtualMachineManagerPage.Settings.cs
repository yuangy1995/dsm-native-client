using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineManagerPage
{
    private ContentDialog? _settingsDialog;
    private VirtualMachineSettingsDialogContent? _settingsContent;
    private async void EditSettings_Click(object sender, RoutedEventArgs e) => await ShowSettingsAsync();
    private async Task ShowSettingsAsync()
    {
        if (_disposed || _machineBatchDialog is not null || _creationDialog is not null || _settingsDialog is not null || _powerDialog is not null || XamlRoot is null || _viewModel.IsLoading || _viewModel.RequiresReconnect ||
            _repository.ProfileId != _viewModel.ActiveProfileId || _viewModel.SelectedMachine is not { } selected) return;
        using var content = new VirtualMachineSettingsDialogContent(_repository, selected.Id);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Content = content, Title = LocalizationService.Current.Get("VmSettingsTitle"),
            PrimaryButtonText = LocalizationService.Current.Get("VmSettingsSave"), SecondaryButtonText = LocalizationService.Current.Get("VmSettingsReview"),
            CloseButtonText = LocalizationService.Current.Get("ActionClose"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false };
        _settingsDialog = dialog; _settingsContent = content;
        void UpdateButtons() { dialog.IsPrimaryButtonEnabled = content.CanSave; dialog.IsSecondaryButtonEnabled = content.CanReload; }
        content.StateChanged += UpdateButtons; dialog.Opened += async (_, _) => await content.ActivateAsync();
        dialog.PrimaryButtonClick += async (_, args) => { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.SaveAsync(); } finally { deferral.Complete(); } };
        dialog.SecondaryButtonClick += async (_, args) => { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.ReloadAsync(); } finally { deferral.Complete(); } };
        try { await dialog.ShowAsync(); }
        finally { content.StateChanged -= UpdateButtons; if (ReferenceEquals(_settingsDialog, dialog)) { _settingsDialog = null; _settingsContent = null; } }
        if (!_disposed && content.NeedsParentRefresh && _repository.ProfileId == _viewModel.ActiveProfileId) await RunAsync(_viewModel.RefreshAsync);
    }
    private void CloseSettingsDialog() { _settingsContent?.Dispose(); _settingsDialog?.Hide(); _settingsContent = null; _settingsDialog = null; }
}
