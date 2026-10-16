using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private DispatcherTimer? _fileRefreshTimer;
    private bool _fileRefreshing;
    private readonly HashSet<Guid> _pendingFileChanges = [];
    private sealed record PhotoFileChangeChoice(Guid Id, string Title) { public override string ToString() => Title; }
    private void StartFileRefresh()
    {
        if (_disposed || !_windowVisible || !_model.Repository.SupportsFileManagement) return;
        if (_fileRefreshTimer is null)
        {
            _fileRefreshTimer = new() { Interval = TimeSpan.FromSeconds(15) };
            _fileRefreshTimer.Tick += async (_, _) => await RefreshFilesAsync();
        }
        _fileRefreshTimer.Start(); _ = RefreshFilesAsync();
    }
    private async Task RefreshFilesAsync()
    {
        if (_disposed || !_windowVisible || !IsLoaded || _dialog is not null || _fileRefreshing) return;
        _fileRefreshing = true; var generation = _viewGeneration;
        bool Current() => !_disposed && _windowVisible && IsLoaded && generation == _viewGeneration;
        try
        {
            var changes = await _model.Repository.FileChangesAsync();
            foreach (var change in changes.Where(change => change.Pending)) _pendingFileChanges.Add(change.Id);
            foreach (var change in changes.Where(change => change.Pending && !change.Running))
            { if (!Current() || _dialog is not null) return; await _model.Repository.ReviewFileChangeAsync(change.Id); }
            if (!Current() || _dialog is not null) return;
            changes = await _model.Repository.FileChangesAsync();
            foreach (var change in changes.Where(change => change.State == SynologyPhotoFileState.Completed && _pendingFileChanges.Contains(change.Id)))
            { if (!Current() || _dialog is not null) return; await _model.ApplyFileChangeAsync(change); _pendingFileChanges.Remove(change.Id); generation = _viewGeneration; }
            if (!Current()) return;
            PhotoFileBar.IsOpen = changes.Any(change => change.Pending);
            PhotoFileBar.Message = _l.Get("PhotosFileProcessing");
            if (_model.Deletion.Pending is not null) await _model.Deletion.ReviewAsync();
        }
        catch (Exception error)
        { if (Current()) { PhotoFileBar.Message = _l.Get(FileErrorKey(error)); PhotoFileBar.IsOpen = true; } }
        finally { _fileRefreshing = false; }
    }
    private string FileStateText(SynologyPhotoFileChange change) => change.State switch
    {
        SynologyPhotoFileState.Ready => _l.Get("PhotosChangeReady"),
        SynologyPhotoFileState.Submitting or SynologyPhotoFileState.PendingReview => _l.Get("PhotosFileProcessing"),
        SynologyPhotoFileState.Completed => _l.Get("PhotosFileCompleted"),
        SynologyPhotoFileState.Partial => _l.Get("PhotosFilePartial"),
        SynologyPhotoFileState.Cancelled => _l.Get("PhotosChangeCancelled"),
        _ => _l.Get(FileErrorKey(new SynologyPhotoException(change.Failure ?? SynologyPhotoFailure.WriteFailed))),
    };
    private async Task ShowFileChangesAsync(Guid? selected = null)
    {
        if (_disposed || _dialog is not null || !_model.Repository.SupportsFileManagement) return;
        var generation = _viewGeneration; var closed = false; var busy = false;
        var values = new Dictionary<Guid, SynologyPhotoFileChange>(); SynologyPhotoFileChange? resume = null;
        var picker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(picker, _l.Get("PhotosFileChanges"));
        var selection = new TextBlock { TextWrapping = TextWrapping.Wrap }; var target = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; var counts = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var names = new ListView { SelectionMode = ListViewSelectionMode.None, MaxHeight = 180 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(names, _l.Get("PhotosSelectedFiles"));
        var refresh = QueueButton("PhotosRefresh"); var proceed = QueueButton("PhotosContinueFiles"); var cancel = QueueButton("PhotosCancelFiles");
        var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; actions.Children.Add(refresh); actions.Children.Add(proceed);
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 560, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { picker, progress, selection, names, target, message, counts, actions, cancel }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosFileChanges"), CloseButtonText = _l.Get("PhotosClose"),
            Content = new ScrollViewer { Content = panel, MaxHeight = 550 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        SynologyPhotoFileChange? Selected() => picker.SelectedItem is PhotoFileChangeChoice choice ? values.GetValueOrDefault(choice.Id) : null;
        void Render()
        {
            if (!Current()) return; var value = Selected();
            selection.Text = value is null ? "" : FileSelectionText(value.Command);
            names.ItemsSource = value?.Command.Folders.Select(folder => folder.Name).Concat(value.Command.Photos.Select(photo => photo.Filename)).ToArray();
            target.Text = value?.Command.Destination is { } folder ? FileTargetText(folder) : "";
            message.Text = value is null ? _l.Get("PhotosFileChangesEmpty") : FileStateText(value);
            counts.Text = value?.Counts is { } total ? _l.Format("PhotosFileCounts", total.Total, total.Completion, total.Error, total.Skip, total.Overwrite) : "";
            picker.IsEnabled = refresh.IsEnabled = !busy; proceed.IsEnabled = !busy && value?.CanContinue == true;
            cancel.IsEnabled = !busy && value?.State is SynologyPhotoFileState.Ready or SynologyPhotoFileState.Failed;
            progress.IsActive = busy; progress.Visibility = Visible(busy);
        }
        async Task Load(bool review = false, bool cancelSelected = false)
        {
            if (!Current() || busy) return; var prior = Selected(); busy = true; Render();
            string? errorText = null;
            try
            {
                if (prior is not null && cancelSelected) await _model.Repository.CancelFileChangeAsync(prior.Id);
                var changes = await _model.Repository.FileChangesAsync();
                foreach (var change in changes.Where(change => change.Pending)) _pendingFileChanges.Add(change.Id);
                if (review)
                {
                    foreach (var change in changes.Where(change => change.Pending && !change.Running))
                    { if (!Current()) return; await _model.Repository.ReviewFileChangeAsync(change.Id); }
                    changes = await _model.Repository.FileChangesAsync();
                }
                if (!Current()) return;
                values = changes.ToDictionary(change => change.Id); var id = prior?.Id ?? selected;
                var entries = changes.Select((change, index) => new PhotoFileChangeChoice(change.Id, _l.Format("PhotosChangeChoice", index + 1, FileActionTitle(change.Command.Action)))).ToArray();
                picker.ItemsSource = entries; picker.SelectedIndex = entries.Length == 0 ? -1 : Math.Max(0, Array.FindIndex(entries, entry => entry.Id == id));
            }
            catch (Exception error) { errorText = _l.Get(FileErrorKey(error)); }
            finally { busy = false; Render(); if (Current() && errorText is not null) message.Text = errorText; }
        }
        picker.SelectionChanged += (_, _) => Render(); refresh.Click += async (_, _) => await Load(true);
        cancel.Click += async (_, _) => await Load(cancelSelected: true);
        proceed.Click += (_, _) => { if (!busy && Selected() is { CanContinue: true } value) { resume = value; dialog.Hide(); } };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
        timer.Tick += async (_, _) => { if (values.Values.Any(change => change.Pending)) await Load(true); };
        dialog.Closed += (_, _) => { closed = true; timer.Stop(); };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(true); await showing; }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
        if (_disposed || !_windowVisible || generation != _viewGeneration) return;
        if (resume is not null) await ShowFileCommandAsync(resume.Command, resume.Id);
        // 既有终态只展示历史。照片可能已在其他客户端恢复，不能重演旧操作对列表的影响。
        else foreach (var change in values.Values.Where(change => change.State == SynologyPhotoFileState.Completed && _pendingFileChanges.Contains(change.Id)))
            if (!_disposed) { await _model.ApplyFileChangeAsync(change); _pendingFileChanges.Remove(change.Id); }
    }
}
