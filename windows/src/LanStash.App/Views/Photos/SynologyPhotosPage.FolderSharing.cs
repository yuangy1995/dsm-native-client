using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private void RenderFolderSharingControls()
    {
        var supported = _model.Repository.SupportsFolderSharing;
        PhotoFolderSharingMenu.Visibility = PhotoFolderSharingChangesMenu.Visibility = Visible(supported);
        PhotoFolderSharingMenu.Text = _l.Get("PhotosFolderShareTitle"); PhotoFolderSharingChangesMenu.Text = _l.Get("PhotosFolderShareChanges");
        PhotoFolderSharingHistoryButton.Content = _l.Get("PhotosFolderShareChanges");
        var target = SelectedPhotoFolder();
        PhotoFolderSharingMenu.IsEnabled = supported && !_managementPreparing && !_model.IsLoading && _model.CanManageSharedSpace &&
            _model.Section == SynologyPhotosSection.Folders && target is { Space: SynologyPhotoSpace.Shared, Path: not null } &&
            target.Path.Split('/', StringSplitOptions.RemoveEmptyEntries).Length is 1 or 2;
    }
    private async void PhotoFolderSharing_Click(object sender, RoutedEventArgs args)
    { if (SelectedPhotoFolder() is { } folder) await ShowFolderSharingAsync(folder.Id); }
    private async void PhotoFolderSharingChanges_Click(object sender, RoutedEventArgs args) => await ShowFolderSharingChangesAsync();
    private async Task ShowFolderSharingAsync(long folderId)
    {
        if (_disposed || _dialog is not null || _managementPreparing || !_model.Repository.SupportsFolderSharing) return;
        var generation = _viewGeneration; var closed = false; var busy = false; var candidateBusy = false; var submitting = false;
        _managementPreparing = true; RenderManagementControls();
        SynologyPhotoFolderSharing? original = null; SynologyPhotoFolderSharingEditor? editor = null; SynologyPhotoFolderSharingChange? submitted = null;
        SynologyPhotoFolderSharingEdit? frozen = null;
        var target = new TextBlock { TextWrapping = TextWrapping.Wrap }; var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var memberError = new TextBlock { TextWrapping = TextWrapping.Wrap }; var restriction = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var body = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var retry = QueueButton("PhotosRetry"); var membersRetry = QueueButton("PhotosShareReloadMembers"); var copy = QueueButton("PhotosShareCopyLink");
        var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { target, copy, progress, message, retry, restriction, body, memberError, membersRetry }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosFolderShareTitle"),
            PrimaryButtonText = _l.Get("PhotosShareContinue"), CloseButtonText = _l.Get("PhotosCancel"), DefaultButton = ContentDialogButton.Close,
            IsPrimaryButtonEnabled = false, Content = new ScrollViewer { Content = panel, MaxHeight = 550 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        void Render()
        {
            if (!Current()) return; SynologyPhotoFolderSharingEdit? input = null; try { input = editor?.Input(); } catch (ArgumentException) { }
            var editable = original is { InheritsManagementOnly: false };
            dialog.IsPrimaryButtonEnabled = input is not null && editable && !busy && _model.Repository.SharingSafety.FolderPermissions;
            body.IsEnabled = editable && !busy; retry.Visibility = Visible(editor is null && !busy); retry.IsEnabled = !busy;
            copy.Visibility = Visible(original?.Url is not null); copy.IsEnabled = !busy;
            membersRetry.Visibility = Visible(editable && original?.Members is not null); membersRetry.IsEnabled = !busy && !candidateBusy;
            restriction.Text = original?.InheritsManagementOnly == true ? _l.Get("PhotosFolderShareParentRestricted") :
                original is not null && !_model.Repository.SharingSafety.FolderPermissions ? _l.Get("PhotosFolderShareRestricted") : "";
            progress.IsActive = busy || candidateBusy; progress.Visibility = Visible(progress.IsActive);
            foreach (var text in new[] { target, message, memberError, restriction }) text.Visibility = Visible(text.Text.Length > 0);
        }
        async Task LoadMembers()
        {
            if (!Current() || candidateBusy || original is not { Members: not null, InheritsManagementOnly: false }) return;
            candidateBusy = true; memberError.Text = ""; Render();
            try { var values = await _model.Repository.SharingRecipientsAsync(true, _viewCancellation.Token); if (Current()) editor?.SetCandidates(values); }
            catch (Exception error) { if (Current()) memberError.Text = SharingError(error); }
            finally { candidateBusy = false; Render(); }
        }
        async Task Load()
        {
            if (!Current() || busy) return; busy = true; message.Text = _l.Get("PhotosLoadingDescription"); Render();
            try
            {
                var folder = await _model.Repository.FolderAsync(folderId, SynologyPhotoSpace.Shared, _viewCancellation.Token);
                original = await _model.Repository.FolderSharingAsync(folder, _viewCancellation.Token); if (!Current()) return;
                target.Text = folder.Path; editor = new(original); editor.Changed += Render; body.Content = editor; message.Text = "";
            }
            catch (Exception error) { if (Current()) message.Text = SharingError(error); }
            finally { busy = false; Render(); }
            if (Current()) await LoadMembers();
        }
        retry.Click += async (_, _) => await Load(); membersRetry.Click += async (_, _) => await LoadMembers();
        copy.Click += (_, _) => { if (original?.Url is { } url) { CopyPhotoSharingLink(url, message); Render(); } };
        dialog.Closing += (_, args) => { if (submitting && Current() && _windowVisible && IsLoaded) args.Cancel = true; };
        dialog.Closed += (_, _) => closed = true;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (!Current() || busy || editor is null || !dialog.IsPrimaryButtonEnabled) return;
            var deferral = args.GetDeferral(); busy = submitting = true; Render();
            try { var input = editor.Input(); await _model.Repository.PrepareFolderSharingAsync(input, _viewCancellation.Token); if (Current()) { frozen = input; args.Cancel = false; } }
            catch (Exception error) { if (Current()) message.Text = SharingError(error); }
            finally { busy = submitting = false; Render(); deferral.Complete(); }
        };
        try
        {
            SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); Render(); var showing = ShowPhotoDialogAsync(dialog); await Load(); await showing;
            if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null);
            if (frozen is not null && !_disposed && generation == _viewGeneration && _windowVisible)
                submitted = await ConfirmFolderSharingAsync(frozen);
        }
        finally { closed = true; editor?.ClearPassword(); frozen = null; _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); }
        if (submitted is not null && !_disposed && generation == _viewGeneration && _windowVisible) await ShowFolderSharingChangesAsync(submitted.Id);
    }
    private async Task<SynologyPhotoFolderSharingChange?> ConfirmFolderSharingAsync(SynologyPhotoFolderSharingEdit edit)
    {
        var generation = _viewGeneration; var closed = false; var busy = false; SynologyPhotoFolderSharingChange? result = null;
        var message = new TextBlock { Text = _l.Get("PhotosFolderShareConfirmBody"), TextWrapping = TextWrapping.Wrap };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 560, Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = edit.Original.Folder.Path, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock { Text = _l.Get(edit.Access switch { SynologyPhotoFolderAccess.Management => "PhotosFolderShareManagement", SynologyPhotoFolderAccess.Invited => "PhotosFolderShareInvitedRisk", SynologyPhotoFolderAccess.View => "PhotosFolderShareViewRisk", _ => "PhotosFolderShareDownloadRisk" }), TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(message);
        if (edit.AppliesToSubfolders && edit.Original.Depth == 1) panel.Children.Add(new TextBlock { Text = _l.Get("PhotosFolderShareApplyRisk"), TextWrapping = TextWrapping.Wrap });
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosFolderShareConfirm"),
            PrimaryButtonText = _l.Get("PhotosSaveChanges"), CloseButtonText = _l.Get("PhotosCancel"), DefaultButton = ContentDialogButton.Close,
            Content = new ScrollViewer { Content = panel, MaxHeight = 480 } };
        dialog.Closing += (_, args) => { if (busy && !closed && !_disposed && _windowVisible && IsLoaded) args.Cancel = true; };
        dialog.Closed += (_, _) => closed = true;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (busy || closed || _disposed || generation != _viewGeneration) return;
            var deferral = args.GetDeferral(); busy = true; dialog.IsPrimaryButtonEnabled = false;
            try { result = await _model.Repository.EditFolderSharingAsync(Guid.NewGuid(), edit); if (!closed && !_disposed && generation == _viewGeneration) args.Cancel = false; }
            catch (Exception error) { if (!closed && !_disposed && generation == _viewGeneration) message.Text = SharingError(error); }
            finally { busy = false; dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); }
        };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); await ShowPhotoDialogAsync(dialog); } finally { closed = true; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
        return result;
    }
    private string FolderSharingStateText(SynologyPhotoFolderSharingChange value) => value.Pending ? _l.Get("PhotosShareProcessing") : value.State switch
    {
        SynologyPhotoChangeState.Completed => _l.Get("PhotosShareSaved"),
        _ when value.PermissionsSaved => _l.Get("PhotosFolderShareDefaultIncomplete"),
        SynologyPhotoChangeState.Cancelled => _l.Get("PhotosShareStopped"),
        _ when value.NeedsInput => _l.Get("PhotosShareStartAgain"),
        _ when value.Failure is { } failure => SharingError(new SynologyPhotoException(failure)), _ => _l.Get("PhotosShareReady"),
    };
    private async Task RefreshFolderSharingStatusAsync()
    {
        if (!_model.Repository.SupportsFolderSharing) return; var generation = _viewGeneration;
        var values = await _model.Repository.FolderSharingChangesAsync();
        foreach (var value in values.Where(value => value.Pending && !value.Running))
        { if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return; await _model.Repository.ReviewFolderSharingAsync(value.Id); }
        if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return;
        values = await _model.Repository.FolderSharingChangesAsync(); PhotoFolderSharingBar.IsOpen = values.Any(value => value.Pending || value.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed);
        PhotoFolderSharingBar.Message = _l.Get(values.Any(value => value.Pending) ? "PhotosShareProcessing" : "PhotosFolderShareUnfinished");
    }
    private async Task ShowFolderSharingChangesAsync(Guid? selected = null)
    {
        if (_disposed || _dialog is not null || !_model.Repository.SupportsFolderSharing) return;
        var generation = _viewGeneration; var closed = false; var busy = false; long? editAgain = null;
        var values = new Dictionary<Guid, SynologyPhotoFolderSharingChange>();
        var picker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch }; AutomationProperties.SetName(picker, _l.Get("PhotosFolderShareChanges"));
        var target = new TextBlock { TextWrapping = TextWrapping.Wrap }; var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var refresh = QueueButton("PhotosRefresh"); var resume = QueueButton("PhotosShareContinue"); var cancel = QueueButton("PhotosShareStop");
        var restart = QueueButton("PhotosShareEditAgain"); var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { picker, target, progress, message, refresh, resume, restart, cancel }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosFolderShareChanges"), CloseButtonText = _l.Get("PhotosClose"), Content = new ScrollViewer { Content = panel, MaxHeight = 550 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        SynologyPhotoFolderSharingChange? Selected() => picker.SelectedItem is PhotoFolderChangeChoice choice ? values.GetValueOrDefault(choice.Id) : null;
        void Render()
        {
            if (!Current()) return; var value = Selected(); target.Text = value?.Result?.Folder.Path ?? ""; target.Visibility = Visible(target.Text.Length > 0);
            message.Text = value is null ? _l.Get("PhotosFolderShareChangesEmpty") : FolderSharingStateText(value);
            picker.IsEnabled = refresh.IsEnabled = !busy; resume.IsEnabled = !busy && value?.CanContinue == true;
            cancel.IsEnabled = !busy && value is { Running: false, State: SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed };
            restart.Visibility = Visible(value?.NeedsInput == true); restart.IsEnabled = cancel.IsEnabled && value?.Result is not null;
            progress.IsActive = busy; progress.Visibility = Visible(busy);
        }
        async Task Load(bool review = false, bool proceed = false, bool stop = false)
        {
            if (!Current() || busy) return; var prior = Selected(); busy = true; Render(); string? error = null;
            try
            {
                if (prior is not null && proceed) await _model.Repository.ContinueFolderSharingAsync(prior.Id);
                if (prior is not null && stop) await _model.Repository.CancelFolderSharingAsync(prior.Id);
                var changes = await _model.Repository.FolderSharingChangesAsync();
                if (review) foreach (var change in changes.Where(change => !change.Running && (change.Pending || change.Result is null)))
                { if (!Current()) return; await _model.Repository.ReviewFolderSharingAsync(change.Id); }
                changes = await _model.Repository.FolderSharingChangesAsync(); if (!Current()) return; values = changes.ToDictionary(value => value.Id);
                var id = prior?.Id ?? selected; var entries = changes.Select((value, index) => new PhotoFolderChangeChoice(value.Id, _l.Format("PhotosChangeChoice", index + 1, _l.Get("PhotosFolderShareTitle")))).ToArray();
                picker.ItemsSource = entries; picker.SelectedIndex = entries.Length == 0 ? -1 : Math.Max(0, Array.FindIndex(entries, value => value.Id == id));
            }
            catch (Exception failure) { error = SharingError(failure); }
            finally { busy = false; Render(); if (Current() && error is not null) message.Text = error; }
        }
        picker.SelectionChanged += (_, _) => Render(); refresh.Click += async (_, _) => await Load(review: true);
        resume.Click += async (_, _) => await Load(proceed: true); cancel.Click += async (_, _) => await Load(stop: true);
        restart.Click += async (_, _) => { var value = Selected(); if (value is null || busy) return; await Load(stop: true); if (Current() && Selected()?.State == SynologyPhotoChangeState.Cancelled) { editAgain = value.FolderId; dialog.Hide(); } };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) }; timer.Tick += async (_, _) => { if (values.Values.Any(value => value.Pending)) await Load(review: true); };
        dialog.Closed += (_, _) => { closed = true; timer.Stop(); };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(review: true); await showing; }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
        if (editAgain is { } id && !_disposed && _windowVisible && generation == _viewGeneration) await ShowFolderSharingAsync(id);
    }
}
