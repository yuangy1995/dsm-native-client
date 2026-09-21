using LanStash.App.Features.VirtualMachines;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineManagerPage
{
    private ContentDialog? _powerDialog;
    private VirtualMachinePowerDialogContent? _powerContent;
    private async void PowerOn_Click(object sender, RoutedEventArgs e) => await ShowPowerAsync(VirtualMachinePowerAction.PowerOn);
    private async void Shutdown_Click(object sender, RoutedEventArgs e) => await ShowPowerAsync(VirtualMachinePowerAction.Shutdown);
    private async void PowerOff_Click(object sender, RoutedEventArgs e) => await ShowPowerAsync(VirtualMachinePowerAction.PowerOff);
    private async Task ShowPowerAsync(VirtualMachinePowerAction action)
    {
        if (_disposed || _machineBatchDialog is not null || _creationDialog is not null || _powerDialog is not null || _settingsDialog is not null || XamlRoot is null || _viewModel.IsLoading || _viewModel.RequiresReconnect ||
            _repository.ProfileId != _viewModel.ActiveProfileId || _viewModel.SelectedMachine?.Machine is not { } target || !VirtualMachinePowerRules.CanRequest(target, action)) return;
        using var content = new VirtualMachinePowerDialogContent(_repository, target, action);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Content = content,
            Title = LocalizationService.Current.Get(VirtualMachinePowerViewModel.ActionKey(action)),
            PrimaryButtonText = LocalizationService.Current.Get(VirtualMachinePowerViewModel.ActionKey(action)),
            SecondaryButtonText = LocalizationService.Current.Get("VmPowerReview"), CloseButtonText = LocalizationService.Current.Get("ActionClose"),
            DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false };
        _powerDialog = dialog; _powerContent = content;
        void UpdateButtons() { dialog.IsPrimaryButtonEnabled = content.CanSubmit; dialog.IsSecondaryButtonEnabled = !content.IsBusy; }
        content.StateChanged += UpdateButtons; dialog.Opened += async (_, _) => await content.ActivateAsync();
        dialog.PrimaryButtonClick += async (_, args) =>
        { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.SubmitAsync(); } finally { deferral.Complete(); } };
        dialog.SecondaryButtonClick += async (_, args) =>
        { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.ReloadAsync(); } finally { deferral.Complete(); } };
        try { await dialog.ShowAsync(); }
        finally { content.StateChanged -= UpdateButtons; if (ReferenceEquals(_powerDialog, dialog)) { _powerDialog = null; _powerContent = null; } }
        if (!_disposed && content.NeedsParentRefresh && _repository.ProfileId == _viewModel.ActiveProfileId) await RunAsync(_viewModel.RefreshAsync);
    }
    private void UpdatePowerControls()
    {
        bool Allows(VirtualMachinePowerAction action) => !_disposed && !_viewModel.IsLoading && !_viewModel.RequiresReconnect &&
            _repository.ProfileId == _viewModel.ActiveProfileId && _viewModel.SelectedMachine?.Machine is { } target && VirtualMachinePowerRules.CanRequest(target, action);
        PowerOnButton.IsEnabled = Allows(VirtualMachinePowerAction.PowerOn); ShutdownButton.IsEnabled = Allows(VirtualMachinePowerAction.Shutdown); PowerOffButton.IsEnabled = Allows(VirtualMachinePowerAction.PowerOff);
    }
    private void ClosePowerDialog() { _powerContent?.Dispose(); _powerDialog?.Hide(); _powerContent = null; _powerDialog = null; }
}
