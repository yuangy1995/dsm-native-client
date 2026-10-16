using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private long? SelectedAlbumId() => _model.Album?.Id ?? (LibraryGrid.SelectedItems.Count == 1 && LibraryGrid.SelectedItems[0] is SynologyPhotoCell cell
        ? _model.Section == SynologyPhotosSection.Albums && _model.Category is null ? cell.Collection?.Id : cell.Shared?.AlbumId : null);
    private string AlbumEditTitle(SynologyPhotoAlbumEditKind kind) => _l.Get(kind switch
    {
        SynologyPhotoAlbumEditKind.Create => "PhotosCreateAlbum", SynologyPhotoAlbumEditKind.Rename => "PhotosRenameAlbum", SynologyPhotoAlbumEditKind.Delete => "PhotosDeleteAlbum",
        SynologyPhotoAlbumEditKind.AddMembers => "PhotosAddToAlbum", SynologyPhotoAlbumEditKind.RemoveMembers => "PhotosRemoveFromAlbum", SynologyPhotoAlbumEditKind.Cover => "PhotosAlbumCover",
        SynologyPhotoAlbumEditKind.Sort => "PhotosAlbumSort", SynologyPhotoAlbumEditKind.ListSort => "PhotosAlbumListSort", SynologyPhotoAlbumEditKind.ListDisplay => "PhotosAlbumDisplay",
        SynologyPhotoAlbumEditKind.CreateCondition => "PhotosCreateConditionAlbum", SynologyPhotoAlbumEditKind.Condition => "PhotosEditConditionAlbum",
        SynologyPhotoAlbumEditKind.Unfreeze => "PhotosUnfreezeAlbum", _ => "PhotosRebuildAlbum",
    });
    private string AlbumListFieldTitle(SynologyPhotoAlbumListField field) => _l.Get(field switch
    {
        SynologyPhotoAlbumListField.Name => "PhotosAlbumName", SynologyPhotoAlbumListField.Type => "PhotosAlbumType", SynologyPhotoAlbumListField.StartTime => "PhotosSortDate",
        SynologyPhotoAlbumListField.Created => "PhotosAlbumCreated", SynologyPhotoAlbumListField.Sharing => "PhotosAlbumSharing", _ => "PhotosAlbumShareModified",
    });
    private static string AlbumErrorKey(Exception error) => error is PhotoEditInputException input ? input.Key :
        error is SynologyPhotoException { Failure: SynologyPhotoFailure.DeletionUnverified } ? "PhotosAlbumRestricted" : ManagementErrorKey(error) switch
        {
            "PhotosEditPermission" => "PhotosAlbumPermission", "PhotosEditTargetChanged" => "PhotosAlbumTargetChanged", "PhotosEditBusy" => "PhotosAlbumBusy",
            "PhotosEditRecoveryUnavailable" => "PhotosAlbumRecoveryUnavailable", "PhotosEditUnavailable" => "PhotosAlbumUnavailable",
            "PhotosUploadSignInAgain" => "PhotosUploadSignInAgain", _ => "PhotosAlbumFailed",
        };
    private void RenderAlbumControls()
    {
        RenderSharingControls();
        var supported = _model.Repository.SupportsAlbumManagement;
        PhotoAlbumSeparator.Visibility = Visible(supported && (_model.Repository.SupportsManagement || _model.Repository.SupportsUploads || _model.Repository.SupportsFileManagement));
        var menus = new[] { CreatePhotoAlbumMenu, RenamePhotoAlbumMenu, DeletePhotoAlbumMenu, AddPhotoAlbumMenu, RemovePhotoAlbumMenu, CoverPhotoAlbumMenu, SortPhotoAlbumMenu, SortAlbumListMenu, AlbumDisplayMenu };
        var kinds = Enum.GetValues<SynologyPhotoAlbumEditKind>();
        for (var index = 0; index < menus.Length; index++) { menus[index].Visibility = Visible(supported); menus[index].Text = AlbumEditTitle(kinds[index]); }
        PhotoAlbumChangesMenu.Visibility = Visible(supported); PhotoAlbumChangesMenu.Text = _l.Get("PhotosAlbumChanges"); PhotoAlbumHistoryButton.Content = _l.Get("PhotosAlbumChanges");
        var ready = !_managementPreparing && !_model.IsLoading && !_model.Deletion.IsBusy && _model.HasLoaded;
        var photos = SelectedManagementPhotos(); var selection = photos.Length == LibraryGrid.SelectedItems.Count && photos.Length <= 100;
        CreatePhotoAlbumMenu.IsEnabled = ready && selection;
        RenamePhotoAlbumMenu.IsEnabled = SortPhotoAlbumMenu.IsEnabled = ready && SelectedAlbumId() is not null;
        DeletePhotoAlbumMenu.IsEnabled = RenamePhotoAlbumMenu.IsEnabled && _model.Repository.AlbumSafety.Delete;
        ToolTipService.SetToolTip(DeletePhotoAlbumMenu, _l.Get(_model.Repository.AlbumSafety.Delete ? "PhotosDeleteAlbum" : "PhotosAlbumRestricted"));
        AddPhotoAlbumMenu.IsEnabled = ready && selection && photos.Length > 0;
        RemovePhotoAlbumMenu.IsEnabled = ready && selection && photos.Length > 0 && _model.CurrentAlbum is { Conditional: false, Frozen: false };
        CoverPhotoAlbumMenu.IsEnabled = ready && selection && photos.Length == 1 && _model.CurrentAlbum is { IsOwner: true };
        SortAlbumListMenu.IsEnabled = ready && _model.AlbumListScope is not null;
        AlbumDisplayMenu.IsEnabled = ready && _model.AlbumListScope == SynologyPhotoAlbumListScope.Albums;
        var conditionMenus = new[] { CreateConditionAlbumMenu, EditConditionAlbumMenu, UnfreezeAlbumMenu, RebuildAlbumMenu };
        var conditionKinds = new[] { SynologyPhotoAlbumEditKind.CreateCondition, SynologyPhotoAlbumEditKind.Condition, SynologyPhotoAlbumEditKind.Unfreeze, SynologyPhotoAlbumEditKind.Rebuild };
        for (var index = 0; index < conditionMenus.Length; index++) { conditionMenus[index].Visibility = Visible(supported); conditionMenus[index].Text = AlbumEditTitle(conditionKinds[index]); }
        CreateConditionAlbumMenu.IsEnabled = ready && _model.ConditionSpaces.Count > 0;
        EditConditionAlbumMenu.IsEnabled = ready && SelectedAlbumId() is not null && (_model.CurrentAlbum is null || _model.CurrentAlbum is { IsOwner: true, Conditional: true, Frozen: false });
        var frozen = ready && SelectedAlbumId() is not null && (_model.CurrentAlbum is null || _model.CurrentAlbum is { IsOwner: true, Frozen: true });
        UnfreezeAlbumMenu.IsEnabled = frozen && _model.Repository.AlbumSafety.Unfreeze; RebuildAlbumMenu.IsEnabled = frozen && _model.Repository.AlbumSafety.Rebuild;
        ToolTipService.SetToolTip(UnfreezeAlbumMenu, _l.Get(_model.Repository.AlbumSafety.Unfreeze ? "PhotosUnfreezeAlbum" : "PhotosAlbumRestricted"));
        ToolTipService.SetToolTip(RebuildAlbumMenu, _l.Get(_model.Repository.AlbumSafety.Rebuild ? "PhotosRebuildAlbum" : "PhotosAlbumRestricted"));
    }
    private async void CreatePhotoAlbum_Click(object sender, RoutedEventArgs args) => await ShowAlbumEditAsync(new(SynologyPhotoAlbumEditKind.Create) { Photos = SelectedManagementPhotos() });
    private async void RenamePhotoAlbum_Click(object sender, RoutedEventArgs args) => await ShowAlbumEditAsync(new(SynologyPhotoAlbumEditKind.Rename), SelectedAlbumId());
    private async void DeletePhotoAlbum_Click(object sender, RoutedEventArgs args) => await ShowAlbumEditAsync(new(SynologyPhotoAlbumEditKind.Delete), SelectedAlbumId());
    private async void AddPhotoAlbum_Click(object sender, RoutedEventArgs args) => await ShowAlbumEditAsync(new(SynologyPhotoAlbumEditKind.AddMembers) { Photos = SelectedManagementPhotos() });
    private async void RemovePhotoAlbum_Click(object sender, RoutedEventArgs args) => await ShowAlbumEditAsync(new(SynologyPhotoAlbumEditKind.RemoveMembers) { Photos = SelectedManagementPhotos() }, _model.Album?.Id);
    private async void CoverPhotoAlbum_Click(object sender, RoutedEventArgs args) => await ShowAlbumEditAsync(new(SynologyPhotoAlbumEditKind.Cover) { Photos = SelectedManagementPhotos() }, _model.Album?.Id);
    private async void SortPhotoAlbum_Click(object sender, RoutedEventArgs args) => await ShowAlbumEditAsync(new(SynologyPhotoAlbumEditKind.Sort), SelectedAlbumId());
    private async void SortAlbumList_Click(object sender, RoutedEventArgs args)
    { if (_model.AlbumListScope is { } scope) await ShowAlbumEditAsync(new(SynologyPhotoAlbumEditKind.ListSort) { Scope = scope }); }
    private async void AlbumDisplay_Click(object sender, RoutedEventArgs args) => await ShowAlbumEditAsync(new(SynologyPhotoAlbumEditKind.ListDisplay));
    private async void PhotoAlbumChanges_Click(object sender, RoutedEventArgs args) => await ShowAlbumChangesAsync();

    private async Task ShowAlbumEditAsync(SynologyPhotoAlbumEdit initial, long? albumId = null, Guid? resumeId = null)
    {
        if (_disposed || _dialog is not null || _managementPreparing || !_model.Repository.SupportsAlbumManagement) return;
        var kind = initial.Kind; var needsName = kind is SynologyPhotoAlbumEditKind.Create or SynologyPhotoAlbumEditKind.Rename;
        var chooseAlbum = kind == SynologyPhotoAlbumEditKind.AddMembers && resumeId is null;
        var listFields = Enum.GetValues<SynologyPhotoAlbumListField>().Where(field => initial.Scope == SynologyPhotoAlbumListScope.Albums
            ? field != SynologyPhotoAlbumListField.ShareModified : field is not (SynologyPhotoAlbumListField.Created or SynologyPhotoAlbumListField.Sharing)).ToArray();
        _managementPreparing = true; RenderManagementControls();
        var generation = _viewGeneration; var closed = false; var busy = false; var submitting = false; var ready = false;
        var edit = initial; var id = resumeId ?? Guid.NewGuid(); SynologyPhotoAlbumChange? submitted = null;
        var name = new TextBox { Header = _l.Get("PhotosAlbumName"), Text = initial.Name ?? "", MaxLength = 255, Visibility = Visible(needsName) };
        var target = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var names = new ItemsControl { ItemsSource = initial.Photos.Select(photo => photo.Filename).ToArray(), ItemTemplate = (DataTemplate)Resources["PhotoUploadItemTemplate"] };
        var selectedNames = new ScrollViewer { Content = names, MaxHeight = 120, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Visibility = Visible(initial.Photos.Count > 0) };
        AutomationProperties.SetName(names, _l.Get("PhotosSelectedFiles"));
        var albums = new ListView { DisplayMemberPath = nameof(SynologyPhotoCollection.Name), SelectionMode = ListViewSelectionMode.Single, MaxHeight = 180, Visibility = Visible(chooseAlbum) };
        AutomationProperties.SetName(albums, _l.Get("PhotosChooseAlbum"));
        var field = new ComboBox { Header = _l.Get("PhotosSortBy"), HorizontalAlignment = HorizontalAlignment.Stretch,
            ItemsSource = kind == SynologyPhotoAlbumEditKind.ListSort ? listFields.Select(AlbumListFieldTitle).ToArray() : Enum.GetValues<SynologyPhotoSortField>().Select(PhotoSortTitle).ToArray(),
            Visibility = Visible(kind is SynologyPhotoAlbumEditKind.Sort or SynologyPhotoAlbumEditKind.ListSort) };
        var direction = new ComboBox { Header = _l.Get("PhotosSortDirection"), HorizontalAlignment = HorizontalAlignment.Stretch,
            ItemsSource = new[] { _l.Get("PhotosSortAscending"), _l.Get("PhotosSortDescending") }, Visibility = field.Visibility };
        var display = new ComboBox { Header = _l.Get("PhotosAlbumDisplay"), HorizontalAlignment = HorizontalAlignment.Stretch,
            ItemsSource = new[] { _l.Get("PhotosAlbumsAll"), _l.Get("PhotosAlbumsMine") }, Visibility = Visible(kind == SynologyPhotoAlbumEditKind.ListDisplay) };
        var risk = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = kind == SynologyPhotoAlbumEditKind.Delete ? _l.Get("PhotosAlbumDeleteRisk") :
            kind == SynologyPhotoAlbumEditKind.RemoveMembers ? _l.Get("PhotosAlbumRemoveRisk") : resumeId is not null && needsName && initial.Name is null ? _l.Get("PhotosAlbumReenterName") : "" };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; var retry = QueueButton("PhotosRetry"); var more = QueueButton("PhotosLoadOlder");
        var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 10 };
        foreach (var child in new FrameworkElement[] { target, selectedNames, name, albums, more, field, direction, display, risk, progress, message, retry }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = AlbumEditTitle(kind), PrimaryButtonText = AlbumEditTitle(kind),
            CloseButtonText = _l.Get("PhotosCancel"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false,
            Content = new ScrollViewer { Content = panel, MaxHeight = 560 } };
        var rows = new List<SynologyPhotoCollection>(); var hasMore = false; var listing = false;
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        SynologyPhotoAlbumEdit Input() => edit with
        {
            Name = needsName ? name.Text : null,
            Sort = kind == SynologyPhotoAlbumEditKind.Sort && field.SelectedIndex >= 0 ? new((SynologyPhotoSortField)field.SelectedIndex, direction.SelectedIndex == 1) : edit.Sort,
            ListSort = kind == SynologyPhotoAlbumEditKind.ListSort && field.SelectedIndex >= 0 ? new(listFields[field.SelectedIndex], direction.SelectedIndex == 1) : edit.ListSort,
            Display = kind == SynologyPhotoAlbumEditKind.ListDisplay && display.SelectedIndex >= 0 ? (SynologyPhotoAlbumDisplay)display.SelectedIndex : edit.Display,
        };
        void RenderForm()
        {
            if (!Current()) return;
            target.Text = edit.Album?.Name ?? ""; target.Visibility = Visible(target.Text.Length > 0);
            foreach (var control in new Control[] { name, albums, field, direction, display, retry, more }) control.IsEnabled = !busy;
            if (resumeId is not null) { field.IsEnabled = direction.IsEnabled = display.IsEnabled = false; name.IsEnabled = !busy && initial.Name is null; }
            dialog.IsPrimaryButtonEnabled = !busy && ready && (!needsName || !string.IsNullOrWhiteSpace(name.Text)) &&
                (kind is not (SynologyPhotoAlbumEditKind.Sort or SynologyPhotoAlbumEditKind.ListSort) || field.SelectedIndex >= 0 && direction.SelectedIndex >= 0);
            more.Visibility = Visible(chooseAlbum && hasMore); retry.Visibility = Visible(!ready || chooseAlbum);
            progress.IsActive = busy; progress.Visibility = Visible(busy);
        }
        async Task Load(bool append = false, long? selectedAlbum = null)
        {
            if (!Current() || busy) return; busy = true; ready = false; message.Text = _l.Get("PhotosLoadingDescription"); RenderForm();
            try
            {
                if (chooseAlbum && selectedAlbum is null)
                {
                    var page = await _model.Repository.AddableAlbumsAsync(append ? rows.Count : 0, 100, _viewCancellation.Token);
                    if (!Current()) return;
                    var seen = append ? rows.Select(row => row.Id).ToHashSet() : [];
                    if (page.Count > 100 || page.Any(row => row.Id <= 0 || !seen.Add(row.Id))) throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
                    if (!append) { rows.Clear(); edit = edit with { Album = null }; }
                    rows.AddRange(page); hasMore = page.Count == 100; listing = true; albums.ItemsSource = rows.ToArray(); listing = false;
                    message.Text = _l.Get(rows.Count == 0 ? "PhotosAlbumsAddEmpty" : "PhotosChooseAlbum");
                    return;
                }
                if (resumeId is null && (selectedAlbum ?? albumId) is { } targetId)
                {
                    var album = await _model.Repository.AlbumAsync(targetId, _viewCancellation.Token);
                    if (!Current()) return; edit = edit with { Album = album, Sort = kind == SynologyPhotoAlbumEditKind.Sort ? album.Sort : null };
                    if (kind == SynologyPhotoAlbumEditKind.Rename) name.Text = album.Name;
                }
                if (kind == SynologyPhotoAlbumEditKind.ListSort)
                {
                    var sort = resumeId is null ? await _model.Repository.AlbumListSortAsync(initial.Scope, _viewCancellation.Token) : initial.OriginalListSort!;
                    if (!Current()) return; edit = edit with { OriginalListSort = sort, ListSort = initial.ListSort ?? sort };
                    field.SelectedIndex = Array.IndexOf(listFields, edit.ListSort!.Field); direction.SelectedIndex = edit.ListSort.Descending ? 1 : 0;
                }
                else if (kind == SynologyPhotoAlbumEditKind.Sort)
                { field.SelectedIndex = (int)edit.Sort!.Field; direction.SelectedIndex = edit.Sort.Descending ? 1 : 0; }
                else if (kind == SynologyPhotoAlbumEditKind.ListDisplay)
                {
                    var value = resumeId is null ? await _model.Repository.AlbumDisplayAsync(_viewCancellation.Token) : initial.OriginalDisplay!.Value;
                    if (!Current()) return; edit = edit with { OriginalDisplay = value, Display = initial.Display ?? value }; display.SelectedIndex = (int)edit.Display.Value;
                }
                if (resumeId is null && (!needsName || !string.IsNullOrWhiteSpace(name.Text)))
                    await _model.Repository.PrepareAlbumAsync(Input(), _viewCancellation.Token);
                if (!Current()) return; ready = true; message.Text = "";
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(AlbumErrorKey(error)); }
            finally { busy = false; RenderForm(); }
        }
        name.TextChanged += (_, _) => RenderForm(); field.SelectionChanged += (_, _) => RenderForm(); direction.SelectionChanged += (_, _) => RenderForm(); display.SelectionChanged += (_, _) => RenderForm();
        albums.SelectionChanged += async (_, _) => { if (!listing && albums.SelectedItem is SynologyPhotoCollection album) await Load(selectedAlbum: album.Id); };
        more.Click += async (_, _) => await Load(append: true); retry.Click += async (_, _) => await Load();
        dialog.Closing += (_, args) => { if (submitting && Current() && _windowVisible && IsLoaded) args.Cancel = true; };
        dialog.Closed += (_, _) => closed = true;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (!Current() || busy || !dialog.IsPrimaryButtonEnabled) return;
            var deferral = args.GetDeferral(); busy = submitting = true; RenderForm();
            try
            {
                submitted = await _model.Repository.EditAlbumAsync(id, Input());
                if (resumeId is not null && submitted.CanContinue) submitted = await _model.Repository.ContinueAlbumChangeAsync(id);
                if (Current()) args.Cancel = false;
            }
            catch (Exception error)
            {
                if (Current()) message.Text = _l.Get(resumeId is not null && needsName && initial.Name is null &&
                    error is SynologyPhotoException { Failure: SynologyPhotoFailure.TargetChanged } ? "PhotosAlbumNameMismatch" : AlbumErrorKey(error));
            }
            finally { busy = submitting = false; RenderForm(); deferral.Complete(); }
        };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); RenderForm(); var showing = ShowPhotoDialogAsync(dialog); await Load(); await showing; }
        finally { closed = true; _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); }
        if (submitted is not null && !_disposed && generation == _viewGeneration)
        {
            if (submitted.Pending || submitted.Members.Any(member => member.State == SynologyPhotoChangeState.Completed)) _pendingAlbumChanges.Add(submitted.Id);
            await _model.ApplyAlbumChangeAsync(submitted);
            if (!_disposed && _windowVisible) await ShowAlbumChangesAsync(submitted.Id);
        }
    }
}
