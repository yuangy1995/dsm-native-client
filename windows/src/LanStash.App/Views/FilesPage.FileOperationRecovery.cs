using LanStash.App.Features.Files;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private ContentDialog? _fileOperationRecoveryDialog;
    private FileOperationRecoveryViewModel? _fileOperationRecoveryModel;

    private async void CopyMoveRecovery_Click(object sender, RoutedEventArgs args) => await ShowCopyMoveRecoveryAsync();

    private Task ShowCopyMoveRecoveryAsync() => ShowFileOperationRecoveryAsync(recycle: false);
    private async void RecycleRecovery_Click(object sender, RoutedEventArgs args) => await ShowFileOperationRecoveryAsync(recycle: true);

    private async Task ShowFileOperationRecoveryAsync(bool recycle)
    {
        if (_disposed || _fileOperationRecoveryDialog is not null || _batchCopyMoveDialog is not null ||
            _batchRecycleDialog is not null || XamlRoot is null) return;
        if (recycle ? _recycleRepository is not { SupportsRecycleReview: true } || _recycleRepository.ProfileId != _profileId
            : _copyMoveRepository is not { SupportsCopyMoveReview: true } || _copyMoveRepository.ProfileId != _profileId) return;
        var model = recycle ? new FileOperationRecoveryViewModel(_recycleRepository!, _profileId, _recycleReviewBlocker)
            : new FileOperationRecoveryViewModel(_copyMoveRepository!, _profileId, _copyMoveReviewBlocker);
        var localization = LocalizationService.Current;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme, DefaultButton = ContentDialogButton.Close,
            Title = localization.Get(recycle ? "FileRecycleReviewListTitle" : "FileOperationReviewTitle"), CloseButtonText = localization.Get("FileRecycleCloseAction"),
        };
        _fileOperationRecoveryDialog = dialog; _fileOperationRecoveryModel = model;
        void Render()
        {
            if (_disposed || _fileOperationRecoveryDialog != dialog) return;
            dialog.PrimaryButtonText = model.Items.Count > 0 ? localization.Get("FileOperationReviewNow") : string.Empty;
            dialog.IsPrimaryButtonEnabled = model.CanReview;
            var panel = new StackPanel { Width = 480, MaxWidth = 480, Spacing = 12 };
            panel.Children.Add(new TextBlock { Text = localization.Get("FileOperationReviewHint"), TextWrapping = TextWrapping.Wrap });
            var refresh = new Button { Content = localization.Get("FileOperationReviewRefresh"), IsEnabled = !model.IsBusy, MinHeight = 40 };
            refresh.Click += async (_, _) => { var task = model.RefreshAsync(); Render(); await task; Render(); };
            panel.Children.Add(refresh);
            if (model.IsBusy) panel.Children.Add(new ProgressRing { IsActive = true, Width = 36, Height = 36 });
            if (model.Items.Count > 0)
            {
                var selection = new ComboBox { ItemsSource = model.Items, SelectedItem = model.Selected, DisplayMemberPath = "Name", IsEnabled = !model.IsBusy,
                    HorizontalAlignment = HorizontalAlignment.Stretch };
                AutomationProperties.SetName(selection, localization.Get("FileOperationReviewChoose"));
                selection.SelectionChanged += (_, _) => { model.Selected = selection.SelectedItem as FileOperationReviewEntry; Render(); };
                panel.Children.Add(selection);
                if (model.Selected is { } item)
                {
                    panel.Children.Add(new TextBlock { Text = localization.Get(item.OperationLabelKey) });
                    panel.Children.Add(new ScrollViewer { MaxHeight = 160, Content = new TextBlock
                    {
                        Text = localization.Format("FileOperationReviewPaths", item.SourcePath, item.DestinationPath), TextWrapping = TextWrapping.Wrap,
                        IsTextSelectionEnabled = true,
                    } });
                }
            }
            if (model.MessageKey is { } key)
            {
                var status = new InfoBar { IsOpen = true, IsClosable = false, Message = localization.Get(key),
                    Severity = key == "FileOperationReviewConfirmed" ? InfoBarSeverity.Success : InfoBarSeverity.Informational };
                AutomationProperties.SetLiveSetting(status, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
                panel.Children.Add(status);
            }
            dialog.Content = panel;
        }
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            try { var review = model.ReviewSelectedAsync(); Render(); await review; Render(); }
            finally { deferral.Complete(); }
        };
        dialog.Closing += (_, _) => model.Dispose();
        dialog.Loaded += async (_, _) =>
        {
            if (_disposed || _fileOperationRecoveryDialog != dialog) return;
            var load = model.RefreshAsync(); Render(); await load; Render();
        };
        Render();
        try { await dialog.ShowAsync(); }
        finally
        {
            model.Dispose();
            if (_fileOperationRecoveryDialog == dialog) { _fileOperationRecoveryDialog = null; _fileOperationRecoveryModel = null; }
        }
        if (!_disposed && model.ConfirmedCount > 0 && (recycle ? _recycleRepository?.ProfileId : _copyMoveRepository?.ProfileId) == _profileId) await RunAsync(_viewModel.RefreshAsync);
        if (!_disposed) UpdateState();
    }

    private void CloseFileOperationRecoveryDialog()
    {
        var dialog = _fileOperationRecoveryDialog;
        _fileOperationRecoveryDialog = null; _fileOperationRecoveryModel?.Dispose(); _fileOperationRecoveryModel = null;
        dialog?.Hide();
    }
}
