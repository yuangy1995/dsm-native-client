using LanStash.App.Features.Files;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private readonly CollectionViewSource _groupedFiles = new() { IsSourceGrouped = true };
    private IReadOnlyList<FileBrowserGroup>? _renderedGroups;
    private bool _showsGroups;

    private void Group_Click(object sender, RoutedEventArgs e)
    {
        if (sender is RadioMenuFlyoutItem { Tag: string value } && Enum.TryParse<FileBrowserGrouping>(value, out var grouping))
        {
            ExitDownloadSelectionMode();
            _viewModel.Grouping = grouping;
        }
    }

    private void UpdateGroupingSource()
    {
        var grouped = _viewModel.Grouping != FileBrowserGrouping.None;
        if (_showsGroups != grouped || grouped && !ReferenceEquals(_renderedGroups, _viewModel.Groups))
        {
            _showsGroups = grouped;
            _renderedGroups = _viewModel.Groups;
            var selection = _viewModel.SelectedItem;
            var wasSynchronizing = _isSynchronizingDownloadSelection;
            _isSynchronizingDownloadSelection = true;
            try
            {
                if (grouped) _groupedFiles.Source = _viewModel.Groups;
                FileList.ItemsSource = grouped ? _groupedFiles.View : _viewModel.Items;
                FileGrid.ItemsSource = grouped ? _groupedFiles.View : _viewModel.Items;
                if (_isSelectingItems)
                {
                    ApplyDownloadSelection(FileList);
                    ApplyDownloadSelection(FileGrid);
                }
                else
                {
                    _viewModel.SelectedItem = selection;
                    FileList.SelectedItem = selection;
                    FileGrid.SelectedItem = selection;
                }
            }
            finally { _isSynchronizingDownloadSelection = wasSynchronizing; }
        }
        GroupNoneItem.IsChecked = _viewModel.Grouping == FileBrowserGrouping.None;
        GroupTypeItem.IsChecked = _viewModel.Grouping == FileBrowserGrouping.Type;
        GroupDateItem.IsChecked = _viewModel.Grouping == FileBrowserGrouping.Date;
        GroupSizeItem.IsChecked = _viewModel.Grouping == FileBrowserGrouping.Size;
    }
}
