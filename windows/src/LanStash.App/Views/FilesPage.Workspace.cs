using LanStash.App.Features.Settings;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using D = LanStash.App.Features.Settings.WorkspaceDestination;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private void ApplyWorkspaceDestination()
    {
        if (_disposed) return;
        switch (_workspaceDestination)
        {
            case D.Favorites: ShowLocationCollection(FileLocationSource.Favorite); break;
            case D.Recent: ShowLocationCollection(FileLocationSource.Recent); break;
            case D.RemoteLocations: ShowLocationCollection(FileLocationSource.Remote); break;
            case D.Recycle: ShowLocationCollection(FileLocationSource.Recycle); break;
            case D.SharedLinks:
                HideLocationCollection();
                ManageShareLinks_Click(this, new RoutedEventArgs());
                break;
            default: HideLocationCollection(); break;
        }
    }

    private void ShowLocationCollection(FileLocationSource? source)
    {
        if (_disposed || !_locationsViewModel.IsActive) return;
        CancelFileSearch();
        _locationCollectionOpen = true;
        LocationsPane.ShowSection(source);
        UpdateLocationsLayout();
        UpdatePreviewLayout();
    }

    private void HideLocationCollection()
    {
        _locationCollectionOpen = false;
        LocationsPane.CancelOpening();
        UpdateLocationsLayout();
        UpdatePreviewLayout();
    }

    private void InspectorToggle_Click(object sender, RoutedEventArgs args)
    {
        _inspectorVisible = InspectorToggle.IsChecked == true;
        UpdatePreviewLayout();
    }

    private void QueueStateUpdate()
    {
        if (!_renderInvalidation.TryRequest()) return;
        if (!DispatcherQueue.TryEnqueue(() =>
        {
            if (_renderInvalidation.Consume() && !_disposed) UpdateState();
        })) _renderInvalidation.Consume();
    }

    private void CancelFileSearch()
    {
        var previous = _searchCancellation;
        _searchCancellation = null;
        previous?.Cancel();
    }
}
