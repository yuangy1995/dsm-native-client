using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private SynologyPhotoCollection[] SelectedFileFolders() => _model.Section == SynologyPhotosSection.Folders
        ? LibraryGrid.SelectedItems.OfType<SynologyPhotoCell>().Select(cell => cell.Collection).OfType<SynologyPhotoCollection>().ToArray() : [];
    private void RenderFileControls()
    {
        var supported = _model.Repository.SupportsFileManagement;
        CopyPhotoFilesMenu.Visibility = MovePhotoFilesMenu.Visibility = DeletePhotoFilesMenu.Visibility = PhotoFileChangesMenu.Visibility = Visible(supported);
        CopyPhotoFilesMenu.Text = _l.Get("PhotosCopyFiles"); MovePhotoFilesMenu.Text = _l.Get("PhotosMoveFiles");
        DeletePhotoFilesMenu.Text = _l.Get("PhotosDeleteFiles");
        PhotoFileHistoryButton.Content = _l.Get("PhotosFileChanges"); PhotoFileChangesMenu.Text = _l.Get("PhotosFileChanges");
        var photos = SelectedManagementPhotos(); var folders = SelectedFileFolders();
        var spaces = photos.Select(photo => photo.Id.Space).Concat(folders.Select(folder => folder.Space)).Distinct().ToArray();
        var ready = !_managementPreparing && !_model.IsLoading && !_model.Deletion.IsBusy && photos.Length + folders.Length > 0 &&
            photos.Length + folders.Length == LibraryGrid.SelectedItems.Count && spaces.Length == 1;
        CopyPhotoFilesMenu.IsEnabled = MovePhotoFilesMenu.IsEnabled = ready;
        DeletePhotoFilesMenu.IsEnabled = ready && _model.Repository.CanDeleteOriginals && (_model.Repository.FileSafety.ExtendedDeletion ||
            photos.Length == 1 && folders.Length == 0 && spaces[0] == SynologyPhotoSpace.Personal);
        ToolTipService.SetToolTip(DeletePhotoFilesMenu, _l.Get(DeletePhotoFilesMenu.IsEnabled ? "PhotosDeleteFiles" : "PhotosDeleteUnverified"));
    }
    private async void CopyPhotoFiles_Click(object sender, RoutedEventArgs args) => await ShowSelectedFilesAsync(SynologyPhotoFileAction.Copy);
    private async void MovePhotoFiles_Click(object sender, RoutedEventArgs args) => await ShowSelectedFilesAsync(SynologyPhotoFileAction.Move);
    private async void DeletePhotoFiles_Click(object sender, RoutedEventArgs args) => await ShowSelectedFilesAsync(SynologyPhotoFileAction.Delete);
    private async void PhotoFileChanges_Click(object sender, RoutedEventArgs args) => await ShowFileChangesAsync();
    private string FileActionTitle(SynologyPhotoFileAction action) => _l.Get(action switch
    { SynologyPhotoFileAction.Copy => "PhotosCopyFiles", SynologyPhotoFileAction.Move => "PhotosMoveFiles", _ => "PhotosDeleteFiles" });
    private string FileSelectionText(SynologyPhotoFileCommand command) => _l.Format("PhotosFileSelection", command.Photos.Count, command.Folders.Count);
    private static string FileErrorKey(Exception error) => error is SynologyPhotoException { Failure: SynologyPhotoFailure.DeletionUnverified }
        ? "PhotosFileUnavailable" : ManagementErrorKey(error) switch
    {
        "PhotosEditPermission" => "PhotosFilePermission", "PhotosEditTargetChanged" => "PhotosFileTargetChanged",
        "PhotosEditBusy" => "PhotosFileBusy", "PhotosEditRecoveryUnavailable" => "PhotosFileRecoveryUnavailable",
        "PhotosEditUnavailable" => "PhotosFileUnavailable", "PhotosUploadSignInAgain" => "PhotosUploadSignInAgain", _ => "PhotosFileFailed",
    };
    private string FileTargetText(SynologyPhotoFolder folder) => _l.Format("PhotosFileTarget",
        _l.Get(folder.Space == SynologyPhotoSpace.Personal ? "PhotosSourcePersonal" : "PhotosSourceShared"), folder.Path);
    private async Task ShowSelectedFilesAsync(SynologyPhotoFileAction action)
    {
        if (_disposed || _dialog is not null || _managementPreparing) return;
        var photos = SelectedManagementPhotos(); var selected = SelectedFileFolders();
        if (photos.Length + selected.Length == 0 || photos.Length + selected.Length != LibraryGrid.SelectedItems.Count) return;
        var spaces = photos.Select(photo => photo.Id.Space).Concat(selected.Select(folder => folder.Space)).Distinct().ToArray();
        if (spaces.Length != 1) return;
        // 列表中的目录身份冻结在表单中；提交前仍由 Repository 重新读取权限及原目标。
        if (selected.Any(folder => folder.ParentId is null || folder.Path is null)) { ShowSaveMessage("PhotosFileTargetChanged", true); return; }
        var folders = selected.Select(folder => new SynologyPhotoFolder(folder.Space, folder.Id, folder.ParentId!.Value, folder.Path!)).ToArray();
        await ShowFileCommandAsync(new(action, spaces[0], photos, folders));
    }

    private async Task ShowFileCommandAsync(SynologyPhotoFileCommand original, Guid? resumeId = null, Func<Task>? beforeSubmit = null)
    {
        if (_disposed || _dialog is not null || _managementPreparing) return;
        _managementPreparing = true; RenderManagementControls();
        var generation = _viewGeneration; var closed = false; var busy = false; var submitting = false;
        var command = original; var id = resumeId ?? Guid.NewGuid(); SynologyPhotoFileChange? submitted = null;
        var transfer = original.Action != SynologyPhotoFileAction.Delete; var browse = transfer && resumeId is null;
        var selection = new TextBlock { Text = FileSelectionText(original), TextWrapping = TextWrapping.Wrap };
        var names = new ListView { ItemsSource = original.Folders.Select(folder => folder.Name).Concat(original.Photos.Select(photo => photo.Filename)).ToArray(),
            SelectionMode = ListViewSelectionMode.None, MaxHeight = 130 };
        AutomationProperties.SetName(names, _l.Get("PhotosSelectedFiles"));
        var source = new ComboBox { Header = _l.Get("PhotosChooseSource"), HorizontalAlignment = HorizontalAlignment.Stretch };
        var spaces = _model.Spaces.Where(space => original.Action == SynologyPhotoFileAction.Copy || space == original.Space ||
            _model.Repository.FileSafety.CrossSpaceMove && original.Space == SynologyPhotoSpace.Personal).ToArray();
        if (!spaces.Contains(original.Space)) spaces = [original.Space, .. spaces];
        source.ItemsSource = spaces.Select(space => _l.Get(space == SynologyPhotoSpace.Personal ? "PhotosSourcePersonal" : "PhotosSourceShared")).ToArray();
        source.SelectedIndex = Array.IndexOf(spaces, original.Space); source.Visibility = Visible(browse && spaces.Length > 1);
        var location = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var list = new ListView { DisplayMemberPath = nameof(SynologyPhotoCollection.Name), SelectionMode = ListViewSelectionMode.Single, MaxHeight = 200 };
        AutomationProperties.SetName(list, _l.Get("PhotosChooseDestination"));
        var back = QueueButton("PhotosBack"); var open = QueueButton("PhotosOpenFolder"); var more = QueueButton("PhotosLoadOlder"); var refresh = QueueButton("PhotosRefresh");
        var navigation = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; navigation.Children.Add(back); navigation.Children.Add(open); navigation.Children.Add(refresh);
        var duplicate = new ComboBox { Header = _l.Get("PhotosFileDuplicate"), ItemsSource = new[] { _l.Get("PhotosFileSkip"), _l.Get("PhotosFileOverwrite") }, SelectedIndex = (int)original.Duplicate,
            HorizontalAlignment = HorizontalAlignment.Stretch, Visibility = Visible(browse && _model.Repository.FileSafety.Overwrite) };
        var risk = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 10 };
        foreach (var child in new FrameworkElement[] { selection, names, source, location, navigation, list, more, duplicate, risk, progress, message }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = FileActionTitle(original.Action),
            PrimaryButtonText = _l.Get(original.Action switch { SynologyPhotoFileAction.Copy => "PhotosCopyHere", SynologyPhotoFileAction.Move => "PhotosMoveHere", _ => "PhotosDeleteFiles" }),
            CloseButtonText = _l.Get("PhotosCancel"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false,
            Content = new ScrollViewer { Content = panel, MaxHeight = 550, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        var history = new List<SynologyPhotoFolder>(); var rows = new List<SynologyPhotoCollection>(); var hasMore = false;
        var destinationReady = false;
        var duplicateReady = !browse;
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        bool Allowed(SynologyPhotoFolder target) => target.Space != original.Space ||
            !original.Photos.Any(photo => photo.FolderId == target.Id) && !original.Folders.Any(folder => folder.ParentId == target.Id ||
                target.Id == folder.Id || target.Path.StartsWith(folder.Path.TrimEnd('/') + "/", StringComparison.Ordinal));
        void RenderForm()
        {
            if (!Current()) return;
            location.Text = command.Destination is { } target ? FileTargetText(target) : "";
            location.Visibility = Visible(transfer);
            list.Visibility = navigation.Visibility = Visible(browse); more.Visibility = Visible(browse && hasMore);
            source.IsEnabled = list.IsEnabled = !busy; duplicate.IsEnabled = !busy && duplicateReady;
            back.IsEnabled = !busy && history.Count > 1; open.IsEnabled = !busy && list.SelectedItem is SynologyPhotoCollection;
            refresh.IsEnabled = more.IsEnabled = !busy;
            dialog.IsPrimaryButtonEnabled = !busy && duplicateReady && (browse ? destinationReady && command.Destination is { } folder && Allowed(folder) : destinationReady);
            risk.Text = !transfer ? _l.Get("PhotosFileDeleteRisk") : string.Join(Environment.NewLine,
                new[] { original.Action == SynologyPhotoFileAction.Move ? _l.Get("PhotosFileMoveRisk") : null,
                    command.Destination?.Space == SynologyPhotoSpace.Shared && original.Space != SynologyPhotoSpace.Shared ? _l.Get("PhotosFileSharedRisk") : null,
                    command.Duplicate == SynologyPhotoFileDuplicate.Overwrite ? _l.Get("PhotosFileOverwriteRisk") : duplicate.Visibility == Visibility.Visible ? null : _l.Get("PhotosFileSkipDescription") }.OfType<string>());
            progress.IsActive = busy; progress.Visibility = Visible(busy);
        }
        async Task Load(SynologyPhotoFolder? target, bool append = false, bool goBack = false)
        {
            if (!Current() || busy) return; busy = true; destinationReady = false; message.Text = _l.Get("PhotosLoadingDescription"); RenderForm();
            try
            {
                if (!duplicateReady)
                {
                    var preferences = await _model.Repository.DuplicateSettingsAsync(_viewCancellation.Token);
                    if (!Current()) return;
                    command = command with { Duplicate = preferences.Transfer }; duplicate.SelectedIndex = (int)preferences.Transfer; duplicateReady = true;
                }
                var space = spaces[source.SelectedIndex];
                var folder = await _model.Repository.FolderAsync(target?.Id, space, _viewCancellation.Token);
                if (target is not null && (folder.Space != target.Space || folder.Id != target.Id || folder.ParentId != target.ParentId || folder.Path != target.Path))
                    throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                var page = await _model.Repository.FoldersAsync(folder.Id, append ? rows.Count : 0, 100, _viewCancellation.Token, space);
                var known = append ? rows.Select(row => row.Id).ToHashSet() : [];
                if (page.Count > 100 || page.Any(row => row.Space != space || row.ParentId != folder.Id || row.Path != folder.Path.TrimEnd('/') + "/" + row.Name || !known.Add(row.Id)))
                    throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
                if (!Current()) return;
                if (!append)
                {
                    rows.Clear();
                    if (target is null) history.Clear();
                    else if (goBack) history.RemoveAt(history.Count - 1);
                    if (history.Count == 0 || history[^1].Id != folder.Id) history.Add(folder);
                }
                rows.AddRange(page); hasMore = page.Count == 100; command = command with { Destination = folder };
                list.ItemsSource = rows.ToArray(); destinationReady = true;
                message.Text = !Allowed(folder) ? _l.Get("PhotosFileDestinationInvalid") : rows.Count == 0 ? _l.Get("PhotosFileFolderEmpty") : "";
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(FileErrorKey(error)); }
            finally { busy = false; RenderForm(); }
        }
        list.SelectionChanged += (_, _) => RenderForm();
        source.SelectionChanged += async (_, _) => { if (browse && Current()) await Load(null); };
        duplicate.SelectionChanged += (_, _) => { command = command with { Duplicate = (SynologyPhotoFileDuplicate)duplicate.SelectedIndex }; RenderForm(); };
        open.Click += async (_, _) => { if (list.SelectedItem is SynologyPhotoCollection { ParentId: { } parent, Path: { } path } folder) await Load(new(folder.Space, folder.Id, parent, path)); };
        back.Click += async (_, _) => { if (history.Count > 1) await Load(history[^2], goBack: true); };
        more.Click += async (_, _) => await Load(command.Destination, append: true);
        refresh.Click += async (_, _) => await Load(command.Destination);
        dialog.Closing += (_, args) => { if (submitting && Current() && _windowVisible && IsLoaded) args.Cancel = true; };
        dialog.Closed += (_, _) => closed = true;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (!Current() || busy || !dialog.IsPrimaryButtonEnabled) return;
            var deferral = args.GetDeferral(); busy = submitting = true; RenderForm();
            try
            {
                if (beforeSubmit is not null) await beforeSubmit();
                submitted = resumeId is { } resume ? await _model.Repository.ContinueFileChangeAsync(resume) : await _model.Repository.ChangeFilesAsync(id, command);
                if (Current()) args.Cancel = false;
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(FileErrorKey(error)); }
            finally { busy = submitting = false; RenderForm(); deferral.Complete(); }
        };
        try
        {
            SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); RenderForm(); var showing = ShowPhotoDialogAsync(dialog);
            if (browse) await Load(null);
            else
            {
                busy = true; RenderForm();
                try
                {
                    // 继续原操作使用原记录防重；新的删除在显示可确认按钮前完成只读预检。
                    if (resumeId is null) await _model.Repository.PrepareFilesAsync(command, _viewCancellation.Token);
                    destinationReady = true;
                }
                catch (Exception error) { if (Current()) message.Text = _l.Get(FileErrorKey(error)); }
                finally { busy = false; RenderForm(); }
            }
            await showing;
        }
        finally { closed = true; _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); }
        if (submitted is not null && !_disposed && generation == _viewGeneration)
        { await _model.ApplyFileChangeAsync(submitted); if (!_disposed && _windowVisible) await ShowFileChangesAsync(submitted.Id); }
    }
}
