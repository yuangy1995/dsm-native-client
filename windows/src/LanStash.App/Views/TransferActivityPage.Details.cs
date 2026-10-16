using System.Globalization;
using LanStash.App.Features.Files.Activity;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class TransferActivityPage
{
    private async void Details_Click(object sender, RoutedEventArgs args)
    {
        if (_disposed || _detailsDialog is not null || sender is not FrameworkElement { Tag: ForegroundTransferActivity activity } || activity.ProfileId != _profileId) return;
        if (activity.Source == ForegroundTransferSource.NasFileStation && activity.SourceIdentifier is { } identifier && identifier.StartsWith("file:", StringComparison.Ordinal))
        {
            var id = identifier[5..];
            var task = _fileRefresher.FindTask(id) ?? _pendingFileControls.FirstOrDefault(p => p.Change.Task.Id == id)?.Change.Task;
            if (task is not null) await ShowFileTaskDetailsAsync(task);
        }
        else await ShowTransferDetailsAsync(activity);
    }

    internal async Task ShowFileTaskDetailsAsync(FileBackgroundTaskSummary task)
    {
        if (_disposed || _detailsDialog is not null) return;
        using var model = new FileBackgroundTaskViewModel(_fileRepository, task);
        var text = LocalizationService.Current;
        var panel = new StackPanel { Spacing = 12, MinWidth = 300, MaxWidth = 560 };
        var summary = new StackPanel { Spacing = 8 };
        var loading = new ProgressRing { Width = 24, Height = 24 };
        var notice = new InfoBar { IsClosable = false };
        var refresh = new Button { Content = text.Get("FileTaskRefresh"), MinHeight = 44 };
        var risk = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        panel.Children.Add(loading); panel.Children.Add(summary); panel.Children.Add(notice); panel.Children.Add(refresh); panel.Children.Add(risk);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = XamlRoot.Content is FrameworkElement root ? root.ActualTheme : ElementTheme.Default, Title = text.Get("FileTaskDetailsTitle"),
            Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled },
            CloseButtonText = text.Get("ActionClose"), DefaultButton = ContentDialogButton.Close };
        _detailsDialog = dialog;
        var confirming = false;
        void Render()
        {
            if (_disposed) return;
            summary.Children.Clear();
            void Line(string value) => summary.Children.Add(new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            Line(text.Get(ActivityPresentation.FileTaskNameKey(model.Task.Kind)));
            Line(text.Get(model.Task.State == FileBackgroundTaskState.Finished ? "TransferActivityFileEndedNeedsReview" : "TransferActivityFileRunning"));
            if (model.Task.CreatedAt is { } created) Line(text.Format("FileTaskCreated", created.ToLocalTime().ToString("G", CultureInfo.CurrentCulture)));
            if (model.Task.Progress is { } progress) summary.Children.Add(new ProgressBar { Minimum = 0, Maximum = 1, Value = progress });
            if (model.Task.ProcessedItemCount is { } count) Line(text.Format("FileTaskProcessedItems", count));
            if (model.Task.ProcessedBytes is { } bytes) Line(text.Format("FileTaskProcessedBytes", bytes));
            summary.Children.Add(new Expander { Header = text.Get("FileTaskReference"), Content = new TextBlock { Text = model.Task.Id, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap } });
            notice.IsOpen = model.MessageKey is not null;
            notice.Message = model.MessageKey is { } key ? text.Get(key) : "";
            notice.Severity = model.Progress?.Outcome.Status == MutationResultStatus.ConfirmedSuccess ? InfoBarSeverity.Success : InfoBarSeverity.Informational;
            refresh.IsEnabled = !model.IsBusy;
            loading.IsActive = model.IsBusy; loading.Visibility = model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
            dialog.PrimaryButtonText = model.CanControl ? text.Get(model.Action == FileBackgroundTaskAction.Clear ? "FileTaskClear" : "FileTaskStop") : "";
            dialog.IsPrimaryButtonEnabled = model.CanControl;
            risk.Text = text.Get(model.Action == FileBackgroundTaskAction.Clear ? "FileTaskClearRisk" : "FileTaskStopRisk");
            risk.Visibility = confirming ? Visibility.Visible : Visibility.Collapsed;
        }
        model.PropertyChanged += (_, _) => Render();
        refresh.Click += async (_, _) => { confirming = false; await model.RefreshAsync(); };
        dialog.PrimaryButtonClick += async (_, e) =>
        {
            e.Cancel = true;
            if (!confirming) { confirming = true; Render(); return; }
            var deferral = e.GetDeferral();
            try { confirming = false; await model.ControlAsync(true); Render(); }
            finally { deferral.Complete(); }
        };
        dialog.Opened += async (_, _) => await model.RefreshAsync();
        try { Render(); await dialog.ShowAsync(); }
        finally { model.Dispose(); _detailsDialog = null; }
        await RefreshNasTasksAsync();
    }

    private async Task ShowTransferDetailsAsync(ForegroundTransferActivity activity)
    {
        var text = LocalizationService.Current;
        var row = ActivityPresentation.Create(activity);
        var panel = new StackPanel { Spacing = 12, MinWidth = 300, MaxWidth = 560 };
        void Line(string value) => panel.Children.Add(new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        Line(row.DisplayName); Line(row.SourceText);
        Action<ForegroundTransferActivity>? updateItems = null;
        string UnknownMessage(ForegroundTransferActivity value) => text.Get(value.FailureCategory == MutationErrorCategory.Authentication
            ? "TransferDetailAuthentication" : "TransferDetailUnknown");
        if (_transfers.CanRefreshUpload(activity))
        {
            var status = new TextBlock { Text = UnknownMessage(activity), TextWrapping = TextWrapping.Wrap };
            var refresh = new Button { Content = text.Get("FileTaskRefresh"), MinHeight = 44 };
            refresh.Click += async (_, _) =>
            {
                refresh.IsEnabled = false;
                await _transfers.RefreshUploadAsync(activity);
                if (_disposed) return;
                var current = _coordinator.GetActivities(_profileId).FirstOrDefault(item => item.Id == activity.Id);
                if (current is not null)
                {
                    status.Text = current.State == ForegroundTransferState.ResultNeedsReview
                        ? UnknownMessage(current) : ActivityPresentation.Create(current).StatusText;
                    updateItems?.Invoke(current);
                    refresh.IsEnabled = _transfers.CanRefreshUpload(current);
                }
                RenderActivities();
            };
            panel.Children.Add(status); panel.Children.Add(refresh);
        }
        else if (activity.State is ForegroundTransferState.Failed or ForegroundTransferState.ResultNeedsReview)
            Line(text.Get(activity.State == ForegroundTransferState.ResultNeedsReview ? "TransferDetailUnknown" : activity.FailureCategory switch
            {
                MutationErrorCategory.Authentication => "TransferDetailAuthentication",
                MutationErrorCategory.Permission => "TransferDetailPermission",
                MutationErrorCategory.Conflict when activity.Direction == ForegroundTransferDirection.Download => "FileStructureDownloadTargetExists",
                MutationErrorCategory.Conflict => "TransferDetailConflict",
                MutationErrorCategory.Network => "TransferDetailNetwork",
                MutationErrorCategory.Validation when activity.Direction == ForegroundTransferDirection.Download => "FileStructureDownloadInvalidNames",
                _ => "TransferDetailFailed",
            }));
        else Line(row.StatusText);
        if (activity.ItemResults.Count > 0)
        {
            var uploading = activity.Direction == ForegroundTransferDirection.Upload;
            var summary = new TextBlock { TextWrapping = TextWrapping.Wrap };
            var results = new ListView { MaxHeight = 320, SelectionMode = ListViewSelectionMode.None,
                ItemTemplate = (DataTemplate)Resources["TransferItemResultTemplate"] };
            updateItems = current =>
            {
                summary.Text = text.Format(uploading ? "TransferUploadSummary" : "FileStructureDownloadSummary",
                    current.ItemResults.Count(item => item.State == ForegroundTransferItemState.Completed),
                    current.ItemResults.Count(item => item.State == ForegroundTransferItemState.Failed),
                    current.ItemResults.Count(item => item.State == ForegroundTransferItemState.Cancelled),
                    current.ItemResults.Count(item => item.State is ForegroundTransferItemState.Waiting or ForegroundTransferItemState.Running),
                    current.ItemResults.Count(item => item.State == ForegroundTransferItemState.ResultNeedsReview));
                results.ItemsSource = current.ItemResults.Select(item => new TransferItemRow(item.RelativePath, text.Get(item.State switch
                {
                    ForegroundTransferItemState.Completed => uploading ? "TransferUploadItemCompleted" : "FileStructureItemCompleted",
                    ForegroundTransferItemState.Failed => uploading ? "TransferUploadItemFailed" : "FileStructureItemFailed",
                    ForegroundTransferItemState.Cancelled => "FileStructureItemCancelled",
                    ForegroundTransferItemState.Running => uploading ? "TransferUploadItemRunning" : "FileStructureItemRunning",
                    ForegroundTransferItemState.ResultNeedsReview => "TransferUploadItemPending",
                    _ => "FileStructureItemWaiting",
                }))).ToArray();
            };
            updateItems(activity); panel.Children.Add(summary);
            results.ItemContainerStyle = new Style(typeof(ListViewItem))
            { Setters = { new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch) } };
            panel.Children.Add(results);
        }
        var folder = activity.OriginalFolder;
        if (folder is not null) Line(folder);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = XamlRoot.Content is FrameworkElement root ? root.ActualTheme : ElementTheme.Default, Title = text.Get("FileTaskDetailsTitle"), Content = panel,
            CloseButtonText = text.Get("ActionClose"), PrimaryButtonText = folder is not null && _openOriginalFolder is not null ? text.Get("TransferDetailOpenFolder") : "",
            DefaultButton = ContentDialogButton.Close };
        _detailsDialog = dialog;
        ContentDialogResult result;
        try { result = await dialog.ShowAsync(); }
        finally { _detailsDialog = null; }
        if (!_disposed && result == ContentDialogResult.Primary && folder is not null && _openOriginalFolder is not null) await _openOriginalFolder(folder);
    }

    private sealed record TransferItemRow(string Name, string Status);
}
