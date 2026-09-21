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
        ServiceSettingsButton.IsEnabled = settingsRepository is not null;
        // 普通离页只关闭临时表单，不销毁 Shell 缓存的页面模型。
        Unloaded += (_, _) => CloseServiceSettings();

        if (settingsRepository is not null)
        {
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
        if (!ReferenceEquals(_settingsRepository, settingsRepository)) CloseServiceSettings();
        _settingsRepository = settingsRepository;
        ServiceSettingsButton.IsEnabled = true;

        await Task.CompletedTask;

        UpdateWriteAvailability();
    }

    public void Deactivate()
    {
        CloseServiceSettings();
        _viewModel.Deactivate();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        CloseServiceSettings();
        _viewModel.Dispose();
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
        StorageOverviewCards.Visibility = _viewModel.SelectedSection == NasDetailsSectionKind.StorageHealth
            ? Visibility.Visible : Visibility.Collapsed;
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

}
