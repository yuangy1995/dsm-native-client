using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private DispatcherTimer? _similarTimer;
    private bool _similarStatusBusy;
    private (SynologyPhotoSpace Space, long Generation)? _similarStatusScope;
    private void RenderSimilarControls()
    {
        if (!_ready || _disposed) return;
        var visible = _windowVisible && IsLoaded && _model.Category == SynologyPhotoCategory.Similar;
        if (visible)
        {
            if (_similarTimer is null) { _similarTimer = new() { Interval = TimeSpan.FromSeconds(15) }; _similarTimer.Tick += async (_, _) => await RefreshSimilarStatusAsync(); }
            _similarTimer.Start();
            var scope = (_model.SelectedSpace, _viewGeneration);
            if (_similarStatusScope != scope) { _similarStatusScope = scope; SimilarStatusBar.IsOpen = false; _ = RefreshSimilarStatusAsync(); }
        }
        else { _similarTimer?.Stop(); _similarStatusScope = null; SimilarStatusBar.IsOpen = false; }
        SimilarPhotoButton.Label = _l.Get("PhotosCategorySimilar");
        SimilarPhotoButton.Visibility = Visible(_model.Preview.Photo is { SimilarGroup: not null, AlbumContext: null });
        SimilarPhotoButton.IsEnabled = !_managementPreparing && !_model.Preview.IsLoadingSimilar;
        SimilarGroupsMenu.Text = _l.Get("PhotosSimilarUngroup");
        SimilarGroupsMenu.Visibility = Visible(_model.Category == SynologyPhotoCategory.Similar && _model.Repository.SupportsSimilarManagement(_model.SelectedSpace));
        var selected = SelectedManagementPhotos();
        SimilarGroupsMenu.IsEnabled = !_managementPreparing && !_model.IsLoading && selected.Length is > 0 and <= 100 &&
            selected.Length == LibraryGrid.SelectedItems.Count && selected.All(photo => photo.SimilarGroup is not null && photo.AlbumContext is null);
    }
    private async Task RefreshSimilarStatusAsync()
    {
        if (_similarStatusBusy || _disposed || !_windowVisible || !IsLoaded || _model.Category != SynologyPhotoCategory.Similar) return;
        _similarStatusBusy = true; var generation = _viewGeneration; var space = _model.SelectedSpace;
        try
        {
            var status = await _model.Repository.SimilarStatusAsync(space, _viewCancellation.Token);
            if (_disposed || !_windowVisible || !IsLoaded || generation != _viewGeneration || _model.Category != SynologyPhotoCategory.Similar || space != _model.SelectedSpace) return;
            SimilarStatusBar.Message = status.Running ? _l.Format("PhotosSimilarProcessing", status.WaitingCount) : _l.Get("PhotosSimilarWaiting"); SimilarStatusBar.IsOpen = status.HasWork;
        }
        catch (Exception)
        {
            if (!_disposed && _windowVisible && IsLoaded && generation == _viewGeneration && _model.Category == SynologyPhotoCategory.Similar)
            { SimilarStatusBar.Message = _l.Get("PhotosSimilarStatusFailed"); SimilarStatusBar.IsOpen = true; }
        }
        finally { _similarStatusBusy = false; }
    }
    private async void SimilarPhoto_Click(object sender, RoutedEventArgs args)
    { if (_model.Preview.Photo?.SimilarGroup is { } group) await ShowSimilarAsync([group.Id], group.Space); }
    private async void SimilarGroups_Click(object sender, RoutedEventArgs args)
    {
        var photos = SelectedManagementPhotos(); if (photos.Length == 0 || photos.Any(photo => photo.SimilarGroup is null || photo.Id.Space != _model.SelectedSpace)) return;
        await ShowSimilarAsync(photos.Select(photo => photo.SimilarGroup!.Id).Distinct().ToArray(), _model.SelectedSpace, batch: true);
    }
    private async Task ShowSimilarAsync(IReadOnlyList<long> ids, SynologyPhotoSpace space, bool batch = false)
    {
        if (_disposed || _dialog is not null || _managementPreparing || ids.Count is 0 or > 100) return;
        _managementPreparing = true; RenderManagementControls(); var generation = _viewGeneration; var closed = false; var busy = false; var continueAction = false;
        using var images = CancellationTokenSource.CreateLinkedTokenSource(_viewCancellation.Token);
        var dialogToken = images.Token;
        SynologyPhotoSimilarEditor? editor = null; SynologyPhotoRecognitionEdit? edit = null; SynologyPhoto? openPhoto = null; SynologyPhotoSimilarDetail? cleanup = null; long[] keep = [];
        var body = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; var restriction = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var retry = QueueButton("PhotosRetry"); var open = QueueButton("PhotosSimilarOpen"); var spinner = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        foreach (var control in new FrameworkElement[] { spinner, message, retry, body, open, restriction }) panel.Children.Add(control);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get(batch ? "PhotosSimilarUngroup" : "PhotosCategorySimilar"),
            PrimaryButtonText = _l.Get("PhotosShareContinue"), CloseButtonText = _l.Get("PhotosClose"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false,
            Content = new ScrollViewer { Content = panel, MaxHeight = 560 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        bool Allowed() => editor?.Action == PhotoSimilarAction.Cleanup ? _model.Repository.CanDeleteOriginals && _model.Repository.FileSafety.ExtendedDeletion : _model.Repository.RecognitionSafety.SimilarGroups;
        void Render()
        {
            if (!Current()) return; body.IsEnabled = !busy; spinner.IsActive = busy; spinner.Visibility = Visible(busy); retry.Visibility = Visible(editor is null && !busy);
            message.Visibility = Visible(message.Text.Length > 0); open.Visibility = Visible(editor is not null); open.IsEnabled = !busy && editor?.OpenPhoto is not null;
            restriction.Text = editor is null || Allowed() ? "" : _l.Get(editor.Action == PhotoSimilarAction.Cleanup ? "PhotosDeleteUnverified" : "PhotosSimilarRestricted");
            restriction.Visibility = Visible(restriction.Text.Length > 0); dialog.IsPrimaryButtonEnabled = !busy && Allowed() && editor is not null && (editor.Input() is not null || editor.CanCleanup);
        }
        async Task Load()
        {
            if (!Current() || busy) return; busy = true; message.Text = _l.Get("PhotosLoadingDescription"); Render();
            try
            {
                var details = new List<SynologyPhotoSimilarDetail>();
                foreach (var id in ids) { var value = await _model.Repository.SimilarGroupAsync(id, space, dialogToken); if (!Current()) return; if (value is null) { message.Text = _l.Get("PhotosSimilarDissolved"); return; } details.Add(value); }
                editor = new(details, batch); editor.AttachThumbnails((DataTemplate)Resources["SimilarPhotoTemplate"], _model.Repository, images.Token);
                editor.Changed += Render; body.Content = editor; message.Text = "";
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(ManagementErrorKey(error)); }
            finally { busy = false; Render(); }
        }
        retry.Click += async (_, _) => await Load(); open.Click += (_, _) => { if (!busy && editor?.OpenPhoto is { } photo) { openPhoto = photo; dialog.Hide(); } };
        dialog.Closed += (_, _) => closed = true;
        dialog.Closing += (_, args) => { if (busy && editor is not null && Current() && _windowVisible && IsLoaded) args.Cancel = true; };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (!Current() || busy || editor is null || !Allowed()) return; var deferral = args.GetDeferral(); busy = true; Render();
            try
            {
                if (editor.CanCleanup)
                {
                    cleanup = editor.Groups.Single(); keep = editor.Selected; await _model.Repository.SimilarCleanupAsync(cleanup, keep, _viewCancellation.Token);
                }
                else if (editor.Input() is { } value) { await _model.Repository.PrepareRecognitionAsync(value, _viewCancellation.Token); edit = value; }
                if (Current()) { continueAction = true; args.Cancel = false; }
            }
            catch (Exception error) { cleanup = null; edit = null; if (Current()) message.Text = _l.Get(ManagementErrorKey(error)); }
            finally { busy = false; Render(); deferral.Complete(); }
        };
        // 关闭不等待读取返回；Load 自行捕获错误并通过 Current 丢弃迟到结果。
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); Render(); var showing = ShowPhotoDialogAsync(dialog); _ = Load(); await showing; }
        finally { closed = true; images.Cancel(); _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); }
        if (_disposed || !_windowVisible || generation != _viewGeneration) return;
        if (openPhoto is not null) { await _model.Preview.OpenAsync(openPhoto); return; }
        if (!continueAction) return;
        if (cleanup is not null)
        {
            var photos = cleanup.Photos.Where(photo => !keep.Contains(photo.Id.ItemId)).ToArray();
            await ShowFileCommandAsync(new(SynologyPhotoFileAction.Delete, space, photos, []), beforeSubmit: async () => { await _model.Repository.SimilarCleanupAsync(cleanup, keep, _viewCancellation.Token); }); return;
        }
        if (edit is not null) await SubmitSimilarConfirmationAsync(edit);
    }
    private async Task SubmitSimilarConfirmationAsync(SynologyPhotoRecognitionEdit edit)
    {
        var generation = _viewGeneration; var result = await ConfirmRecognitionAsync(edit);
        if (result is null || _disposed || generation != _viewGeneration) return;
        await _model.ApplyRecognitionChangeAsync(result); if (!_disposed && _windowVisible && generation == _viewGeneration) await ShowRecognitionChangesAsync(result.Id);
    }
}
