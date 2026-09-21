using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class NasDetailsPage
{
    private ContentDialog? _serviceSettingsDialog;
    private INasSettingsDialogContent? _serviceSettingsContent;

    private async void TerminalSettings_Click(object sender, RoutedEventArgs e) =>
        await ShowServiceSettingsAsync(terminal: true);

    private async void ProxySettings_Click(object sender, RoutedEventArgs e) =>
        await ShowServiceSettingsAsync(terminal: false);

    private async Task ShowServiceSettingsAsync(bool terminal)
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        var content = new NasServiceSettingsDialogContent(_settingsRepository, terminal);
        await ShowSettingsContentAsync(content, terminal ? "NasSettingsTerminalTitle" : "NasSettingsProxyTitle");
    }

    private async void FileServiceSettings_Click(object sender, RoutedEventArgs e) =>
        await ShowFileServiceSettingsAsync();

    private async Task ShowFileServiceSettingsAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasFileServiceSettingsDialogContent(_settingsRepository), "NasSettingsFileServiceTitle");
    }

    private async void RegionSettings_Click(object sender, RoutedEventArgs e) => await ShowRegionSettingsAsync();

    private async Task ShowRegionSettingsAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasRegionSettingsDialogContent(_settingsRepository), "NasSettingsRegionTitle");
    }

    private async void NetworkSettings_Click(object sender, RoutedEventArgs e) => await ShowNetworkSettingsAsync();
    private async Task ShowNetworkSettingsAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasNetworkSettingsDialogContent(_settingsRepository), "NasSettingsNetworkTitle");
    }

    private async void SecuritySettings_Click(object sender, RoutedEventArgs e) => await ShowSecuritySettingsAsync();
    private async Task ShowSecuritySettingsAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasSecuritySettingsDialogContent(_settingsRepository), "NasSettingsSecurityTitle");
    }

    private async void HardwareSettings_Click(object sender, RoutedEventArgs e) => await ShowHardwareSettingsAsync();
    private async Task ShowHardwareSettingsAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasHardwareSettingsDialogContent(_settingsRepository), "NasSettingsHardwareTitle");
    }

    private async void DdnsSettings_Click(object sender, RoutedEventArgs e) => await ShowDdnsDialogAsync();
    private async Task ShowDdnsDialogAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasDdnsSettingsDialogContent(_settingsRepository), "NasSettingsDdnsTitle");
    }

    private async void PackageSettings_Click(object sender, RoutedEventArgs e) => await ShowPackageSettingsAsync();
    private async Task ShowPackageSettingsAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasPackageSettingsDialogContent(_settingsRepository), "NasPackageManagerTitle");
    }

    private async void DirectorySettings_Click(object sender, RoutedEventArgs e) => await ShowDirectorySettingsAsync();
    private async Task ShowDirectorySettingsAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasDirectorySettingsDialogContent(_settingsRepository), "NasDirectoryManagerTitle");
    }

    private async void PowerSettings_Click(object sender, RoutedEventArgs e) => await ShowPowerSettingsAsync();
    private async Task ShowPowerSettingsAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasPowerSettingsDialogContent(_settingsRepository), "NasSettingsPowerTitle");
    }

    private async void ConnectionsSettings_Click(object sender, RoutedEventArgs e) => await ShowConnectionsSettingsAsync();
    private async Task ShowConnectionsSettingsAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasConnectionsSettingsDialogContent(_settingsRepository), "NasConnectionsTitle");
    }

    private async void TasksSettings_Click(object sender, RoutedEventArgs e) => await ShowTasksSettingsAsync();
    private async Task ShowTasksSettingsAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasTasksSettingsDialogContent(_settingsRepository), "NasTasksTitle");
    }

    private async void DiskTests_Click(object sender, RoutedEventArgs e) => await ShowDiskTestsAsync();
    private async Task ShowDiskTestsAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasDiskTestsDialogContent(_settingsRepository), "NasDiskTitle");
    }

    private async void RemoteAccess_Click(object sender, RoutedEventArgs e) => await ShowRemoteAccessAsync();
    private async Task ShowRemoteAccessAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasRemoteAccessDialogContent(_settingsRepository), "NasRemoteTitle");
    }

    private async void PowerSchedule_Click(object sender, RoutedEventArgs e) => await ShowPowerScheduleAsync();
    private async Task ShowPowerScheduleAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasPowerScheduleDialogContent(_settingsRepository), "NasPowerScheduleTitle");
    }

    private async void ExternalStorage_Click(object sender, RoutedEventArgs e) => await ShowExternalStorageAsync();
    private async Task ShowExternalStorageAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasExternalStorageDialogContent(_settingsRepository), "NasExternalTitle");
    }

    private async void Zram_Click(object sender, RoutedEventArgs e) => await ShowZramAsync();
    private async Task ShowZramAsync()
    {
        if (_disposed || _settingsRepository is null || _serviceSettingsDialog is not null ||
            _settingsRepository.ProfileId != _viewModel.ActiveProfileId) return;
        await ShowSettingsContentAsync(new NasZramDialogContent(_settingsRepository), "NasZramTitle");
    }

    private async Task ShowSettingsContentAsync(INasSettingsDialogContent content, string titleKey)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = LocalizationService.Current.Get(titleKey),
            Content = content,
            PrimaryButtonText = content.PrimaryButtonResourceKey is { } primaryKey ? LocalizationService.Current.Get(primaryKey) : "",
            SecondaryButtonText = LocalizationService.Current.Get("NasServiceReload"),
            CloseButtonText = LocalizationService.Current.Get("ActionClose"),
            DefaultButton = ContentDialogButton.Close,
            IsPrimaryButtonEnabled = false,
        };
        _serviceSettingsDialog = dialog;
        _serviceSettingsContent = content;
        void UpdateButtons()
        {
            dialog.IsPrimaryButtonEnabled = content.CanSave;
            dialog.IsSecondaryButtonEnabled = !content.IsBusy;
        }
        content.StateChanged += UpdateButtons;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            try { await content.SaveAsync(); }
            finally { deferral.Complete(); }
        };
        dialog.SecondaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            try { await content.ReloadAsync(); }
            finally { deferral.Complete(); }
        };
        dialog.Opened += async (_, _) => await content.ActivateAsync();
        try { await dialog.ShowAsync(); }
        finally
        {
            content.StateChanged -= UpdateButtons;
            content.Dispose();
            if (ReferenceEquals(_serviceSettingsDialog, dialog))
            {
                _serviceSettingsDialog = null;
                _serviceSettingsContent = null;
            }
        }
    }

    private void CloseServiceSettings()
    {
        _serviceSettingsContent?.Dispose();
        _serviceSettingsDialog?.Hide();
        _serviceSettingsContent = null;
        _serviceSettingsDialog = null;
    }
}
