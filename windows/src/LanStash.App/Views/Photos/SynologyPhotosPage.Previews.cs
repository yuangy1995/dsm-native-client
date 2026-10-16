using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private bool _previewPreparing;
    private readonly HashSet<Guid> _previewRuns = [];
    private static string PreviewGenerationErrorKey(Exception error) => error is SynologyPhotoException photo ? photo.Failure switch
    {
        SynologyPhotoFailure.Unavailable => "PhotosPreviewUnavailable",
        SynologyPhotoFailure.Media or SynologyPhotoFailure.InvalidResponse => "PhotosPreviewFailed",
        _ => ManagementErrorKey(error),
    } : error is DsmException ? ManagementErrorKey(error) : "PhotosPreviewFailed";
    private void RenderPreviewGenerationControls()
    {
        if (!_ready || _disposed) return;
        GeneratePhotoPreviewsMenu.Text = GeneratePhotoPreviewButton.Label = _l.Get("PhotosGeneratePreviews");
        PendingPhotoPreviewsMenu.Text = _l.Get("PhotosPendingPreviews");
        PhotoPreviewHistoryMenu.Text = _l.Get("PhotosPreviewHistory"); PhotoPreviewHistoryButton.Content = _l.Get("PhotosPreviewHistory");
        AutomationProperties.SetName(GeneratePhotoPreviewButton, GeneratePhotoPreviewButton.Label);
        var enabled = _model.Repository.SupportsManagement && _model.Spaces.Any(_model.Repository.SupportsPreviewGeneration);
        GeneratePhotoPreviewsMenu.Visibility = PendingPhotoPreviewsMenu.Visibility = PhotoPreviewHistoryMenu.Visibility = Visible(enabled);
        var ready = !_previewPreparing && !_managementPreparing && !_model.IsLoading && !_model.Slideshow.IsPresented;
        var selection = SelectedManagementPhotos();
        GeneratePhotoPreviewsMenu.IsEnabled = ready && selection.Length is > 0 and <= 100 && selection.Length == LibraryGrid.SelectedItems.Count &&
            selection.All(photo => photo.SupportsPreviewGeneration && _model.Repository.SupportsPreviewGeneration(photo.Id.Space));
        PendingPhotoPreviewsMenu.IsEnabled = ready && enabled;
        GeneratePhotoPreviewButton.Visibility = Visible(_model.CurrentAlbum?.Frozen != true && _model.Album?.IsFrozen != true &&
            _model.Preview.Photo is { SupportsPreviewGeneration: true } photo && _model.Repository.SupportsPreviewGeneration(photo.Id.Space));
        GeneratePhotoPreviewButton.IsEnabled = ready && !_model.Preview.IsLoading && !_imageDecodePending && !_model.Deletion.IsBusy;
    }
    private async void GeneratePhotoPreviews_Click(object sender, RoutedEventArgs args) => await ShowPreviewGenerationAsync(SelectedManagementPhotos());
    private async void GeneratePhotoPreview_Click(object sender, RoutedEventArgs args)
    { if (_model.CurrentAlbum?.Frozen != true && _model.Album?.IsFrozen != true && _model.Preview.Photo is { } photo) await ShowPreviewGenerationAsync([photo]); }
    private async void PendingPhotoPreviews_Click(object sender, RoutedEventArgs args) => await ShowPendingPreviewsAsync();
    private async void PhotoPreviewHistory_Click(object sender, RoutedEventArgs args) => await ShowPreviewHistoryAsync();

    private async Task ShowPreviewGenerationAsync(IReadOnlyList<SynologyPhoto> photos, bool resuming = false)
    {
        if (_disposed || _dialog is not null || _previewPreparing || photos.Count is < 1 or > 100 || _model.Slideshow.IsPresented) return;
        _previewPreparing = true; var generation = _viewGeneration; var closed = false; var confirmed = false;
        var request = new SynologyPhotoPreviewGenerationRequest(photos.ToArray(), resuming);
        var message = new TextBlock { Text = _l.Get("PhotosLoadingDescription"), TextWrapping = TextWrapping.Wrap };
        var spinner = new ProgressRing { IsActive = true, Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 }; panel.Children.Add(spinner); panel.Children.Add(message);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosGeneratePreviews"),
            PrimaryButtonText = _l.Get(resuming ? "PhotosPreviewContinue" : "PhotosGeneratePreviews"), IsPrimaryButtonEnabled = false,
            CloseButtonText = _l.Get("PhotosCancel"), Content = panel };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        dialog.PrimaryButtonClick += (_, _) => confirmed = true; dialog.Closed += (_, _) => closed = true;
        try
        {
            // 先让原生菜单关闭，避免弹出层退场时禁用所属按钮。
            if (MoreButton.Flyout.IsOpen)
            {
                var hidden = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                void Hidden(object? sender, object args) => hidden.TrySetResult();
                MoreButton.Flyout.Closed += Hidden;
                try { MoreButton.Flyout.Hide(); await hidden.Task.WaitAsync(_viewCancellation.Token); }
                finally { MoreButton.Flyout.Closed -= Hidden; }
            }
            if (_disposed || generation != _viewGeneration) return;
            RenderPreviewGenerationControls(); SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog);
            try
            {
                await _model.Repository.PreparePreviewGenerationAsync(request, _viewCancellation.Token);
                if (Current()) { message.Text = _l.Format("PhotosPreviewConfirm", photos.Count); dialog.IsPrimaryButtonEnabled = true; }
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(PreviewGenerationErrorKey(error)); }
            finally { if (Current()) { spinner.IsActive = false; spinner.Visibility = Visibility.Collapsed; } }
            await showing;
        }
        catch (OperationCanceledException) { }
        finally { closed = true; _previewPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderPreviewGenerationControls(); }
        if (!confirmed || _disposed || generation != _viewGeneration) return;
        var id = Guid.NewGuid(); _ = RunPreviewGenerationAsync(id, request);
        await ShowPreviewHistoryAsync(id);
    }
    private async Task RunPreviewGenerationAsync(Guid id, SynologyPhotoPreviewGenerationRequest? request = null)
    {
        if (!_previewRuns.Add(id)) return; var generation = _viewGeneration;
        try
        {
            // 执行归属于原工作区；页面关闭和来源切换不重建或取消已提交的任务。
            var result = request is null ? await _model.Repository.ContinuePreviewGenerationAsync(id) : await _model.Repository.GeneratePreviewsAsync(id, request);
            if (!_disposed && generation == _viewGeneration) await ApplyPreviewGenerationAsync(result);
        }
        catch (Exception error)
        { if (!_disposed && generation == _viewGeneration) { PhotoPreviewGenerationBar.Message = _l.Get(PreviewGenerationErrorKey(error)); PhotoPreviewGenerationBar.Severity = InfoBarSeverity.Error; PhotoPreviewGenerationBar.IsOpen = true; } }
        finally { _previewRuns.Remove(id); }
    }
    private async Task ApplyPreviewGenerationAsync(SynologyPhotoPreviewGeneration value)
    {
        if (await _model.ApplyPreviewGenerationAsync(value) && !_disposed) { CancelThumbnails(); _thumbnails.Clear(); RebuildGroups(); }
    }
    private async Task RefreshPreviewGenerationStatusAsync()
    {
        if (!_model.Repository.SupportsManagement) return;
        var generation = _viewGeneration; var values = await _model.Repository.PreviewGenerationsAsync();
        foreach (var value in values)
        {
            if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return;
            var current = value.Pending && !value.Running ? await _model.Repository.ReviewPreviewGenerationAsync(value.Id) : value;
            if (!_disposed && generation == _viewGeneration) await ApplyPreviewGenerationAsync(current);
        }
        if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return;
        values = await _model.Repository.PreviewGenerationsAsync();
        PhotoPreviewGenerationBar.IsOpen = values.Any(value => value.Pending || value.Running || value.CanContinue);
        PhotoPreviewGenerationBar.Message = _l.Get(values.Any(value => value.Pending || value.Running) ? "PhotosPreviewProcessing" : "PhotosPreviewReady");
        PhotoPreviewGenerationBar.Severity = InfoBarSeverity.Informational;
    }

    private async Task ShowPendingPreviewsAsync()
    {
        if (_disposed || _dialog is not null || _previewPreparing) return;
        var generation = _viewGeneration; var closed = false; var loading = false; var readGeneration = 0;
        var spaces = _model.Spaces.Where(_model.Repository.SupportsPreviewGeneration).ToArray(); if (spaces.Length == 0) return;
        var picker = new ComboBox { ItemsSource = spaces.Select(space => _l.Get(space == SynologyPhotoSpace.Personal ? "PhotosSourcePersonal" : "PhotosSourceShared")).ToArray(), SelectedIndex = Math.Max(0, Array.IndexOf(spaces, _model.SelectedSpace)), HorizontalAlignment = HorizontalAlignment.Stretch, Visibility = Visible(spaces.Length > 1) };
        AutomationProperties.SetName(picker, _l.Get("PhotosChooseSource"));
        var list = new ListView { SelectionMode = ListViewSelectionMode.Multiple, DisplayMemberPath = nameof(SynologyPhoto.Filename), MaxHeight = 320 };
        AutomationProperties.SetName(list, _l.Get("PhotosPendingPreviews"));
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; var refresh = QueueButton("PhotosRefresh");
        var spinner = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { picker, spinner, message, list, refresh }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosPendingPreviews"),
            PrimaryButtonText = _l.Get("PhotosPreviewContinue"), IsPrimaryButtonEnabled = false, CloseButtonText = _l.Get("PhotosClose"), Content = new ScrollViewer { Content = panel, MaxHeight = 540 } };
        SynologyPhoto[] selected = [];
        bool Current(int read) => !closed && !_disposed && generation == _viewGeneration && read == readGeneration;
        void Render()
        { dialog.IsPrimaryButtonEnabled = !loading && list.SelectedItems.Count is > 0 and <= 100; spinner.IsActive = loading; spinner.Visibility = Visible(loading); refresh.IsEnabled = !loading; list.IsEnabled = !loading; }
        async Task Load()
        {
            var read = ++readGeneration; var space = spaces[picker.SelectedIndex]; loading = true; list.ItemsSource = null; message.Text = _l.Get("PhotosLoadingDescription"); Render();
            try { var values = await _model.Repository.PendingPreviewGenerationsAsync(space, _viewCancellation.Token); if (!Current(read)) return; list.ItemsSource = values; message.Text = _l.Get(values.Count == 0 ? "PhotosPreviewQueueEmpty" : "PhotosPreviewChoose"); }
            catch (Exception error) { if (Current(read)) message.Text = _l.Get(PreviewGenerationErrorKey(error)); }
            finally { if (Current(read)) { loading = false; Render(); } }
        }
        picker.SelectionChanged += async (_, _) => { if (picker.SelectedIndex >= 0) await Load(); };
        list.SelectionChanged += (_, _) => Render(); refresh.Click += async (_, _) => await Load();
        dialog.PrimaryButtonClick += (_, _) => selected = list.SelectedItems.Cast<SynologyPhoto>().ToArray(); dialog.Closed += (_, _) => closed = true;
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); await Load(); await showing; }
        finally { closed = true; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
        if (!_disposed && generation == _viewGeneration && selected.Length > 0) await ShowPreviewGenerationAsync(selected, resuming: true);
    }

    private async Task ShowPreviewHistoryAsync(Guid? selected = null)
    {
        if (_disposed || _dialog is not null) return;
        var generation = _viewGeneration; var closed = false; var loading = false; var stopping = false;
        var values = new Dictionary<Guid, SynologyPhotoPreviewGeneration>(); SynologyPhoto[] retry = [];
        var picker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch }; AutomationProperties.SetName(picker, _l.Get("PhotosPreviewHistory"));
        var rows = new StackPanel { Spacing = 10 }; var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var resume = QueueButton("PhotosPreviewContinue"); var refresh = QueueButton("PhotosRefresh"); var cancel = QueueButton("PhotosCancelRemainingChanges"); var restart = QueueButton("PhotosPreviewRetry");
        var spinner = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { picker, spinner, message, rows, resume, refresh, cancel, restart }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosPreviewHistory"), CloseButtonText = _l.Get("PhotosClose"), Content = new ScrollViewer { Content = panel, MaxHeight = 550 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        SynologyPhotoPreviewGeneration? Selected() => picker.SelectedItem is PhotoChangeChoice choice ? values.GetValueOrDefault(choice.Id) : null;
        void Render()
        {
            if (!Current()) return; var value = Selected(); rows.Children.Clear();
            if (value is not null) foreach (var item in value.Items)
            {
                var row = new StackPanel { Spacing = 4 }; row.Children.Add(new TextBlock { Text = item.Original.Filename, TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                if (value.Items.Select(entry => entry.Original.Id.Space).Distinct().Count() > 1)
                    row.Children.Add(new TextBlock { Text = _l.Get(item.Original.Id.Space == SynologyPhotoSpace.Personal ? "PhotosSourcePersonal" : "PhotosSourceShared") });
                row.Children.Add(new TextBlock { TextWrapping = TextWrapping.Wrap, Text = item.State switch
                { SynologyPhotoChangeState.Completed => _l.Get("PhotosPreviewCompleted"), SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview => _l.Get("PhotosPreviewProcessing"),
                    SynologyPhotoChangeState.Ready => _l.Get("PhotosPreviewReady"), SynologyPhotoChangeState.Cancelled => _l.Get("PhotosChangeCancelled"),
                    _ => item.Failure is { } failure ? _l.Get(PreviewGenerationErrorKey(new SynologyPhotoException(failure))) : _l.Get("PhotosPreviewFailed") } }); rows.Children.Add(row);
            }
            message.Text = value is null ? _l.Get(selected is { } id && _previewRuns.Contains(id) ? "PhotosPreviewProcessing" : "PhotosPreviewHistoryEmpty") : value.Pending && !value.Running ? _l.Get("PhotosPreviewPending") : "";
            message.Visibility = Visible(message.Text.Length > 0); spinner.IsActive = loading || value?.Running == true; spinner.Visibility = Visible(spinner.IsActive);
            refresh.IsEnabled = !loading; picker.IsEnabled = !loading && !stopping;
            resume.IsEnabled = !loading && value?.CanContinue == true && !_previewRuns.Contains(value.Id);
            cancel.IsEnabled = !stopping && value is not null && (value.Running || value.Items.Any(item => item.State == SynologyPhotoChangeState.Ready));
            restart.Visibility = Visible(value is { Running: false, Pending: false } && value.Items.Any(item => item.State == SynologyPhotoChangeState.Failed)); restart.IsEnabled = !loading;
        }
        async Task Load(bool review = false)
        {
            if (!Current() || loading) return; loading = true; var id = Selected()?.Id ?? selected; Render(); string? error = null;
            try
            {
                var all = await _model.Repository.PreviewGenerationsAsync();
                if (review) foreach (var value in all.Where(value => value.Pending && !value.Running)) { if (!Current()) return; await _model.Repository.ReviewPreviewGenerationAsync(value.Id); }
                all = await _model.Repository.PreviewGenerationsAsync(); if (!Current()) return;
                foreach (var value in all) { if (!Current()) return; await ApplyPreviewGenerationAsync(value); }
                if (!Current()) return; values = all.ToDictionary(value => value.Id);
                var choices = all.Select((value, index) => new PhotoChangeChoice(value.Id, _l.Format("PhotosChangeChoice", index + 1, _l.Get("PhotosGeneratePreviews")))).ToArray();
                if (picker.ItemsSource is not PhotoChangeChoice[] prior || !prior.SequenceEqual(choices))
                { picker.ItemsSource = choices; picker.SelectedIndex = choices.Length == 0 ? -1 : Math.Max(0, Array.FindIndex(choices, value => value.Id == id)); }
            }
            catch (Exception failure) { error = _l.Get(PreviewGenerationErrorKey(failure)); }
            finally { loading = false; Render(); if (Current() && error is not null) { message.Text = error; message.Visibility = Visibility.Visible; } }
        }
        picker.SelectionChanged += (_, _) => { selected = Selected()?.Id; Render(); }; refresh.Click += async (_, _) => await Load(review: true);
        resume.Click += async (_, _) => { if (Selected() is { CanContinue: true } value) { _ = RunPreviewGenerationAsync(value.Id); await Load(); } };
        cancel.Click += async (_, _) =>
        {
            if (stopping || Selected() is not { } value) return; stopping = true; Render(); string? failure = null;
            try { await _model.Repository.CancelPreviewGenerationAsync(value.Id); await Load(); }
            catch (Exception error) { failure = _l.Get(PreviewGenerationErrorKey(error)); }
            finally { stopping = false; Render(); if (Current() && failure is not null) { message.Text = failure; message.Visibility = Visibility.Visible; } }
        };
        restart.Click += (_, _) => { if (Selected() is { Running: false, Pending: false } value) { retry = value.Items.Where(item => item.State == SynologyPhotoChangeState.Failed).Select(item => item.Original).ToArray(); dialog.Hide(); } };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) }; var nextReview = DateTimeOffset.UtcNow.AddSeconds(15);
        timer.Tick += async (_, _) => { var review = DateTimeOffset.UtcNow >= nextReview; if (review) nextReview = DateTimeOffset.UtcNow.AddSeconds(15); await Load(review); };
        dialog.Closed += (_, _) => { closed = true; timer.Stop(); };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(review: true); await showing; }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
        if (retry.Length > 0 && !_disposed && generation == _viewGeneration) await ShowPreviewGenerationAsync(retry);
    }
}
