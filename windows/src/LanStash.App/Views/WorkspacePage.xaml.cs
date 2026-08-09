using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class WorkspacePage : Page
{
    private readonly WorkspaceViewModel _viewModel;
    private static LocalizationService L => LocalizationService.Current;

    public WorkspacePage(AppViewModel app)
    {
        InitializeComponent();
        _viewModel = new WorkspaceViewModel(app);
        DataContext = _viewModel;
        _viewModel.PropertyChanged += (_, _) => UpdateState();
    }

    public async Task ShowModuleAsync(AppModule module)
    {
        SearchBox.Text = string.Empty;
        await _viewModel.ShowModuleAsync(module);
        if (_viewModel.Categories.Count > 0)
        {
            CategoryList.SelectedIndex = 0;
        }
        UpdateState();
    }

    public void CancelNasSettingsLoad() =>
        _viewModel.CancelNasSettingsLoad();

    private async void CategoryList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CategoryList.SelectedItem is WorkspaceCategoryOption category)
        {
            _viewModel.SelectedCategory = category.Id;
            await Task.CompletedTask;
        }
    }

    private async void SearchBox_QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args) =>
        await RunAsync(() => _viewModel.ReloadAsync(args.QueryText));

    private async void Refresh_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(() => _viewModel.ReloadAsync(SearchBox.Text));

    private async void Up_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.GoUpAsync);

    private async void ResourceList_ItemClick(object sender, ItemClickEventArgs e)
    {
        _viewModel.SelectedItem = e.ClickedItem as WorkspaceRow;
        await RunAsync(_viewModel.OpenSelectedAsync);
    }

    private async void Create_Click(object sender, RoutedEventArgs e)
    {
        var input = new TextBox
        {
            Header = L.Get("FieldFolderName"),
        };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(input);
        var dialog = CreateDialog(
            L.Get("DialogNewFolder"),
            panel,
            L.Get("ActionAdd"));
        if (await dialog.ShowAsync() == ContentDialogResult.Primary &&
            !string.IsNullOrWhiteSpace(input.Text))
        {
            await RunAsync(() => _viewModel.CreateAsync(input.Text));
        }
    }

    private async void Rename_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.SelectedItem is null)
        {
            return;
        }
        var input = new TextBox
        {
            Header = L.Get("FieldNewName"),
            Text = _viewModel.SelectedItem.Title,
            SelectionStart = 0,
            SelectionLength = _viewModel.SelectedItem.Title.Length,
        };
        var dialog = CreateDialog(L.Get("DialogRename"), input, L.Get("ActionSave"));
        if (await dialog.ShowAsync() == ContentDialogResult.Primary &&
            !string.IsNullOrWhiteSpace(input.Text))
        {
            await RunAsync(() => _viewModel.RenameSelectedAsync(input.Text));
        }
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.SelectedItem is null)
        {
            return;
        }
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(new TextBlock
        {
            Text = L.Format("DeleteItemWarning", _viewModel.SelectedItem.Title),
            TextWrapping = TextWrapping.Wrap,
        });
        var dialog = CreateDialog(
            L.Get("DialogConfirmDelete"),
            panel,
            L.Get("ActionDeleteText"));
        dialog.DefaultButton = ContentDialogButton.Close;
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await RunAsync(() => _viewModel.DeleteSelectedAsync());
        }
    }

    private async void KeepOffline_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.KeepSelectedOfflineAsync);

    private async void ReleaseOffline_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.ReleaseSelectedOfflineAsync);

    private ContentDialog CreateDialog(string title, object content, string primaryText) =>
        new()
        {
            XamlRoot = XamlRoot,
            Title = title,
            Content = content,
            PrimaryButtonText = primaryText,
            CloseButtonText = L.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Primary,
        };

    private async Task RunAsync(Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (DsmException error)
        {
            await ShowErrorAsync(L.ErrorMessage(error));
        }
        catch
        {
            await ShowErrorAsync(L.Get("ErrorOperationIncomplete"));
        }
        UpdateState();
    }

    private async Task ShowErrorAsync(string message)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = L.Get("ErrorOperationTitle"),
            Content = message,
            CloseButtonText = L.Get("ActionAcknowledge"),
        };
        await dialog.ShowAsync();
    }

    private void UpdateState()
    {
        if (CreateButton is null)
        {
            return;
        }
        CreateButton.Visibility = _viewModel.CanCreate ? Visibility.Visible : Visibility.Collapsed;
        UpButton.Visibility = _viewModel.Module == AppModule.Files &&
                              !string.IsNullOrWhiteSpace(_viewModel.CurrentPath)
            ? Visibility.Visible
            : Visibility.Collapsed;
        RenameButton.IsEnabled = _viewModel.CanRename;
        RenameButton.Visibility = _viewModel.Module == AppModule.Files
            ? Visibility.Visible
            : Visibility.Collapsed;
        DeleteButton.IsEnabled = _viewModel.CanDelete;
        DeleteButton.Visibility = _viewModel.Module == AppModule.Files
            ? Visibility.Visible
            : Visibility.Collapsed;
        KeepOfflineButton.Visibility =
            _viewModel.CanManageOffline && !_viewModel.SelectedFileIsKeptOffline
                ? Visibility.Visible
                : Visibility.Collapsed;
        ReleaseOfflineButton.Visibility =
            _viewModel.CanManageOffline && _viewModel.SelectedFileIsKeptOffline
                ? Visibility.Visible
                : Visibility.Collapsed;
        LoadingIndicator.IsActive = _viewModel.IsLoading;
        LoadingIndicator.Visibility = _viewModel.IsLoading ? Visibility.Visible : Visibility.Collapsed;
        EmptyState.Visibility = !_viewModel.IsLoading && _viewModel.HasMessage
            ? Visibility.Visible
            : Visibility.Collapsed;
        ResourceList.Visibility = _viewModel.IsLoading || _viewModel.HasMessage
            ? Visibility.Collapsed
            : Visibility.Visible;
        CategoryList.Visibility = _viewModel.Categories.Count > 0
            ? Visibility.Visible
            : Visibility.Collapsed;
    }
}
