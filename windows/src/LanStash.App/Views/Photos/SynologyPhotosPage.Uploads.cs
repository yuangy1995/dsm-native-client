using LanStash.App.Features.Transfers;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private bool _uploadPreparing;
    private async void UploadFiles_Click(object sender, RoutedEventArgs args) => await ChooseUploadAsync(false);
    private async void UploadFolder_Click(object sender, RoutedEventArgs args) => await ChooseUploadAsync(true);
    private async void UploadQueue_Click(object sender, RoutedEventArgs args) => await ShowUploadQueueAsync();

    private async Task<IReadOnlyList<SynologyPhotoUploadSource>?> PickUploadSourcesAsync(bool folder, bool flatten)
    {
        if (_uploadPicker is null) return null;
        if (!folder)
        {
            var paths = await _uploadPicker.PickMultipleFilePathsAsync(WindowsTransferPickerService.MediaFileTypeFilters);
            return paths?.Where(WindowsTransferPickerService.IsSupportedMediaPath).Select(path => new SynologyPhotoUploadSource(path, [])).ToArray();
        }
        var directory = await _uploadPicker.PickSingleFolderPathAsync();
        if (directory is null) return null;
        var prepared = await Task.Run(() => BoundedFolderUploadPlan.Create(directory));
        if (prepared is not { Status: FolderUploadPlanStatus.Valid, Plan: { } plan }) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        return plan.Files.Where(file => WindowsTransferPickerService.IsSupportedMediaPath(file.SourcePath) && file.Length > 0 &&
            !file.RelativePath.Split('/').Any(part => part.StartsWith('.')) && (File.GetAttributes(file.SourcePath) & FileAttributes.Hidden) == 0)
            .Select(file => new SynologyPhotoUploadSource(file.SourcePath, flatten ? [] :
                new[] { plan.RootName }.Concat(file.RelativePath.Split('/').SkipLast(1)).ToArray())).ToArray();
    }
    private async Task ChooseUploadAsync(bool folder)
    {
        if (_disposed || _dialog is not null || _uploadPreparing || _uploadPicker is null) return;
        var generation = _viewGeneration; var album = _model.Album;
        var target = new SynologyPhotoUploadTarget(_model.SelectedSpace,
            album is null && _model.Section == Features.Photos.Synology.SynologyPhotosSection.Folders ? _model.FolderHistory.LastOrDefault()?.Id : null,
            album?.Id, album is not null);
        _uploadPreparing = true; Render();
        try
        {
            var sources = await PickUploadSourcesAsync(folder, target.DirectToAlbum);
            if (sources is null || _disposed || generation != _viewGeneration) return;
            if (sources.Count == 0) { UploadMessage("PhotosUploadNoMedia", true); return; }
            var preferences = await _model.Repository.DuplicateSettingsAsync(_viewCancellation.Token);
            if (_disposed || generation != _viewGeneration) return;
            var duplicate = new ComboBox { Header = _l.Get("PhotosUploadDuplicate"), HorizontalAlignment = HorizontalAlignment.Stretch,
                ItemsSource = new[] { _l.Get("PhotosUploadSkip"), _l.Get("PhotosUploadKeepBoth") }, SelectedIndex = (int)preferences.Upload };
            var albums = new List<UploadAlbumChoice> { new(null, _l.Get("PhotosUploadNoAlbum")) };
            var albumPicker = new ComboBox { Header = _l.Get("PhotosUploadAddAlbum"), HorizontalAlignment = HorizontalAlignment.Stretch };
            var content = new StackPanel { Spacing = 14, MinWidth = 280 };
            content.Children.Add(new TextBlock { Text = _l.Format(sources.Count == 1 ? "PhotosUploadSelectionOne" : "PhotosUploadSelection", sources.Count,
                album?.Name ?? (_model.Section == Features.Photos.Synology.SynologyPhotosSection.Folders ? _model.FolderHistory.LastOrDefault()?.Name : null) ??
                    _l.Get(target.Space == SynologyPhotoSpace.Personal ? "PhotosSourcePersonal" : "PhotosSourceShared")), TextWrapping = TextWrapping.Wrap });
            content.Children.Add(duplicate);
            if (!target.DirectToAlbum)
            {
                try
                {
                    var seen = new HashSet<long>();
                    for (var offset = 0; ; offset += 100)
                    {
                        var page = await _model.Repository.AddableAlbumsAsync(offset, 100, _viewCancellation.Token);
                        foreach (var choice in page)
                        { if (!seen.Add(choice.Id)) throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse); albums.Add(new(choice.Id, choice.Name)); }
                        if (page.Count < 100) break;
                    }
                    albumPicker.ItemsSource = albums; albumPicker.SelectedIndex = 0; content.Children.Add(albumPicker);
                }
                catch (Exception) { content.Children.Add(new TextBlock { Text = _l.Get("PhotosUploadAlbumsUnavailable"), TextWrapping = TextWrapping.Wrap }); }
            }
            if (_disposed || generation != _viewGeneration) return;
            var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosUploadFiles"),
                PrimaryButtonText = _l.Get("PhotosUploadStart"), CloseButtonText = _l.Get("PhotosCancel"),
                DefaultButton = ContentDialogButton.Primary, Content = content };
            ContentDialogResult result;
            try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); result = await ShowPhotoDialogAsync(dialog); }
            finally { if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
            if (result != ContentDialogResult.Primary || _disposed || generation != _viewGeneration) return;
            target = target with { Duplicate = duplicate.SelectedIndex == 1 ? SynologyPhotoDuplicatePolicy.KeepBoth : SynologyPhotoDuplicatePolicy.Skip,
                AlbumId = target.DirectToAlbum ? target.AlbumId : (albumPicker.SelectedItem as UploadAlbumChoice)?.Id };
            UploadMessage("PhotosUploadPreparing", false);
            var batch = await _model.Repository.QueueUploadAsync(Guid.NewGuid(), target, sources, _viewCancellation.Token);
            // 队列归属于原 Repository；离开页面只关闭视图，不取消或重建上传。
            _ = RunUploadAsync(batch.Id);
            if (!_disposed) { UploadBar.IsOpen = false; await ShowUploadQueueAsync(); }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { UploadMessage(UploadErrorKey(error), true); }
        finally { _uploadPreparing = false; if (!_disposed) Render(); }
    }
    private async Task RunUploadAsync(Guid id, IReadOnlyList<SynologyPhotoUploadSource>? sources = null)
    {
        try { await _model.Repository.ContinueUploadAsync(id, sources); }
        catch (Exception error) { UploadMessage(UploadErrorKey(error), true); }
    }
    private void UploadMessage(string key, bool error)
    {
        if (_disposed) return;
        UploadBar.Message = _l.Get(key); UploadBar.Severity = error ? InfoBarSeverity.Error : InfoBarSeverity.Informational; UploadBar.IsOpen = true;
    }
    private static string UploadErrorKey(Exception error) => error is SynologyPhotoException photo ? photo.Failure switch
    {
        SynologyPhotoFailure.SessionExpired => "PhotosUploadSignInAgain",
        SynologyPhotoFailure.Permission => "PhotosUploadPermission",
        SynologyPhotoFailure.TargetChanged => "PhotosUploadSourceChanged",
        SynologyPhotoFailure.UploadBusy => "PhotosUploadAlreadyQueued",
        SynologyPhotoFailure.RecoveryUnavailable => "PhotosUploadRecoveryUnavailable",
        _ => "PhotosUploadFailed",
    } : error is DsmException { AuthenticationFailure: true } ? "PhotosUploadSignInAgain" :
        error is DsmException { Code: 105 } ? "PhotosUploadPermission" : "PhotosUploadFailed";
    private sealed record UploadAlbumChoice(long? Id, string Title) { public override string ToString() => Title; }
    private sealed record UploadBatchChoice(SynologyPhotoUploadBatch Batch, string Title) { public override string ToString() => Title; }

    private async Task ShowUploadQueueAsync()
    {
        if (_disposed || _dialog is not null) return;
        var batches = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(batches, _l.Get("PhotosUploadQueue"));
        var rows = new ListView { SelectionMode = ListViewSelectionMode.None, MaxHeight = 320, ItemTemplate = (DataTemplate)Resources["PhotoUploadItemTemplate"] };
        AutomationProperties.SetName(rows, _l.Get("PhotosUploadItems"));
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = _l.Get("PhotosLoadingDescription") };
        var progress = new ProgressRing { IsActive = true, Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var resume = QueueButton("PhotosUploadContinue"); var pause = QueueButton("PhotosUploadPause");
        var files = QueueButton("PhotosUploadReselectFiles"); var folder = QueueButton("PhotosUploadReselectFolder");
        var refresh = QueueButton("PhotosRefresh"); var cancel = QueueButton("PhotosUploadCancelRemaining");
        var buttons = new StackPanel { Spacing = 8 };
        foreach (var pair in new[] { new[] { resume, pause }, new[] { files, folder }, new[] { refresh, cancel } })
        { var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; foreach (var button in pair) row.Children.Add(button); buttons.Children.Add(row); }
        var panel = new StackPanel { MinWidth = 280, MaxWidth = 620, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { batches, progress, message, rows, buttons }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosUploadQueue"), CloseButtonText = _l.Get("PhotosClose"),
            Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 620 } };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) }; var loading = false; var closed = false;
        Guid? selected = null; string? rendered = null;
        var currentValues = new Dictionary<Guid, SynologyPhotoUploadBatch>();
        SynologyPhotoUploadBatch? Current() => batches.SelectedItem is UploadBatchChoice choice ? currentValues.GetValueOrDefault(choice.Batch.Id) : null;
        async Task Load(bool review = false)
        {
            if (loading || closed || _disposed) return; loading = true;
            try
            {
                selected = Current()?.Id ?? selected;
                if (review && selected is { } id) await _model.Repository.ReviewUploadAsync(id);
                var values = await _model.Repository.UploadsAsync();
                if (closed || _disposed) return;
                currentValues = values.ToDictionary(batch => batch.Id);
                var choices = values.Select(batch => new UploadBatchChoice(batch, _l.Format(batch.Items.Count == 1 ? "PhotosUploadBatchTitleOne" : "PhotosUploadBatchTitle", batch.Items[0].File.Name, batch.Items.Count))).ToArray();
                if (batches.ItemsSource is not UploadBatchChoice[] previous || !previous.Select(choice => choice.Batch.Id).SequenceEqual(choices.Select(choice => choice.Batch.Id)))
                {
                    batches.ItemsSource = choices;
                    batches.SelectedIndex = Math.Max(0, Array.FindIndex(choices, choice => choice.Batch.Id == selected));
                }
                Draw();
            }
            catch (Exception error) { if (!closed && !_disposed) message.Text = _l.Get(UploadErrorKey(error)); }
            finally { loading = false; if (!closed && !_disposed) { progress.IsActive = false; progress.Visibility = Visibility.Collapsed; } }
        }
        void Draw()
        {
            var batch = Current();
            message.Text = batch is not null && !batch.NeedsReview && !batch.IsRunning ? "" : _l.Get(batch is null ? "PhotosUploadEmpty" : batch.NeedsReview ? "PhotosUploadInterrupted" :
                batch.StopRequested ? "PhotosUploadStopping" : "PhotosUploadRunning");
            message.Visibility = Visible(message.Text.Length > 0);
            resume.IsEnabled = batch?.CanContinue == true;
            pause.IsEnabled = batch?.IsRunning == true && !batch.StopRequested;
            var missing = batch?.Items.Any(item => !item.SourceAvailable && item.UploadedPhoto is null && item.State is SynologyPhotoUploadState.Queued or SynologyPhotoUploadState.Failed) == true;
            files.Visibility = folder.Visibility = Visible(missing);
            files.IsEnabled = folder.IsEnabled = _uploadPicker is not null && batch?.IsRunning == false && !batch.NeedsReview;
            cancel.IsEnabled = batch?.Items.Any(item => item.State is SynologyPhotoUploadState.Queued or SynologyPhotoUploadState.Uploaded or SynologyPhotoUploadState.Failed) == true;
            var text = batch?.Items.Select(item => _l.Format(item.State == SynologyPhotoUploadState.Uploading ? "PhotosUploadItemLine" : "PhotosUploadItemSummary", item.File.Name,
                _l.Get(item.State == SynologyPhotoUploadState.Failed && item.UploadedPhoto is not null ? "PhotosUploadAlbumFailed" :
                    item.State == SynologyPhotoUploadState.Failed && item.Failure is { } failure ? UploadErrorKey(new SynologyPhotoException(failure)) : "PhotosUploadState" + item.State),
                _l.Format("PhotosUploadBytes", item.BytesSent, item.File.Length))).ToArray() ?? [];
            var key = string.Join('\n', text);
            if (key != rendered) { rendered = key; rows.ItemsSource = text; }
        }
        batches.SelectionChanged += (_, _) => { if (!loading) { selected = Current()?.Id; Draw(); } };
        resume.Click += async (_, _) => { if (Current() is { } batch) { _ = RunUploadAsync(batch.Id); await Load(); } };
        async Task Stop(bool cancelRemaining)
        {
            try { if (Current() is { } batch) { await _model.Repository.StopUploadAsync(batch.Id, cancelRemaining); await Load(); } }
            catch (Exception error) { if (!closed) message.Text = _l.Get(UploadErrorKey(error)); }
        }
        pause.Click += async (_, _) => await Stop(false);
        cancel.Click += async (_, _) => await Stop(true);
        refresh.Click += async (_, _) => await Load(true);
        async Task Reselect(bool isFolder)
        {
            if (Current() is not { } batch) return;
            try
            {
                var sources = await PickUploadSourcesAsync(isFolder, batch.Target.DirectToAlbum);
                if (sources is { Count: > 0 } && !closed && !_disposed) { _ = RunUploadAsync(batch.Id, sources); await Load(); }
            }
            catch (Exception error) { if (!closed) message.Text = _l.Get(UploadErrorKey(error)); }
        }
        files.Click += async (_, _) => await Reselect(false); folder.Click += async (_, _) => await Reselect(true);
        timer.Tick += async (_, _) => await Load();
        foreach (var button in new[] { resume, pause, files, folder, cancel }) button.IsEnabled = false;
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); _ = Load(); timer.Start(); await showing; }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
    }
    private Button QueueButton(string key) => new() { Content = _l.Get(key), MinHeight = 40 };
}
