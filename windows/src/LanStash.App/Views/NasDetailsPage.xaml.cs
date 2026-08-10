using LanStash.App.Features.NasAdmin;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class NasDetailsPage : Page, IDisposable
{
    private readonly NasDetailsViewModel _viewModel = new();
    private bool _disposed;

    public NasDetailsPage(INasDetailsRepository repository)
    {
        InitializeComponent();
        DataContext = _viewModel;
        _viewModel.PropertyChanged += (_, _) => UpdateState();
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
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.RefreshAsync();
        RestoreSectionSelection();
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
}
