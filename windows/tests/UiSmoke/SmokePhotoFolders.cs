using LanStash.App.Features.Photos.Synology;
using LanStash.App.Features.Transfers;
using LanStash.App.Views;
using LanStash.App.Views.Photos;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal sealed partial class SmokePhotosRepository
{
    public bool SupportsFolderManagement => State.StartsWith("folder-", StringComparison.Ordinal);
    internal bool EditingFolder;
    internal int FolderWrites, FolderContinues, FolderReviews;
    internal readonly TaskCompletionSource FolderRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal SynologyPhotoFolderEdit? SubmittedFolder;
    private List<SynologyPhotoFolderChange>? _folderChanges;
    public async Task<SynologyPhotoFolder> FolderAsync(long? id, SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    {
        if (State.StartsWith("file-", StringComparison.Ordinal)) return await FileFolderAsync(id, space);
        if (State is "fperm-parent" or "fperm-second" && id == 2) return SyntheticFolderSharing.Folder;
        if (EditingFolder && State is "folder-loading" or "folder-cover-loading") await FolderRelease.Task;
        if (EditingFolder && State is "folder-error" or "folder-cover-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return new(space, id ?? 1, id is null or 1 ? 0 : id == 4 ? 2 : 1, id is null or 1 ? "/" : id == 4 ? "/Synthetic folder/Child" : "/Synthetic folder") { Sort = new() };
    }
    public async Task<IReadOnlyList<byte[]>> FolderCoverImagesAsync(SynologyPhotoCollection folder, CancellationToken cancellationToken = default) =>
        [await ThumbnailAsync(new(new(ProfileId, folder.Space, 1), "synthetic.jpg", 1, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, folder.Id, "photo"), cancellationToken: cancellationToken)];
    public Task<IReadOnlyList<SynologyPhotoCollection>> FoldersAsync(long parentId, int offset, int limit, bool descending,
        CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) => FoldersAsync(parentId, offset, limit, cancellationToken, space);
    public Task<SynologyPhotoFolderChange> EditFolderAsync(Guid operationId, SynologyPhotoFolderEdit edit, CancellationToken cancellationToken = default)
    {
        FolderWrites++; SubmittedFolder = edit;
        var result = edit.Kind == SynologyPhotoFolderEditKind.Create ? new SynologyPhotoFolder(edit.Folder.Space, 30, edit.Folder.Id, "/Synthetic new folder") :
            edit.Kind == SynologyPhotoFolderEditKind.Rename ? edit.Folder with { Path = "/" + edit.Name } : edit.Folder with { Sort = edit.Sort };
        var change = new SynologyPhotoFolderChange(operationId, edit, SynologyPhotoChangeState.Completed, result, null, false, false);
        (_folderChanges ??= []).Add(change); return Task.FromResult(change);
    }
    public Task<IReadOnlyList<SynologyPhotoFolderChange>> FolderChangesAsync(CancellationToken cancellationToken = default)
    {
        _folderChanges ??= State == "folder-history-empty" ? [] : [new(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Rename,
            new(SynologyPhotoSpace.Personal, 2, 1, "/Synthetic folder")) { Name = "Synthetic new folder" },
            State == "folder-history-unknown" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, null,
            State == "folder-history-unknown" ? null : SynologyPhotoFailure.Permission, false, State != "folder-history-unknown")];
        return Task.FromResult<IReadOnlyList<SynologyPhotoFolderChange>>(_folderChanges.ToArray());
    }
    public async Task<SynologyPhotoFolderChange> ReviewFolderChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    { FolderReviews++; return (await FolderChangesAsync()).Single(change => change.Id == operationId); }
    public async Task<SynologyPhotoFolderChange> ContinueFolderChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await FolderChangesAsync(); FolderContinues++; var index = _folderChanges!.FindIndex(change => change.Id == operationId);
        return _folderChanges[index] = _folderChanges[index] with { State = SynologyPhotoChangeState.Completed, CanContinue = false };
    }
    public async Task<SynologyPhotoFolderChange> CancelFolderChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await FolderChangesAsync(); var index = _folderChanges!.FindIndex(change => change.Id == operationId);
        return _folderChanges[index] = _folderChanges[index] with { State = SynologyPhotoChangeState.Cancelled, CanContinue = false };
    }
}
internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoFolderManagementAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repository = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repository, new WindowsTransferSavePicker(() => null));
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        await model.SelectSectionAsync(SynologyPhotosSection.Folders); await Task.Delay(100); repository.EditingFolder = true;
        var cover = state.StartsWith("folder-cover", StringComparison.Ordinal);
        if (state is "folder-rename" or "folder-submit" || cover)
        {
            typeof(SynologyPhotosPage).GetMethod("SetPhotoSelection", flags)!.Invoke(page, [true]);
            var grid = (GridView)page.FindName("LibraryGrid"); grid.SelectedItems.Add(grid.Items.OfType<SynologyPhotoCell>().First(cell => cell.Collection is not null));
        }
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        var history = state.StartsWith("folder-history-", StringComparison.Ordinal);
        var menuName = history ? "PhotoFolderChangesMenu" : cover ? "CoverPhotoFolderMenu" : state == "folder-sort" ? "SortPhotoFolderMenu" : state is "folder-rename" or "folder-submit" ? "RenamePhotoFolderMenu" : "CreatePhotoFolderMenu";
        var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
        var menu = (MenuFlyoutItem)page.FindName(menuName);
        if (!menu.IsEnabled || menu.Visibility != Visibility.Visible) throw new InvalidOperationException("目录菜单不可用。");
        ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        try
        {
            await Task.Delay(300); var dialog = Dialog() ?? throw new InvalidOperationException("目录菜单没有打开原生表单。"); var l = Localization.LocalizationService.Current;
            if (cover)
            {
                var list = Nodes(dialog).OfType<ListView>().Single();
                if (state == "folder-cover-subfolder")
                {
                    list.SelectedItem = list.Items.OfType<SynologyPhotoCell>().First(cell => cell.Collection is not null);
                    Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, l.Get("PhotosOpenFolder")))); await Task.Delay(180);
                }
                if (state is "folder-cover" or "folder-cover-submit" or "folder-cover-subfolder")
                {
                    list.SelectedItem = list.Items.OfType<SynologyPhotoCell>().First(cell => cell.Photo is not null);
                    if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("已选封面照片仍不可保存。");
                    for (var attempt = 0; attempt < 40 && !Nodes(dialog).OfType<Image>().Any(image => image.Source is not null && image.Visibility == Visibility.Visible); attempt++) await Task.Delay(30);
                    if (!Nodes(dialog).OfType<Image>().Any(image => image.Source is not null && image.Visibility == Visibility.Visible)) throw new InvalidOperationException("所选封面缺少可见预览。");
                }
                else if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("无有效照片时仍可保存封面。");
                if (state is "folder-cover-submit" or "folder-cover-subfolder")
                {
                    Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText)));
                    for (var attempt = 0; attempt < 80 && !Equals(Dialog()?.Title, l.Get("PhotosFolderChanges")); attempt++) await Task.Delay(30);
                    dialog = Dialog() ?? throw new InvalidOperationException("封面保存后未显示结果。"); await Task.Delay(180);
                    if (repository.FolderWrites != 1 || repository.SubmittedFolder is not { Kind: SynologyPhotoFolderEditKind.Cover, Folder.Id: 2 } ||
                        repository.SubmittedFolder.Photo?.FolderId != (state == "folder-cover-subfolder" ? 4 : 2)) throw new InvalidOperationException("封面选择器改变了原目标目录。");
                }
            }
            if (!history && !cover && state is not ("folder-loading" or "folder-error"))
            {
                if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("目录表单没有加载。");
                if (state != "folder-sort") Nodes(dialog).OfType<TextBox>().Single().Text = "Synthetic new folder";
                else if (Nodes(dialog).OfType<ComboBox>().Count() != 2) throw new InvalidOperationException("缺少排序字段或方向。");
                if (state == "folder-submit")
                {
                    Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText)));
                    for (var attempt = 0; attempt < 80 && !Equals(Dialog()?.Title, l.Get("PhotosFolderChanges")); attempt++) await Task.Delay(30);
                    dialog = Dialog() ?? throw new InvalidOperationException("保存目录后未显示结果。"); await Task.Delay(200);
                    if (repository.FolderWrites != 1 || repository.SubmittedFolder is not { Kind: SynologyPhotoFolderEditKind.Rename, Name: "Synthetic new folder", Folder.Id: 2 })
                        throw new InvalidOperationException("目录表单没有提交固定目标。");
                }
            }
            if (state is "folder-history-unknown" or "folder-history-resume")
            {
                Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, l.Get(state == "folder-history-unknown" ? "PhotosRefresh" : "PhotosContinueChanges"))));
                await Task.Delay(100);
                if (state == "folder-history-unknown" ? repository.FolderReviews != 1 || repository.FolderContinues != 0 : repository.FolderContinues != 1)
                    throw new InvalidOperationException("目录记录恢复动作不匹配。");
            }
            dialog.UpdateLayout(); if (dialog.ActualWidth <= 0 || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("目录窗口布局或主题不正确。");
            foreach (var control in Nodes(dialog).OfType<Control>().Where(control => control.Visibility == Visibility.Visible && control.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("目录控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); MarkSnapshotComplete();
        }
        finally { repository.FolderRelease.TrySetResult(); Dialog()?.Hide(); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(value); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, i))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
