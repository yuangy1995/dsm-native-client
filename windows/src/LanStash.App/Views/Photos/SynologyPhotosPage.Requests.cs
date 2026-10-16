using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private string? SelectedRequestId() => _model.IsRequestList && LibraryGrid.SelectedItems.Count == 1 &&
        LibraryGrid.SelectedItems[0] is SynologyPhotoCell { Shared.AlbumId: null, Shared: { } request } ? request.Id : null;
    private string RequestTitle(SynologyPhotoRequestEditKind kind) => _l.Get(kind switch
    { SynologyPhotoRequestEditKind.Create => "PhotosRequestCreate", SynologyPhotoRequestEditKind.Update => "PhotosRequestEdit", _ => "PhotosRequestDelete" });
    private void RenderRequestControls()
    {
        var visible = _model.Repository.SupportsRequestManagement;
        CreatePhotoRequestMenu.Visibility = EditPhotoRequestMenu.Visibility = DeletePhotoRequestMenu.Visibility = PhotoRequestChangesMenu.Visibility = Visible(visible);
        CreatePhotoRequestMenu.Text = RequestTitle(SynologyPhotoRequestEditKind.Create); EditPhotoRequestMenu.Text = RequestTitle(SynologyPhotoRequestEditKind.Update);
        DeletePhotoRequestMenu.Text = RequestTitle(SynologyPhotoRequestEditKind.Delete); PhotoRequestChangesMenu.Text = _l.Get("PhotosRequestChanges");
        PhotoRequestHistoryButton.Content = _l.Get("PhotosRequestChanges");
        var ready = !_managementPreparing && !_model.IsLoading && _model.HasLoaded && _model.Spaces.Count > 0;
        CreatePhotoRequestMenu.IsEnabled = ready; EditPhotoRequestMenu.IsEnabled = DeletePhotoRequestMenu.IsEnabled = ready && SelectedRequestId() is not null;
    }
    private async void CreatePhotoRequest_Click(object sender, RoutedEventArgs args)
    {
        var folder = _model.Section == SynologyPhotosSection.Folders ? SelectedPhotoFolder() : null;
        await ShowPhotoRequestAsync(SynologyPhotoRequestEditKind.Create, initialFolder: folder, initialAlbum: SelectedAlbumId());
    }
    private async void EditPhotoRequest_Click(object sender, RoutedEventArgs args)
    { if (SelectedRequestId() is { } id) await ShowPhotoRequestAsync(SynologyPhotoRequestEditKind.Update, id); }
    private async void DeletePhotoRequest_Click(object sender, RoutedEventArgs args)
    { if (SelectedRequestId() is { } id) await ShowPhotoRequestAsync(SynologyPhotoRequestEditKind.Delete, id); }
    private async void PhotoRequestChanges_Click(object sender, RoutedEventArgs args) => await ShowRequestChangesAsync();
    private async Task ShowPhotoRequestAsync(SynologyPhotoRequestEditKind kind, string? requestId = null,
        SynologyPhotoCollection? initialFolder = null, long? initialAlbum = null)
    {
        if (_disposed || _dialog is not null || _managementPreparing || !_model.Repository.SupportsRequestManagement) return;
        _managementPreparing = true; RenderManagementControls(); var generation = _viewGeneration;
        var closed = false; var busy = false; var submitting = false; var albumHistory = false;
        SynologyPhotoRequest? original = null; SynologyPhotoRequestChange? submitted = null; SynologyPhotoRequestEditor? editor = null;
        var body = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var target = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var risk = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = _l.Get(kind == SynologyPhotoRequestEditKind.Delete ? "PhotosRequestDeleteRisk" : "PhotosRequestUploadRisk") };
        var restriction = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = _l.Get("PhotosRequestRestricted") };
        var retry = QueueButton("PhotosRetry"); var copy = QueueButton("PhotosShareCopyLink");
        var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { target, copy, progress, message, retry, body, risk, restriction }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = RequestTitle(kind),
            PrimaryButtonText = _l.Get(kind == SynologyPhotoRequestEditKind.Create ? "PhotosRequestCreate" : kind == SynologyPhotoRequestEditKind.Delete ? "PhotosRequestDelete" : "PhotosSaveChanges"),
            CloseButtonText = _l.Get("PhotosCancel"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false,
            Content = new ScrollViewer { Content = panel, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        void Render()
        {
            if (!Current()) return; var ready = kind == SynologyPhotoRequestEditKind.Delete ? original is not null : false;
            if (editor is not null) try { _ = editor.Input(); ready = true; } catch (ArgumentException) { }
            dialog.IsPrimaryButtonEnabled = !busy && ready && _model.Repository.SharingSafety.Requests;
            body.IsEnabled = !busy; progress.IsActive = busy; progress.Visibility = Visible(busy);
            copy.Visibility = Visible(original?.Url is not null); copy.IsEnabled = !busy;
            retry.Visibility = Visible(!busy && (kind == SynologyPhotoRequestEditKind.Delete ? original is null : editor is null));
            target.Text = original?.Settings.Subject ?? ""; target.Visibility = Visible(target.Text.Length > 0);
            message.Visibility = Visible(message.Text.Length > 0); restriction.Visibility = Visible(!_model.Repository.SharingSafety.Requests);
            risk.Visibility = Visible(editor is not null || original is not null);
        }
        async Task Load()
        {
            if (!Current() || busy) return; busy = true; message.Text = _l.Get("PhotosLoadingDescription"); Render();
            try
            {
                SynologyPhotoRequestSettings initial;
                if (requestId is not null) { original = await _model.Repository.PhotoRequestAsync(requestId, _viewCancellation.Token); initial = original.Settings; }
                else
                {
                    if (_model.Spaces.Count == 0) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
                    var subject = _l.Format("PhotosRequestDefaultSubject", DateTimeOffset.Now);
                    var space = initialFolder?.Space ?? (_model.Spaces.Contains(SynologyPhotoSpace.Personal) ? SynologyPhotoSpace.Personal : SynologyPhotoSpace.Shared);
                    initial = new(subject, "", space, initialFolder?.Path ?? "") { FolderId = initialFolder?.Path is null ? null : initialFolder.Id };
                    if (initialAlbum is { } albumId)
                    {
                        var album = await _model.Repository.AlbumAsync(albumId, _viewCancellation.Token);
                        if (album is { Conditional: false, Frozen: false, IsOwner: true }) initial = initial with { AlbumId = albumId };
                    }
                }
                if (!Current()) return;
                if (kind != SynologyPhotoRequestEditKind.Delete)
                {
                    editor?.Dispose(); editor = new(_model.Repository, initial, kind == SynologyPhotoRequestEditKind.Create, _model.Spaces, _model.CanManageSharedSpace, original?.AlbumName);
                    editor.Changed += Render; editor.AlbumHistoryRequested += () => { if (!Current() || editor.CreatingAlbum) return; albumHistory = true; dialog.Hide(); };
                    body.Content = editor;
                }
                message.Text = "";
            }
            catch (Exception error) { if (Current()) message.Text = SharingError(error); }
            finally { busy = false; Render(); }
            if (Current() && editor is not null) await editor.LoadAlbumsAsync();
        }
        retry.Click += async (_, _) => await Load(); copy.Click += (_, _) => { if (original?.Url is { } url) { CopyPhotoSharingLink(url, message); Render(); } };
        dialog.Closing += (_, args) => { if ((submitting || editor?.CreatingAlbum == true) && Current() && _windowVisible && IsLoaded) args.Cancel = true; };
        dialog.Closed += (_, _) => closed = true;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (!Current() || busy || !dialog.IsPrimaryButtonEnabled) return; var deferral = args.GetDeferral(); busy = submitting = true; Render();
            try
            {
                submitted = await _model.Repository.EditPhotoRequestAsync(Guid.NewGuid(), new(kind, kind == SynologyPhotoRequestEditKind.Delete ? null : editor!.Input(), original));
                if (Current()) args.Cancel = false;
            }
            catch (Exception error) { if (Current()) message.Text = error is ArgumentException ? _l.Get("PhotosRequestInvalid") : SharingError(error); }
            finally { busy = submitting = false; Render(); deferral.Complete(); }
        };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); Render(); var showing = ShowPhotoDialogAsync(dialog); await Load(); await showing; }
        finally { closed = true; editor?.Dispose(); _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); }
        if (_disposed || generation != _viewGeneration || !_windowVisible) return;
        if (albumHistory) await ShowAlbumChangesAsync();
        else if (submitted is not null) await ShowRequestChangesAsync(submitted.Id);
    }
    private string RequestStateText(SynologyPhotoRequestChange value) => value.Pending ? _l.Get("PhotosRequestProcessing") : value.State switch
    {
        SynologyPhotoChangeState.Completed => _l.Get(value.Kind == SynologyPhotoRequestEditKind.Delete ? "PhotosRequestDeleted" : "PhotosRequestSaved"),
        SynologyPhotoChangeState.Cancelled => _l.Get("PhotosShareStopped"), _ when value.NeedsInput => _l.Get("PhotosRequestStartAgain"),
        _ when value.Failure is { } failure => SharingError(new SynologyPhotoException(failure)), _ => _l.Get("PhotosShareReady"),
    };
    private async Task RefreshRequestStatusAsync()
    {
        if (!_model.Repository.SupportsRequestManagement) return; var generation = _viewGeneration;
        var values = await _model.Repository.PhotoRequestChangesAsync();
        foreach (var value in values.Where(value => value.Pending && !value.Running))
        {
            if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return;
            await _model.Repository.ReviewPhotoRequestAsync(value.Id);
        }
        if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return;
        values = await _model.Repository.PhotoRequestChangesAsync(); PhotoRequestBar.IsOpen = values.Any(value => value.Pending || value.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed);
        PhotoRequestBar.Message = _l.Get(values.Any(value => value.Pending) ? "PhotosRequestProcessing" : "PhotosRequestUnfinished");
        await _model.ApplyRequestChangesAsync(values);
    }
    private async Task ShowRequestChangesAsync(Guid? selected = null)
    {
        if (_disposed || _dialog is not null || !_model.Repository.SupportsRequestManagement) return;
        var generation = _viewGeneration; var closed = false; var busy = false; SynologyPhotoRequestChange? restart = null;
        var values = new Dictionary<Guid, SynologyPhotoRequestChange>();
        var picker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch }; AutomationProperties.SetName(picker, _l.Get("PhotosRequestChanges"));
        var target = new TextBlock { TextWrapping = TextWrapping.Wrap }; var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var refresh = QueueButton("PhotosRefresh"); var resume = QueueButton("PhotosShareContinue"); var cancel = QueueButton("PhotosShareStop");
        var edit = QueueButton("PhotosShareEditAgain"); var copy = QueueButton("PhotosShareCopyLink");
        var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { picker, target, progress, message, copy, refresh, resume, edit, cancel }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosRequestChanges"), CloseButtonText = _l.Get("PhotosClose"),
            Content = new ScrollViewer { Content = panel, MaxHeight = 550 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        SynologyPhotoRequestChange? Selected() => picker.SelectedItem is PhotoAlbumChangeChoice choice ? values.GetValueOrDefault(choice.Id) : null;
        void Render()
        {
            if (!Current()) return; var value = Selected(); target.Text = value?.Result?.Settings.Subject ?? ""; target.Visibility = Visible(target.Text.Length > 0);
            message.Text = value is null ? _l.Get("PhotosRequestChangesEmpty") : RequestStateText(value);
            picker.IsEnabled = refresh.IsEnabled = !busy;
            resume.IsEnabled = !busy && value?.CanContinue == true && (value.Kind != SynologyPhotoRequestEditKind.Delete || value.Result is not null);
            cancel.IsEnabled = !busy && value is { Running: false, State: SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed };
            edit.Visibility = Visible(value?.NeedsInput == true); edit.IsEnabled = cancel.IsEnabled && (value?.Kind == SynologyPhotoRequestEditKind.Create || value?.Result is not null);
            copy.Visibility = Visible(value is { State: SynologyPhotoChangeState.Completed, Result.Url: not null }); copy.IsEnabled = !busy;
            progress.IsActive = busy; progress.Visibility = Visible(busy);
        }
        async Task Load(bool proceed = false, bool stop = false)
        {
            if (!Current() || busy) return; var prior = Selected(); busy = true; Render(); string? error = null;
            try
            {
                if (prior is not null && proceed) await _model.Repository.ContinuePhotoRequestAsync(prior.Id);
                if (prior is not null && stop) await _model.Repository.CancelPhotoRequestAsync(prior.Id);
                var changes = await _model.Repository.PhotoRequestChangesAsync();
                foreach (var change in changes.Where(change => !change.Running))
                { if (!Current()) return; await _model.Repository.ReviewPhotoRequestAsync(change.Id); }
                changes = await _model.Repository.PhotoRequestChangesAsync(); if (!Current()) return;
                values = changes.ToDictionary(change => change.Id); var id = prior?.Id ?? selected;
                var entries = changes.Select((change, index) => new PhotoAlbumChangeChoice(change.Id, _l.Format("PhotosChangeChoice", index + 1, RequestTitle(change.Kind)))).ToArray();
                picker.ItemsSource = entries; picker.SelectedIndex = entries.Length == 0 ? -1 : Math.Max(0, Array.FindIndex(entries, item => item.Id == id));
            }
            catch (Exception failure) { error = SharingError(failure); }
            finally { busy = false; Render(); if (Current() && error is not null) message.Text = error; }
        }
        picker.SelectionChanged += (_, _) => Render(); refresh.Click += async (_, _) => await Load(); resume.Click += async (_, _) => await Load(proceed: true);
        cancel.Click += async (_, _) => await Load(stop: true);
        edit.Click += async (_, _) => { var value = Selected(); if (value is null || busy) return; await Load(stop: true); if (Current() && Selected()?.State == SynologyPhotoChangeState.Cancelled) { restart = value; dialog.Hide(); } };
        copy.Click += (_, _) => { if (Selected()?.Result?.Url is { } url) CopyPhotoSharingLink(url, message); };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) }; timer.Tick += async (_, _) => { if (values.Values.Any(value => value.Pending)) await Load(); };
        dialog.Closed += (_, _) => { closed = true; timer.Stop(); };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(); await showing; }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
        if (_disposed || !_windowVisible || generation != _viewGeneration) return;
        if (restart is not null) await ShowPhotoRequestAsync(restart.Kind, restart.Result?.Id);
        else await _model.ApplyRequestChangesAsync(values.Values.ToArray());
    }
}
