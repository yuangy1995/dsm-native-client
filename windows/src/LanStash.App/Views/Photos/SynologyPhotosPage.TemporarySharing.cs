using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private void RenderTemporaryControls()
    {
        var supported = _model.Repository.SupportsSharingManagement;
        CreateTemporarySharingMenu.Visibility = StopTemporarySharingMenu.Visibility = TemporarySharingChangesMenu.Visibility = Visible(supported);
        CreateTemporarySharingMenu.Text = _l.Get("PhotosTemporaryCreate"); StopTemporarySharingMenu.Text = _l.Get("PhotosTemporaryStop");
        TemporarySharingChangesMenu.Text = _l.Get("PhotosTemporaryChanges"); TemporarySharingHistoryButton.Content = _l.Get("PhotosTemporaryChanges");
        var ready = !_managementPreparing && !_model.IsLoading && _model.HasLoaded;
        var photos = SelectedManagementPhotos();
        CreateTemporarySharingMenu.IsEnabled = ready && photos.Length is > 0 and <= 100 && photos.Length == LibraryGrid.SelectedItems.Count;
        StopTemporarySharingMenu.IsEnabled = ready && SelectedAlbumId() is not null;
    }
    private async void CreateTemporarySharing_Click(object sender, RoutedEventArgs args) => await ShowTemporarySharingAsync();
    private async void StopTemporarySharing_Click(object sender, RoutedEventArgs args) { if (SelectedAlbumId() is { } id) await ShowTemporarySharingAsync(id); }
    private async void TemporarySharingChanges_Click(object sender, RoutedEventArgs args) => await ShowTemporaryChangesAsync();
    private async Task ShowTemporarySharingAsync(long? albumId = null)
    {
        if (_disposed || _dialog is not null || _managementPreparing || !_model.Repository.SupportsSharingManagement) return;
        var photos = SelectedManagementPhotos(); var creating = albumId is null;
        if (creating && photos.Length is 0 or > 100) return;
        _managementPreparing = true; RenderManagementControls(); var generation = _viewGeneration;
        var closed = false; var busy = false; var submitted = false; var handedOff = false; var id = Guid.NewGuid();
        SynologyPhotoSharing? original = null; SynologyPhotoTemporaryChange? result = null;
        var name = new TextBox { Header = _l.Get("PhotosAlbumName"), MaxLength = 255, Visibility = Visible(creating) };
        var target = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var copy = new CheckBox { Content = _l.Get("PhotosTemporaryKeepCopy"), IsChecked = true, Visibility = Visible(!creating) };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var risk = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = _l.Get(creating ? "PhotosTemporaryCreateRisk" : "PhotosTemporaryStopRisk") };
        var retry = QueueButton("PhotosRetry");
        var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 540, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { target, name, copy, risk, progress, message, retry }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get(creating ? "PhotosTemporaryCreate" : "PhotosTemporaryStop"),
            PrimaryButtonText = _l.Get(creating ? "PhotosTemporaryCreate" : "PhotosTemporaryStop"), CloseButtonText = _l.Get("PhotosCancel"),
            DefaultButton = ContentDialogButton.Close, Content = new ScrollViewer { Content = panel, MaxHeight = 540 }, IsPrimaryButtonEnabled = false };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        var safety = _model.Repository.SharingSafety.TemporaryCleanup && (!creating || _model.Repository.SharingSafety.Publish);
        void Render()
        {
            if (!Current()) return;
            dialog.IsPrimaryButtonEnabled = !busy && !submitted && safety && (creating ? !string.IsNullOrWhiteSpace(name.Text) : original is { Temporary: true, Album.Conditional: false, Album.Frozen: false });
            name.IsEnabled = copy.IsEnabled = !busy && !submitted; progress.IsActive = busy; progress.Visibility = Visible(busy);
            retry.Visibility = Visible(!creating && original is null && !busy); retry.IsEnabled = !busy;
            if (!safety) message.Text = _l.Get("PhotosTemporaryRestricted");
            target.Visibility = Visible(target.Text.Length > 0); message.Visibility = Visible(message.Text.Length > 0);
        }
        async Task Load()
        {
            if (creating || !Current() || busy) return; busy = true; message.Text = ""; Render();
            try { original = await _model.Repository.AlbumSharingAsync(albumId!.Value, _viewCancellation.Token); if (!Current()) return;
                target.Text = original.Album.Name; if (original.Temporary != true) message.Text = _l.Get("PhotosTemporaryNotTemporary"); }
            catch (Exception error) { if (Current()) message.Text = SharingError(error); }
            finally { busy = false; Render(); }
        }
        name.TextChanged += (_, _) => Render(); retry.Click += async (_, _) => await Load();
        dialog.Closed += async (_, _) =>
        {
            closed = true;
            if (creating && submitted && !handedOff)
                try { await _model.Repository.CancelTemporaryCreationAsync(id); } catch (SynologyPhotoException) { }
        };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (!Current() || busy || submitted || !dialog.IsPrimaryButtonEnabled) return;
            busy = submitted = true; Render();
            try
            {
                result = creating ? await _model.Repository.CreateTemporarySharingAsync(id, name.Text, photos) :
                    await _model.Repository.StopTemporarySharingAsync(id, original!, copy.IsChecked == true);
                if (Current()) { handedOff = true; dialog.Hide(); }
                else if (creating) await _model.Repository.CancelTemporaryCreationAsync(id);
            }
            catch (Exception error) { submitted = false; if (Current()) message.Text = SharingError(error); }
            finally { busy = false; Render(); }
        };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); Render(); var showing = ShowPhotoDialogAsync(dialog); await Load(); await showing; }
        finally { closed = true; _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); }
        if (_disposed || !_windowVisible || generation != _viewGeneration || result is null) return;
        if (result.CanConfigure && result.AlbumId is { } created) await ShowAlbumSharingAsync(created, result.Id);
        else await ShowTemporaryChangesAsync(result.Id);
    }
    private string TemporaryStateText(SynologyPhotoTemporaryChange value) => value.Pending ? _l.Get("PhotosTemporaryProcessing") :
        value.State == SynologyPhotoChangeState.Completed ? _l.Get(value.FromCreation && !value.CancelRequested ? "PhotosTemporaryReady" : "PhotosTemporaryStopped") :
        value.State == SynologyPhotoChangeState.Cancelled ? _l.Get("PhotosTemporaryKept") :
        value.CanConfigure ? _l.Get("PhotosTemporaryConfigure") : value.Failure is { } failure ? SharingError(new SynologyPhotoException(failure)) :
        _l.Get(value.CopyId is not null ? "PhotosTemporaryCopyKept" : "PhotosTemporaryUnfinished");
    private async Task RefreshTemporaryStatusAsync()
    {
        if (!_model.Repository.SupportsSharingManagement) return; var generation = _viewGeneration;
        var values = await _model.Repository.TemporarySharingChangesAsync();
        foreach (var value in values.Where(value => value.Pending && !value.Running))
        { if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return; await _model.Repository.ReviewTemporarySharingAsync(value.Id); }
        if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return;
        values = await _model.Repository.TemporarySharingChangesAsync();
        foreach (var value in values.Where(value => value.State == SynologyPhotoChangeState.Completed))
        { if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return; await _model.ApplyTemporaryChangeAsync(value); generation = _viewGeneration; }
        TemporarySharingBar.IsOpen = values.Any(value => value.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled));
        TemporarySharingBar.Message = _l.Get(values.Any(value => value.Pending) ? "PhotosTemporaryProcessing" : "PhotosTemporaryUnfinished");
    }
    private async Task ShowTemporaryChangesAsync(Guid? selected = null)
    {
        if (_disposed || _dialog is not null || !_model.Repository.SupportsSharingManagement) return;
        var generation = _viewGeneration; var closed = false; var busy = false; SynologyPhotoTemporaryChange? configure = null;
        var values = new Dictionary<Guid, SynologyPhotoTemporaryChange>(); var targets = new Dictionary<long, string>();
        var picker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch }; AutomationProperties.SetName(picker, _l.Get("PhotosTemporaryChanges"));
        var target = new TextBlock { TextWrapping = TextWrapping.Wrap }; var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var refresh = QueueButton("PhotosRefresh"); var resume = QueueButton("PhotosShareContinue"); var settings = QueueButton("PhotosTemporaryConfigureButton");
        var cancel = QueueButton("PhotosTemporaryCancelCreation"); var keep = QueueButton("PhotosTemporaryKeepAlbums");
        var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 540, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { picker, target, progress, message, refresh, resume, settings, cancel, keep }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosTemporaryChanges"), CloseButtonText = _l.Get("PhotosClose"),
            Content = new ScrollViewer { Content = panel, MaxHeight = 550 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        SynologyPhotoTemporaryChange? Selected() => picker.SelectedItem is PhotoAlbumChangeChoice choice ? values.GetValueOrDefault(choice.Id) : null;
        void Render()
        {
            if (!Current()) return; var value = Selected();
            target.Text = value?.AlbumId is { } id ? targets.GetValueOrDefault(id) ?? "" : ""; target.Visibility = Visible(target.Text.Length > 0);
            message.Text = value is null ? _l.Get("PhotosTemporaryEmpty") : TemporaryStateText(value);
            refresh.IsEnabled = picker.IsEnabled = !busy; resume.IsEnabled = !busy && value?.CanContinue == true;
            settings.Visibility = Visible(value?.CanConfigure == true); settings.IsEnabled = !busy && target.Text.Length > 0;
            cancel.Visibility = Visible(value is { FromCreation: true, State: not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled) });
            cancel.IsEnabled = !busy && value?.CancelRequested == false;
            keep.IsEnabled = !busy && value is { Running: false, State: SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed };
            progress.IsActive = busy; progress.Visibility = Visible(busy);
        }
        async Task Load(string? action = null)
        {
            if (!Current() || busy) return; var prior = Selected(); busy = true; Render(); string? error = null;
            try
            {
                if (prior is not null)
                {
                    if (action == "continue") await _model.Repository.ContinueTemporarySharingAsync(prior.Id);
                    if (action == "cancel") await _model.Repository.CancelTemporaryCreationAsync(prior.Id);
                    if (action == "keep") await _model.Repository.KeepTemporaryAlbumsAsync(prior.Id);
                }
                var changes = await _model.Repository.TemporarySharingChangesAsync();
                foreach (var change in changes.Where(value => value.Pending && !value.Running))
                { if (!Current()) return; await _model.Repository.ReviewTemporarySharingAsync(change.Id); }
                changes = await _model.Repository.TemporarySharingChangesAsync(); if (!Current()) return; values = changes.ToDictionary(value => value.Id);
                var entries = changes.Select((value, index) => new PhotoAlbumChangeChoice(value.Id, _l.Format("PhotosChangeChoice", index + 1,
                    _l.Get(value.FromCreation ? "PhotosTemporaryCreate" : value.KeepCopy ? "PhotosTemporaryStopWithCopy" : "PhotosTemporaryStop")))).ToArray();
                picker.ItemsSource = entries; picker.SelectedIndex = entries.Length == 0 ? -1 : Math.Max(0, Array.FindIndex(entries, item => item.Id == (prior?.Id ?? selected)));
                foreach (var change in changes.Where(value => value.CanConfigure || value.CanContinue))
                { if (change.AlbumId is not { } id) continue; var snapshot = await _model.Repository.AlbumSharingAsync(id, _viewCancellation.Token); if (!Current()) return; targets[id] = snapshot.Album.Name; }
            }
            catch (Exception failure) { error = SharingError(failure); }
            finally { busy = false; Render(); if (Current() && error is not null) message.Text = error; }
        }
        picker.SelectionChanged += (_, _) => Render(); refresh.Click += async (_, _) => await Load(); resume.Click += async (_, _) => await Load("continue");
        cancel.Click += async (_, _) => await Load("cancel"); keep.Click += async (_, _) => await Load("keep");
        settings.Click += (_, _) => { if (!busy && Selected()?.CanConfigure == true) { configure = Selected(); dialog.Hide(); } };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) }; timer.Tick += async (_, _) => { if (values.Values.Any(value => value.Pending)) await Load(); };
        dialog.Closed += (_, _) => { closed = true; timer.Stop(); };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(); await showing; }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
        if (_disposed || !_windowVisible || generation != _viewGeneration) return;
        if (configure?.AlbumId is { } album) await ShowAlbumSharingAsync(album, configure.Id);
        else foreach (var value in values.Values.Where(value => value.State == SynologyPhotoChangeState.Completed)) await _model.ApplyTemporaryChangeAsync(value);
    }
}
