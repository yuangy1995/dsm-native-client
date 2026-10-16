using LanStash.App.Features.Files.Sharing;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private bool CanEnterShareSelection() => !_disposed && !_viewModel.IsLoading && !_isSelectingItems &&
        !IsReadOnlyLocation() && _shareLinkDialog is null && _shareRepository?.ShareLinkAvailability.IsAvailable == true &&
        _viewModel.Items.Any(item => CanSelectForSharing(item.Item));

    private bool CanSelectForSharing(FileItem item) => !IsReadOnlyLocation() && item.Path.StartsWith('/') &&
        item.Path.Length > 1 && !item.Path.EndsWith('/') && !item.Path.Contains('\\') &&
        !item.Path.Split('/').Any(part => part is "." or ".." || part.Equals("#recycle", StringComparison.OrdinalIgnoreCase));

    private async void ShareMultiple_Click(object sender, RoutedEventArgs e)
    {
        if (!await ClosePreviewAsync()) return;
        if (!CanEnterShareSelection()) return;
        var selected = _viewModel.SelectedItem;
        _batchSelectionOperation = FileBatchSelectionOperation.Share;
        _batchSelection.Clear();
        FileList.SelectionMode = FileGrid.SelectionMode = ListViewSelectionMode.Multiple;
        FileList.SelectedItems.Clear(); FileGrid.SelectedItems.Clear();
        if (selected is not null && CanSelectForSharing(selected.Item)) _batchSelection.Add(selected.Path);
        ApplyDownloadSelection(VisibleFilesControl()); AnnounceBatchSelection(); UpdateState();
    }

    private async void ShareSelectedItems_Click(object sender, RoutedEventArgs e)
    {
        if (_batchSelectionOperation != FileBatchSelectionOperation.Share || _shareRepository is null || _shareLinkDialog is not null) return;
        var targets = _viewModel.Items.Where(item => _batchSelection.Contains(item.Path)).Select(item => item.Item).ToArray();
        if (targets.Length == 0 || targets.Length != _batchSelection.Count || targets.Any(item => !CanSelectForSharing(item))) return;
        var localization = LocalizationService.Current;
        var models = targets.Select(item => new FileShareLinkViewModel(_shareRepository, _profileId, item, _systemShare.IsAvailable,
            _shareReviewBlocker.Contains(_profileId, item.Path))).ToArray();
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = localization.Get("FileShareBatchCreateTitle"),
            CloseButtonText = localization.Get("ActionClose"), DefaultButton = ContentDialogButton.None };
        _shareLinkDialog = dialog;
        var index = 0;
        void Render()
        {
            if (_disposed || !ReferenceEquals(_shareLinkDialog, dialog)) return;
            var model = models[index];
            _shareLinkModel = model;
            var panel = new StackPanel { Spacing = 12, MinWidth = 440, MaxWidth = 480 };
            var selection = new ComboBox { Header = localization.Get("FileShareBatchTarget"),
                HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = model.State != FileShareLinkPresentationState.Creating };
            for (var item = 0; item < models.Length; item++)
            {
                var entry = models[item];
                var status = entry.State switch
                {
                    FileShareLinkPresentationState.Success => "FileShareCreated",
                    FileShareLinkPresentationState.NeedsReview => "FileShareChangePending",
                    FileShareLinkPresentationState.Form => "FileShareNotSubmitted",
                    _ => "FileShareLinkFailureTitle",
                };
                selection.Items.Add(new ComboBoxItem { Content = localization.Format("FileShareItemOutcome",
                    entry.TargetName, localization.Get(status)), MinHeight = 44 });
            }
            selection.SelectedIndex = index;
            selection.SelectionChanged += (_, _) => { if (selection.SelectedIndex >= 0) { index = selection.SelectedIndex; Render(); } };
            AutomationProperties.SetName(selection, localization.Get("FileShareBatchTarget"));
            panel.Children.Add(selection);
            panel.Children.Add(BuildShareDialogContent(model, localization, Render));
            dialog.Content = panel;
        }
        dialog.Closing += (_, args) =>
        {
            if (_isClosingShareLink || _shareLinkDialog != dialog || models[index].State != FileShareLinkPresentationState.Creating) return;
            args.Cancel = true; models[index].RequestCancellation(); Render();
        };
        Render();
        try { await dialog.ShowAsync(); }
        finally
        {
            foreach (var model in models) model.Dispose();
            _shareLinkModel = null;
            if (ReferenceEquals(_shareLinkDialog, dialog)) _shareLinkDialog = null;
            _isClosingShareLink = false;
            if (!_disposed) UpdateState();
        }
    }
}
