using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private DispatcherTimer? _albumRefreshTimer;
    private bool _albumRefreshing;
    private readonly HashSet<Guid> _pendingAlbumChanges = [];
    private sealed record PhotoAlbumChangeChoice(Guid Id, string Title) { public override string ToString() => Title; }
    private void StartAlbumRefresh()
    {
        if (_disposed || !_windowVisible || !(_model.Repository.SupportsAlbumManagement || _model.Repository.SupportsSharingManagement)) return;
        if (_albumRefreshTimer is null)
        { _albumRefreshTimer = new() { Interval = TimeSpan.FromSeconds(15) }; _albumRefreshTimer.Tick += async (_, _) => await RefreshAlbumsAsync(); }
        _albumRefreshTimer.Start(); _ = RefreshAlbumsAsync();
    }
    private async Task RefreshAlbumsAsync()
    {
        if (_disposed || !_windowVisible || !IsLoaded || _dialog is not null || _albumRefreshing) return;
        _albumRefreshing = true; var generation = _viewGeneration;
        bool Current() => !_disposed && _windowVisible && IsLoaded && generation == _viewGeneration;
        try
        {
            if (!_model.Repository.SupportsAlbumManagement) { await RefreshSharingStatusAsync(); return; }
            var changes = await _model.Repository.AlbumChangesAsync();
            foreach (var change in changes.Where(change => change.Pending)) _pendingAlbumChanges.Add(change.Id);
            foreach (var change in changes.Where(change => change.Pending && !change.Running))
            { if (!Current() || _dialog is not null) return; await _model.Repository.ReviewAlbumChangeAsync(change.Id); }
            if (!Current() || _dialog is not null) return;
            changes = await _model.Repository.AlbumChangesAsync();
            foreach (var change in changes.Where(change => _pendingAlbumChanges.Contains(change.Id)))
            {
                if (!Current() || _dialog is not null) return;
                await _model.ApplyAlbumChangeAsync(change); generation = _viewGeneration;
                if (!change.Pending) _pendingAlbumChanges.Remove(change.Id);
            }
            if (!Current()) return;
            PhotoAlbumBar.IsOpen = changes.Any(change => change.Pending); PhotoAlbumBar.Message = _l.Get("PhotosAlbumProcessing");
            await RefreshSharingStatusAsync();
        }
        catch (Exception error) { if (Current()) { PhotoAlbumBar.Message = _l.Get(AlbumErrorKey(error)); PhotoAlbumBar.IsOpen = true; } }
        finally { _albumRefreshing = false; }
    }
    private string AlbumStateText(SynologyPhotoAlbumChange change) => change.ReplacementCreated && change.State != SynologyPhotoChangeState.Completed ?
        _l.Get(change.Pending ? "PhotosConditionCleanupProcessing" : "PhotosConditionBothKept") : change.Pending ? _l.Get("PhotosAlbumProcessing") : change.State == SynologyPhotoChangeState.Completed ? _l.Get("PhotosAlbumCompleted") :
        change.State == SynologyPhotoChangeState.Failed && change.Failure is { } failure ? _l.Get(AlbumErrorKey(new SynologyPhotoException(failure))) : ChangeStateText(change.State);
    private string AlbumMemberStateText(SynologyPhotoAlbumEditKind kind, SynologyPhotoChangeState state) => state == SynologyPhotoChangeState.Failed ? _l.Get("PhotosAlbumIncomplete") : state != SynologyPhotoChangeState.Completed ? ChangeStateText(state) : _l.Get(kind switch
    { SynologyPhotoAlbumEditKind.AddMembers => "PhotosAlbumAdded", SynologyPhotoAlbumEditKind.RemoveMembers => "PhotosAlbumRemoved", _ => "PhotosAlbumCompleted" });
    private static bool CanResumeAlbum(SynologyPhotoAlbumChange change) => !change.Running &&
        change.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed &&
        (change.CanContinue || change.Edit.Kind is SynologyPhotoAlbumEditKind.Create or SynologyPhotoAlbumEditKind.Rename or SynologyPhotoAlbumEditKind.CreateCondition or SynologyPhotoAlbumEditKind.Condition or SynologyPhotoAlbumEditKind.Rebuild);
    private async Task ShowAlbumChangesAsync(Guid? selected = null)
    {
        if (_disposed || _dialog is not null || !_model.Repository.SupportsAlbumManagement) return;
        var generation = _viewGeneration; var closed = false; var busy = false;
        var values = new Dictionary<Guid, SynologyPhotoAlbumChange>(); SynologyPhotoAlbumChange? resume = null;
        var picker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(picker, _l.Get("PhotosAlbumChanges"));
        var target = new TextBlock { TextWrapping = TextWrapping.Wrap }; var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var members = new ItemsControl { ItemTemplate = (DataTemplate)Resources["PhotoUploadItemTemplate"] };
        var memberScroll = new ScrollViewer { Content = members, MaxHeight = 220, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(members, _l.Get("PhotosSelectedFiles"));
        var refresh = QueueButton("PhotosRefresh"); var proceed = QueueButton("PhotosAlbumContinue"); var cancel = QueueButton("PhotosAlbumCancel");
        var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; actions.Children.Add(refresh); actions.Children.Add(proceed);
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { picker, progress, target, message, memberScroll, actions, cancel }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosAlbumChanges"), CloseButtonText = _l.Get("PhotosClose"),
            Content = new ScrollViewer { Content = panel, MaxHeight = 550 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        SynologyPhotoAlbumChange? Selected() => picker.SelectedItem is PhotoAlbumChangeChoice choice ? values.GetValueOrDefault(choice.Id) : null;
        void RenderHistory()
        {
            if (!Current()) return; var value = Selected();
            target.Text = value?.Result?.Name ?? value?.Edit.Name ?? value?.Edit.Album?.Name ?? "";
            message.Text = value is null ? _l.Get("PhotosAlbumChangesEmpty") : AlbumStateText(value);
            members.ItemsSource = value?.Members.Select(member => _l.Format("PhotosAlbumMemberStatus", member.Photo.Filename, AlbumMemberStateText(value.Edit.Kind, member.State))).ToArray();
            picker.IsEnabled = refresh.IsEnabled = !busy; proceed.IsEnabled = !busy && value is not null && CanResumeAlbum(value);
            cancel.IsEnabled = !busy && value is { Running: false, State: SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed };
            progress.IsActive = busy; progress.Visibility = Visible(busy);
        }
        async Task Load(bool review = false, bool cancelSelected = false)
        {
            if (!Current() || busy) return; var prior = Selected(); busy = true; RenderHistory(); string? errorText = null;
            try
            {
                if (prior is not null && cancelSelected) await _model.Repository.CancelAlbumChangeAsync(prior.Id);
                var changes = await _model.Repository.AlbumChangesAsync();
                foreach (var change in changes.Where(change => change.Pending)) _pendingAlbumChanges.Add(change.Id);
                if (review)
                {
                    foreach (var change in changes.Where(change => change.Pending && !change.Running))
                    { if (!Current()) return; await _model.Repository.ReviewAlbumChangeAsync(change.Id); }
                    changes = await _model.Repository.AlbumChangesAsync();
                }
                if (!Current()) return;
                values = changes.ToDictionary(change => change.Id); var id = prior?.Id ?? selected;
                var entries = changes.Select((change, index) => new PhotoAlbumChangeChoice(change.Id, _l.Format("PhotosChangeChoice", index + 1, AlbumEditTitle(change.Edit.Kind)))).ToArray();
                picker.ItemsSource = entries; picker.SelectedIndex = entries.Length == 0 ? -1 : Math.Max(0, Array.FindIndex(entries, entry => entry.Id == id));
            }
            catch (Exception error) { errorText = _l.Get(AlbumErrorKey(error)); }
            finally { busy = false; RenderHistory(); if (Current() && errorText is not null) message.Text = errorText; }
        }
        picker.SelectionChanged += (_, _) => RenderHistory(); refresh.Click += async (_, _) => await Load(true); cancel.Click += async (_, _) => await Load(cancelSelected: true);
        proceed.Click += (_, _) => { if (!busy && Selected() is { } value && CanResumeAlbum(value)) { resume = value; dialog.Hide(); } };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) }; timer.Tick += async (_, _) => { if (values.Values.Any(change => change.Pending)) await Load(true); };
        dialog.Closed += (_, _) => { closed = true; timer.Stop(); };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(true); await showing; }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
        if (_disposed || !_windowVisible || generation != _viewGeneration) return;
        if (resume is not null)
        {
            if (resume.Edit.Kind is SynologyPhotoAlbumEditKind.CreateCondition or SynologyPhotoAlbumEditKind.Condition or SynologyPhotoAlbumEditKind.Unfreeze or SynologyPhotoAlbumEditKind.Rebuild)
                await ShowConditionAlbumAsync(resume.Edit.Kind, resume: resume);
            else await ShowAlbumEditAsync(resume.Edit, resumeId: resume.Id);
        }
        // 冷启动已结束的历史只供查看，不能把旧移除重演到后来重新加入的成员上。
        else foreach (var change in values.Values.Where(change => _pendingAlbumChanges.Contains(change.Id)))
            if (!_disposed) { await _model.ApplyAlbumChangeAsync(change); if (!change.Pending) _pendingAlbumChanges.Remove(change.Id); }
    }
}
