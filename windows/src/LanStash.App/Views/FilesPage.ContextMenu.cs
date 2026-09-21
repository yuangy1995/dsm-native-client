using LanStash.App.Features.Files;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private void Files_ContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if (_disposed || sender is not ListViewBase list) return;
        if (!_isSelectingItems && args.OriginalSource is DependencyObject source)
        {
            var container = FindItemContainer(list, source);
            if (container is not null && list.ItemFromContainer(container) is FileBrowserEntry entry)
                _viewModel.SelectedItem = entry;
            else if (args.TryGetPosition(list, out _))
                _viewModel.SelectedItem = null;
        }
        UpdateState();
        var menu = new MenuFlyout();
        if (_isSelectingItems)
        {
            AddContextCommand(menu, DownloadSelectedFilesButton, DownloadSelectedFiles_Click);
            AddContextCommand(menu, CopySelectedItemsButton, CopySelectedItems_Click);
            AddContextCommand(menu, MoveSelectedItemsButton, MoveSelectedItems_Click);
            AddContextCommand(menu, MoveSelectedToRecycleButton, MoveSelectedToRecycle_Click);
            AddContextCommand(menu, RestoreSelectedItemsButton, RestoreSelectedItems_Click);
        }
        else
        {
            if (_viewModel.SelectedItem is null)
            {
                AddContextCommand(menu, CreateFolderButton, CreateFolder_Click);
                AddContextCommand(menu, ToggleFavoriteButton, ToggleFavorite_Click);
                AddContextCommand(menu, RefreshButton, Refresh_Click);
            }
            else
            {
                AddContextCommand(menu, PreviewButton, Preview_Click);
                AddContextCommand(menu, ToggleFavoriteButton, ToggleFavorite_Click);
                AddContextCommand(menu, DownloadButton, Download_Click);
                AddContextCommand(menu, RenameButton, RenameItem_Click);
                AddContextCommand(menu, CopyFileButton, CopyFile_Click);
                AddContextCommand(menu, MoveFileButton, MoveFile_Click);
                AddContextCommand(menu, ShareLinkButton, ShareLink_Click);
                AddContextCommand(menu, MoveToRecycleButton, MoveToRecycle_Click);
                AddContextCommand(menu, RestoreFromRecycleButton, RestoreFromRecycle_Click);
            }
        }
        if (menu.Items.Count == 0) return;
        args.Handled = true;
        if (args.TryGetPosition(list, out var position))
            menu.ShowAt(list, new FlyoutShowOptions { Position = position });
        else
            menu.ShowAt(list);
    }

    private static void AddContextCommand(MenuFlyout menu, ButtonBase command, RoutedEventHandler handler)
    {
        if (command.Visibility != Visibility.Visible) return;
        var item = new MenuFlyoutItem
        {
            Text = command is AppBarButton appBar ? appBar.Label : (string)ToolTipService.GetToolTip(command),
            IsEnabled = command.IsEnabled,
            MinHeight = 40,
        };
        // 复用同一个处理器，右键入口不能绕过确认、权限与结果回读。
        item.Click += handler;
        menu.Items.Add(item);
    }
}
