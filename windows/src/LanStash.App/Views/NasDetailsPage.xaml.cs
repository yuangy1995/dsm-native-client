using LanStash.App.Localization;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class NasDetailsPage : Page, IDisposable
{
    private readonly NasDetailsViewModel _viewModel = new();
    private readonly NasDdnsViewModel? _ddnsViewModel;
    private readonly NasPowerViewModel? _powerViewModel;
    private INasSettingsRepository? _settingsRepository;
    private bool _disposed;

    public NasDetailsPage(INasDetailsRepository repository)
        : this(repository, settingsRepository: null)
    {
    }

    public NasDetailsPage(INasDetailsRepository repository, INasSettingsRepository? settingsRepository)
    {
        InitializeComponent();
        DataContext = _viewModel;
        _viewModel.PropertyChanged += (_, _) => UpdateState();
        _settingsRepository = settingsRepository;

        if (settingsRepository is not null)
        {
            _ddnsViewModel = new NasDdnsViewModel();
            _powerViewModel = new NasPowerViewModel();
            _ = ActivateWriteAsync(settingsRepository);
        }

        _ = ActivateAsync(repository);
    }

    public async Task ActivateAsync(INasDetailsRepository repository)
    {
        if (_disposed)
        {
            return;
        }
        await _viewModel.ActivateAsync(repository);
        RestoreSectionSelection();
        UpdateState();
    }

    public async Task ActivateWriteAsync(INasSettingsRepository settingsRepository)
    {
        if (_disposed)
        {
            return;
        }
        _settingsRepository = settingsRepository;

        if (_ddnsViewModel is not null)
        {
            await _ddnsViewModel.ActivateAsync(settingsRepository);
        }
        if (_powerViewModel is not null)
        {
            await _powerViewModel.ActivateAsync(settingsRepository);
        }

        UpdateWriteAvailability();
    }

    public void Deactivate() =>
        _viewModel.Deactivate();

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _viewModel.Dispose();
        _ddnsViewModel?.Dispose();
        _powerViewModel?.Dispose();
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.RefreshAsync();
        RestoreSectionSelection();
        UpdateState();
    }

    private async void RunStorageAnalysis_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.SelectSection(NasDetailsSectionKind.StorageAnalysis);
        RestoreSectionSelection();
        UpdateState();
        await _viewModel.RunStorageAnalysisAsync();
        RestoreSectionSelection();
        UpdateState();
    }

    private async void RunDeepStorageAnalysis_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.SelectSection(NasDetailsSectionKind.StorageAnalysis);
        RestoreSectionSelection();
        UpdateState();
        await _viewModel.RunDeepStorageAnalysisAsync();
        RestoreSectionSelection();
        UpdateState();
    }

    private void CancelStorageAnalysis_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.CancelStorageAnalysis();
        UpdateState();
    }

    private void SectionList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SectionList.SelectedItem is NasDetailsSectionOption option)
        {
            _viewModel.SelectSection(option.Kind);
            RestoreSectionSelection();
            UpdateState();
        }
    }

    private async void RefreshAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await _viewModel.RefreshAsync();
        RestoreSectionSelection();
        UpdateState();
    }

    private void RestoreSectionSelection()
    {
        if (SectionList is null)
        {
            return;
        }
        var selected = _viewModel.SelectedSection;
        var item = _viewModel.Sections.FirstOrDefault(section => section.Kind == selected);
        if (item is not null && !ReferenceEquals(SectionList.SelectedItem, item))
        {
            SectionList.SelectedItem = item;
        }
    }

    private void UpdateState()
    {
        if (RefreshButton is null)
        {
            return;
        }
        RefreshButton.IsEnabled = _viewModel.CanRefresh;
        RunStorageAnalysisButton.IsEnabled = _viewModel.CanRunStorageAnalysis;
        RunDeepStorageAnalysisButton.IsEnabled = _viewModel.CanRunDeepStorageAnalysis;
        CancelStorageAnalysisButton.Visibility = _viewModel.CanCancelStorageAnalysis
            ? Visibility.Visible
            : Visibility.Collapsed;
        CancelStorageAnalysisButton.IsEnabled = _viewModel.CanCancelStorageAnalysis;
        RefreshErrorNotice.IsOpen = _viewModel.HasRefreshError;
        LoadingState.Visibility = _viewModel.IsLoading && !_viewModel.HasContent
            ? Visibility.Visible
            : Visibility.Collapsed;
        ContentState.Visibility = _viewModel.HasContent
            ? Visibility.Visible
            : Visibility.Collapsed;
        EmptyState.Visibility = !_viewModel.IsLoading && _viewModel.IsEmpty
            ? Visibility.Visible
            : Visibility.Collapsed;
        ErrorState.Visibility = !_viewModel.IsLoading && _viewModel.HasError
            ? Visibility.Visible
            : Visibility.Collapsed;
        UnavailableState.Visibility = !_viewModel.IsLoading && _viewModel.IsUnavailable
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void UpdateWriteAvailability()
    {
        if (_settingsRepository is null)
        {
            return;
        }

        var availability = _settingsRepository.WriteAvailability;

        if (availability.CanPowerAction ||
            availability.CanSaveDDNS ||
            availability.CanSaveFileService ||
            availability.CanSaveTerminal ||
            availability.CanSaveProxy ||
            availability.CanSaveNetwork ||
            availability.CanSaveRegion ||
            availability.CanSaveSecurity ||
            availability.CanSaveHardware)
        {
            ReadOnlyInfoBar.Visibility = Visibility.Collapsed;
            ReadOnlyInfoBar.IsOpen = false;
            ReadWriteInfoBar.Visibility = Visibility.Visible;
            ReadWriteInfoBar.IsOpen = true;
        }
    }

    // 写操作对话框辅助方法

    private async Task ShowEditDialogAsync<T>(
        string title,
        NasSettingsEditViewModel<T> editor) where T : class
    {
        if (_settingsRepository is null)
        {
            return;
        }

        var saveButtonText = LocalizationService.Current.Get("ActionSave");
        var cancelButtonText = LocalizationService.Current.Get("ActionCancel");

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = title,
            PrimaryButtonText = saveButtonText,
            CloseButtonText = cancelButtonText,
            DefaultButton = ContentDialogButton.Primary,
        };

        // 创建用于编辑的基础纵向面板。
        var contentPanel = new StackPanel { Spacing = 12 };
        dialog.Content = contentPanel;

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            await editor.SaveAsync();
            if (editor.LastResult?.Status == MutationResultStatus.ConfirmedSuccess)
            {
                dialog.Hide();
            }
        };

        await dialog.ShowAsync();
    }

    private async Task ShowPowerActionDialogAsync()
    {
        if (_powerViewModel is null || _settingsRepository is null)
        {
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = LocalizationService.Current.Get("NasSettingsPowerTitle"),
            PrimaryButtonText = LocalizationService.Current.Get("NasSettingsShutdownLabel"),
            SecondaryButtonText = LocalizationService.Current.Get("NasSettingsRebootLabel"),
            CloseButtonText = LocalizationService.Current.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Close,
        };

        _powerViewModel.CancelAction();

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            _powerViewModel.RequestShutdown();
            await ConfirmAndExecutePowerAsync(dialog);
        };

        dialog.SecondaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            _powerViewModel.RequestReboot();
            await ConfirmAndExecutePowerAsync(dialog);
        };

        await dialog.ShowAsync();
    }

    private async Task ConfirmAndExecutePowerAsync(ContentDialog dialog)
    {
        if (_powerViewModel is null || _powerViewModel.ConfirmationMessage is null)
        {
            return;
        }

        var confirmDialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = _powerViewModel.ConfirmationMessage,
            PrimaryButtonText = LocalizationService.Current.Get("ActionAcknowledge"),
            CloseButtonText = LocalizationService.Current.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Close,
        };

        var result = await confirmDialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            await _powerViewModel.ExecuteActionAsync();
            dialog.Hide();
        }
    }

    private async Task ShowDdnsDialogAsync()
    {
        if (_ddnsViewModel is null || _settingsRepository is null)
        {
            return;
        }

        await _ddnsViewModel.RefreshAsync();

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = LocalizationService.Current.Get("NasSettingsDdnsTitle"),
            CloseButtonText = LocalizationService.Current.Get("ActionClose"),
            DefaultButton = ContentDialogButton.Close,
        };

        var contentPanel = new StackPanel { Spacing = 12 };

        // 显示现有记录。
        if (_ddnsViewModel.Records.Count > 0)
        {
            foreach (var record in _ddnsViewModel.Records)
            {
                var recordPanel = new StackPanel { Spacing = 4 };
                recordPanel.Children.Add(new TextBlock
                {
                    Text = $"{record.Hostname} ({record.ProviderId})",
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                });
                recordPanel.Children.Add(new TextBlock
                {
                    Text = record.Status ?? LocalizationService.Current.Get("UnknownValue"),
                    Foreground = (Microsoft.UI.Xaml.Media.Brush)
                        Application.Current.Resources["TextFillColorSecondaryBrush"],
                });

                var actionsPanel = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    Margin = new Microsoft.UI.Xaml.Thickness(0, 4, 0, 0),
                };

                var editButton = new Button
                {
                    Content = LocalizationService.Current.Get("ActionEdit"),
                    MinHeight = 32,
                };
                var recordId = record.Id;
                editButton.Click += async (_, _) =>
                {
                    _ddnsViewModel.BeginEdit(record);
                    await ShowDdnsEditFormAsync(dialog, record.Id);
                };
                actionsPanel.Children.Add(editButton);

                var testButton = new Button
                {
                    Content = LocalizationService.Current.Get("NasSettingsDdnsTest"),
                    MinHeight = 32,
                };
                testButton.Click += async (_, _) =>
                {
                    await _ddnsViewModel.TestAsync(recordId);
                };
                actionsPanel.Children.Add(testButton);

                var deleteButton = new Button
                {
                    Content = LocalizationService.Current.Get("ActionDelete.Label"),
                    MinHeight = 32,
                };
                deleteButton.Click += async (_, _) =>
                {
                    await ShowDeleteConfirmationAsync(
                        LocalizationService.Current.Get("NasSettingsDdnsDeleteTitle"),
                        record.Hostname,
                        () => _ddnsViewModel.DeleteAsync(recordId));
                };
                actionsPanel.Children.Add(deleteButton);

                recordPanel.Children.Add(actionsPanel);
                contentPanel.Children.Add(recordPanel);
            }
        }
        else
        {
            contentPanel.Children.Add(new TextBlock
            {
                Text = LocalizationService.Current.Get("NasSettingsDdnsNone"),
            });
        }

        // 添加按钮。
        var addButton = new Button
        {
            Content = LocalizationService.Current.Get("NasSettingsDdnsAdd"),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            MinHeight = 44,
        };
        addButton.Click += async (_, _) =>
        {
            _ddnsViewModel.BeginCreate();
            await ShowDdnsEditFormAsync(dialog, null);
        };
        contentPanel.Children.Add(addButton);

        dialog.Content = new ScrollViewer { Content = contentPanel, MaxHeight = 500 };
        await dialog.ShowAsync();
    }

    private async Task ShowDdnsEditFormAsync(ContentDialog parentDialog, string? existingRecordId)
    {
        if (_ddnsViewModel is null)
        {
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = existingRecordId is not null
                ? LocalizationService.Current.Get("NasSettingsDdnsEdit")
                : LocalizationService.Current.Get("NasSettingsDdnsAdd"),
            PrimaryButtonText = LocalizationService.Current.Get("ActionSave"),
            CloseButtonText = LocalizationService.Current.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Primary,
        };

        var form = new StackPanel { Spacing = 12 };
        var hostnameBox = new TextBox
        {
            PlaceholderText = LocalizationService.Current.Get("NasSettingsDdnsHostname"),
            Text = _ddnsViewModel.Draft.Hostname ?? string.Empty,
        };
        hostnameBox.TextChanged += (_, _) =>
        {
            _ddnsViewModel.Draft.Hostname = hostnameBox.Text;
        };
        form.Children.Add(hostnameBox);

        var usernameBox = new TextBox
        {
            PlaceholderText = LocalizationService.Current.Get("NasSettingsDdnsUsername"),
            Text = _ddnsViewModel.Draft.Username ?? string.Empty,
        };
        usernameBox.TextChanged += (_, _) =>
        {
            _ddnsViewModel.Draft.Username = usernameBox.Text;
        };
        form.Children.Add(usernameBox);

        var passwordBox = new PasswordBox
        {
            PlaceholderText = LocalizationService.Current.Get("NasSettingsDdnsPassword"),
            Password = _ddnsViewModel.Draft.Password ?? string.Empty,
        };
        passwordBox.PasswordChanged += (_, _) =>
        {
            _ddnsViewModel.Draft.Password = passwordBox.Password;
        };
        form.Children.Add(passwordBox);

        var enabledToggle = new ToggleSwitch
        {
            Header = LocalizationService.Current.Get("NasSettingsDdnsEnabled"),
            IsOn = _ddnsViewModel.Draft.IsEnabled,
        };
        enabledToggle.Toggled += (_, _) =>
        {
            _ddnsViewModel.Draft.IsEnabled = enabledToggle.IsOn;
        };
        form.Children.Add(enabledToggle);

        dialog.Content = form;

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            await _ddnsViewModel.SaveAsync(existingRecordId);
            if (_ddnsViewModel.LastResult?.Status == MutationResultStatus.ConfirmedSuccess)
            {
                dialog.Hide();
            }
        };

        await dialog.ShowAsync();
    }

    private async Task ShowDeleteConfirmationAsync(
        string title,
        string itemName,
        Func<Task> deleteAction)
    {
        var confirmDialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = title,
            Content = LocalizationService.Current.Format("DeleteItemWarning", itemName),
            PrimaryButtonText = LocalizationService.Current.Get("ActionDelete.Label"),
            CloseButtonText = LocalizationService.Current.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Close,
        };

        var result = await confirmDialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            await deleteAction();
        }
    }
}
