using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private void RenderSharingControls()
    {
        RenderTemporaryControls();
        RenderRequestControls();
        RenderFolderSharingControls();
        var supported = _model.Repository.SupportsSharingManagement;
        PhotoSharingMenu.Visibility = PhotoSharingChangesMenu.Visibility = Visible(supported);
        PhotoSharingMenu.Text = _l.Get("PhotosShareAlbum"); PhotoSharingChangesMenu.Text = _l.Get("PhotosShareChanges");
        PhotoSharingHistoryButton.Content = _l.Get("PhotosShareChanges");
        PhotoSharingMenu.IsEnabled = !_managementPreparing && !_model.IsLoading && _model.HasLoaded && SelectedAlbumId() is not null;
    }
    private async void PhotoSharing_Click(object sender, RoutedEventArgs args)
    { if (SelectedAlbumId() is { } id) await ShowAlbumSharingAsync(id); }
    private async void PhotoSharingChanges_Click(object sender, RoutedEventArgs args) => await ShowSharingChangesAsync();
    private string SharingError(Exception error) => _l.Get(ManagementErrorKey(error));
    private async Task ShowAlbumSharingAsync(long albumId, Guid? temporaryCreation = null)
    {
        if (_disposed || _dialog is not null || _managementPreparing || !_model.Repository.SupportsSharingManagement) return;
        _managementPreparing = true; RenderManagementControls();
        var generation = _viewGeneration; var closed = false; var busy = false; var submitting = false; var candidateBusy = false;
        var stopTemporary = false;
        SynologyPhotoSharing? original = null; SynologyPhotoSharingChange? submitted = null; SynologyPhotoSharingEditor? editor = null;
        var target = new TextBlock { TextWrapping = TextWrapping.Wrap }; var body = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; var membersMessage = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var risk = new TextBlock { TextWrapping = TextWrapping.Wrap }; var restriction = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var retry = QueueButton("PhotosRetry"); var membersRetry = QueueButton("PhotosShareReloadMembers"); var copy = QueueButton("PhotosShareCopyLink");
        var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 10 };
        foreach (var child in new FrameworkElement[] { target, copy, progress, message, retry, body, membersMessage, membersRetry, risk, restriction }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosShareAlbum"),
            PrimaryButtonText = _l.Get("PhotosShareSave"), CloseButtonText = _l.Get("PhotosCancel"), DefaultButton = ContentDialogButton.Close,
            IsPrimaryButtonEnabled = false, Content = new ScrollViewer { Content = panel, MaxHeight = 560 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        void Render()
        {
            if (!Current()) return;
            SynologyPhotoSharingEdit? input = null; try { input = editor?.Input(); } catch (ArgumentException) { }
            var limited = input?.ExpandsAccess == true && !_model.Repository.SharingSafety.Publish;
            dialog.IsPrimaryButtonEnabled = input is not null && !busy && !limited;
            body.IsEnabled = !busy;
            retry.Visibility = Visible(editor is null && !busy); retry.IsEnabled = !busy;
            copy.Visibility = Visible(original?.Url is not null); copy.IsEnabled = !busy;
            membersRetry.Visibility = Visible(original?.Members is not null); membersRetry.IsEnabled = !busy && !candidateBusy;
            progress.IsActive = busy || candidateBusy; progress.Visibility = Visible(progress.IsActive);
            risk.Text = input is null ? "" : input.Access switch
            {
                SynologyPhotoLinkAccess.View => _l.Get("PhotosShareViewRisk"), SynologyPhotoLinkAccess.Download => _l.Get("PhotosShareDownloadRisk"),
                SynologyPhotoLinkAccess.Invited => _l.Get("PhotosShareInvitedRisk"), _ => "",
            };
            restriction.Text = limited ? _l.Get("PhotosShareRestricted") : "";
            foreach (var text in new[] { target, message, membersMessage, risk, restriction }) text.Visibility = Visible(text.Text.Length > 0);
        }
        async Task LoadMembers()
        {
            if (!Current() || candidateBusy || original?.Members is null) return;
            candidateBusy = true; membersMessage.Text = ""; Render();
            try
            {
                var values = await _model.Repository.SharingRecipientsAsync(cancellationToken: _viewCancellation.Token);
                if (Current()) editor?.SetCandidates(values);
            }
            catch (Exception error) { if (Current()) membersMessage.Text = SharingError(error); }
            finally { candidateBusy = false; Render(); }
        }
        async Task Load()
        {
            if (!Current() || busy) return; busy = true; message.Text = _l.Get("PhotosLoadingDescription"); Render();
            try
            {
                original = await _model.Repository.AlbumSharingAsync(albumId, _viewCancellation.Token); if (!Current()) return;
                target.Text = original.Album.Name; editor = new(original); editor.Changed += Render; body.Content = editor; message.Text = "";
            }
            catch (Exception error) { if (Current()) message.Text = SharingError(error); }
            finally { busy = false; Render(); }
            if (Current() && editor is not null) await LoadMembers();
        }
        retry.Click += async (_, _) => await Load(); membersRetry.Click += async (_, _) => await LoadMembers();
        copy.Click += (_, _) => { if (original?.Url is { } url) { CopyPhotoSharingLink(url, message); Render(); } };
        dialog.Closing += (_, args) => { if (submitting && Current() && _windowVisible && IsLoaded) args.Cancel = true; };
        dialog.Closed += (_, _) => closed = true;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (!Current() || busy || editor is null || !dialog.IsPrimaryButtonEnabled) return;
            var deferral = args.GetDeferral(); busy = submitting = true; Render();
            try
            {
                if (original?.Temporary == true && editor.Input().Access == SynologyPhotoLinkAccess.Disabled)
                { stopTemporary = temporaryCreation is null; if (Current()) args.Cancel = false; }
                else { submitted = await _model.Repository.EditSharingAsync(Guid.NewGuid(), editor.Input()); if (Current()) args.Cancel = false; }
            }
            catch (Exception error) { if (Current()) message.Text = SharingError(error); }
            finally { busy = submitting = false; Render(); deferral.Complete(); }
        };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); Render(); var showing = ShowPhotoDialogAsync(dialog); await Load(); await showing; }
        finally { closed = true; editor?.ClearPassword(); _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); }
        if (temporaryCreation is { } creation)
        {
            try
            {
                if (submitted is null) await _model.Repository.CancelTemporaryCreationAsync(creation);
                else await _model.Repository.KeepTemporaryAlbumsAsync(creation);
            }
            catch (Exception error) { if (!_disposed && generation == _viewGeneration) { TemporarySharingBar.IsOpen = true; TemporarySharingBar.Message = SharingError(error); } }
        }
        if (stopTemporary && !_disposed && generation == _viewGeneration && _windowVisible) await ShowTemporarySharingAsync(albumId);
        if (submitted is not null && !_disposed && generation == _viewGeneration && _windowVisible) await ShowSharingChangesAsync(submitted.Id);
    }
    private void CopyPhotoSharingLink(Uri url, TextBlock message)
    {
        try { var data = new DataPackage(); data.SetText(url.AbsoluteUri); Clipboard.SetContent(data); message.Text = _l.Get("PhotosShareCopied"); }
        catch { message.Text = _l.Get("PhotosShareCopyFailed"); }
    }
    private string SharingStateText(SynologyPhotoSharingChange change) => change.Pending ? _l.Get("PhotosShareProcessing") : change.State switch
    {
        SynologyPhotoChangeState.Completed => _l.Get("PhotosShareSaved"), SynologyPhotoChangeState.Cancelled => _l.Get("PhotosShareStopped"),
        _ when change.NeedsInput => _l.Get("PhotosShareStartAgain"),
        _ when change.Stage != SynologyPhotoSharingStage.Close => _l.Get("PhotosShareClosedIncomplete"),
        _ when change.Failure is { } failure => SharingError(new SynologyPhotoException(failure)),
        _ => _l.Get("PhotosShareReady"),
    };
    private async Task RefreshSharingStatusAsync()
    {
        await RefreshRequestStatusAsync();
        await RefreshFolderSharingStatusAsync();
        await RefreshRecognitionStatusAsync();
        await RefreshPreviewGenerationStatusAsync();
        if (!_model.Repository.SupportsSharingManagement) return; var generation = _viewGeneration;
        var values = await _model.Repository.SharingChangesAsync();
        foreach (var value in values.Where(value => value.Pending && !value.Running))
        {
            if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return;
            await _model.Repository.ReviewSharingChangeAsync(value.Id);
        }
        if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return;
        values = await _model.Repository.SharingChangesAsync();
        PhotoSharingBar.IsOpen = values.Any(value => value.Pending || value.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed);
        PhotoSharingBar.Message = _l.Get(values.Any(value => value.Pending) ? "PhotosShareProcessing" : "PhotosShareUnfinished");
        await RefreshTemporaryStatusAsync();
    }
    private async Task ShowSharingChangesAsync(Guid? selected = null)
    {
        if (_disposed || _dialog is not null || !_model.Repository.SupportsSharingManagement) return;
        var generation = _viewGeneration; var closed = false; var busy = false; long? editAgain = null;
        var values = new Dictionary<Guid, SynologyPhotoSharingChange>();
        var targets = new Dictionary<long, SynologyPhotoSharing>();
        var picker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch }; AutomationProperties.SetName(picker, _l.Get("PhotosShareChanges"));
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; var target = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var access = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var refresh = QueueButton("PhotosRefresh"); var resume = QueueButton("PhotosShareContinue"); var cancel = QueueButton("PhotosShareStop");
        var restart = QueueButton("PhotosShareEditAgain"); var copy = QueueButton("PhotosShareCopyLink");
        var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { picker, target, access, progress, message, copy, refresh, resume, restart, cancel }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosShareChanges"), CloseButtonText = _l.Get("PhotosClose"),
            Content = new ScrollViewer { Content = panel, MaxHeight = 550 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        SynologyPhotoSharingChange? Selected() => picker.SelectedItem is PhotoAlbumChangeChoice choice ? values.GetValueOrDefault(choice.Id) : null;
        void Render()
        {
            if (!Current()) return; var value = Selected(); var known = value?.Result ?? (value is null ? null : targets.GetValueOrDefault(value.AlbumId));
            target.Text = known?.Album.Name ?? ""; target.Visibility = Visible(target.Text.Length > 0);
            access.Text = value is null ? "" : _l.Get(value.Access switch { SynologyPhotoLinkAccess.Disabled => "PhotosShareDisabled", SynologyPhotoLinkAccess.Invited => "PhotosShareInvitedRisk", SynologyPhotoLinkAccess.View => "PhotosShareViewRisk", _ => "PhotosShareDownloadRisk" });
            access.Visibility = Visible(access.Text.Length > 0);
            message.Text = value is null ? _l.Get("PhotosShareChangesEmpty") : SharingStateText(value);
            picker.IsEnabled = refresh.IsEnabled = !busy; resume.IsEnabled = !busy && known is not null && value?.CanContinue == true;
            cancel.IsEnabled = !busy && value is { Running: false, State: SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed };
            restart.Visibility = Visible(value?.NeedsInput == true); restart.IsEnabled = cancel.IsEnabled && known is not null;
            copy.Visibility = Visible(value is { State: SynologyPhotoChangeState.Completed, Result.Url: not null }); copy.IsEnabled = !busy;
            progress.IsActive = busy; progress.Visibility = Visible(busy);
        }
        async Task Load(bool review = false, bool proceed = false, bool stop = false)
        {
            if (!Current() || busy) return; var prior = Selected(); busy = true; Render(); string? error = null;
            try
            {
                if (prior is not null && proceed) await _model.Repository.ContinueSharingChangeAsync(prior.Id);
                if (prior is not null && stop) await _model.Repository.CancelSharingChangeAsync(prior.Id);
                var changes = await _model.Repository.SharingChangesAsync();
                if (review) foreach (var change in changes.Where(change => change.Pending && !change.Running))
                { if (!Current()) return; await _model.Repository.ReviewSharingChangeAsync(change.Id); }
                changes = await _model.Repository.SharingChangesAsync(); if (!Current()) return;
                values = changes.ToDictionary(change => change.Id); var id = prior?.Id ?? selected;
                var entries = changes.Select((change, index) => new PhotoAlbumChangeChoice(change.Id, _l.Format("PhotosChangeChoice", index + 1, _l.Get("PhotosShareAlbum")))).ToArray();
                picker.ItemsSource = entries; picker.SelectedIndex = entries.Length == 0 ? -1 : Math.Max(0, Array.FindIndex(entries, item => item.Id == id));
                foreach (var change in changes.Where(change => change.Result is null && (change.CanContinue || change.NeedsInput)))
                { var snapshot = await _model.Repository.AlbumSharingAsync(change.AlbumId, _viewCancellation.Token); if (!Current()) return; targets[change.AlbumId] = snapshot; }
            }
            catch (Exception failure) { error = SharingError(failure); }
            finally { busy = false; Render(); if (Current() && error is not null) message.Text = error; }
        }
        picker.SelectionChanged += (_, _) => Render(); refresh.Click += async (_, _) => await Load(review: true);
        resume.Click += async (_, _) => await Load(proceed: true); cancel.Click += async (_, _) => await Load(stop: true);
        restart.Click += async (_, _) => { var value = Selected(); if (value is null || busy) return; await Load(stop: true); if (Current() && Selected()?.State == SynologyPhotoChangeState.Cancelled) { editAgain = value.AlbumId; dialog.Hide(); } };
        copy.Click += (_, _) => { if (Selected()?.Result?.Url is { } url) CopyPhotoSharingLink(url, message); };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) }; timer.Tick += async (_, _) => { if (values.Values.Any(value => value.Pending)) await Load(review: true); };
        dialog.Closed += (_, _) => { closed = true; timer.Stop(); };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(review: true); await showing; }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
        if (_disposed || !_windowVisible || generation != _viewGeneration) return;
        if (editAgain is { } id) await ShowAlbumSharingAsync(id);
        else if (values.Values.Any(value => value.State == SynologyPhotoChangeState.Completed)) await _model.RefreshAsync();
    }
}
