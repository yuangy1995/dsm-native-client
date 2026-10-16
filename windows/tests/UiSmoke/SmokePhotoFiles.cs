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
    public bool SupportsFileManagement => State.StartsWith("file-", StringComparison.Ordinal) || State is "sim-cleanup-submit" or "sim-cleanup-cancel";
    public bool CanDeleteOriginals => SupportsFileManagement && State != "file-disable-all";
    public SynologyPhotoFileSafety FileSafety => State == "file-safety" ? new() : new(true, true, true);
    internal bool EditingFiles;
    internal int FileWrites, FileReviews, FileContinues;
    internal readonly TaskCompletionSource FileRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal SynologyPhotoFileCommand? SubmittedFiles;
    private List<SynologyPhotoFileChange>? _fileChanges;
    private async Task<SynologyPhotoFolder> FileFolderAsync(long? id, SynologyPhotoSpace space)
    {
        if (EditingFiles && State == "file-loading") await FileRelease.Task;
        if (EditingFiles && State == "file-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return new(space, id ?? 1, id is null or 1 ? 0 : 1, id is null or 1 ? "/" : id == 2 ? "/Synthetic folder" : id == 3 ? "/Synthetic destination" : $"/Synthetic-{id}");
    }
    private Task<IReadOnlyList<SynologyPhotoCollection>> FileFoldersAsync(long parent, int offset, int limit, SynologyPhotoSpace space) =>
        Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>(parent != 1 ? [] : Enumerable.Range(2, State == "file-pages" ? 101 : 2).Skip(offset).Take(limit)
            .Select(id => new SynologyPhotoCollection(id, id == 2 ? "Synthetic folder" : id == 3 ? "Synthetic destination" : $"Synthetic-{id}", 1)
            { Space = space, Path = id == 2 ? "/Synthetic folder" : id == 3 ? "/Synthetic destination" : $"/Synthetic-{id}" }).ToArray());
    public Task PrepareFilesAsync(SynologyPhotoFileCommand command, CancellationToken cancellationToken = default) => Task.CompletedTask;
    public Task<SynologyPhotoFileChange> ChangeFilesAsync(Guid operationId, SynologyPhotoFileCommand command, CancellationToken cancellationToken = default)
    {
        FileWrites++; SubmittedFiles = command;
        var total = command.Photos.Count + command.Folders.Count;
        var state = State == "file-unknown" ? SynologyPhotoFileState.PendingReview : State == "file-partial" ? SynologyPhotoFileState.Partial : SynologyPhotoFileState.Completed;
        var change = new SynologyPhotoFileChange(operationId, command, state, state == SynologyPhotoFileState.PendingReview ? null : new(total, total, state == SynologyPhotoFileState.Partial ? 1 : 0, 0, 0), null, false, false);
        (_fileChanges ??= []).Add(change); return Task.FromResult(change);
    }
    public Task<IReadOnlyList<SynologyPhotoFileChange>> FileChangesAsync(CancellationToken cancellationToken = default)
    {
        if (_fileChanges is null)
        {
            _fileChanges = [];
            if (State is "file-history-resume" or "file-history-cold" or "file-history-cancel" or "file-history-stale")
            {
                var photo = new SynologyPhoto(new(ProfileId, SynologyPhotoSpace.Personal, 1), "Sample-001.jpg", 2048,
                    new(2026, 9, 16, 0, 0, 0, TimeSpan.Zero), new(2026, 9, 16, 0, 0, 0, TimeSpan.Zero), 1, "photo");
                _fileChanges.Add(new(Guid.Parse("33333333-3333-3333-3333-333333333333"), new(State == "file-history-stale" ? SynologyPhotoFileAction.Delete : SynologyPhotoFileAction.Copy, SynologyPhotoSpace.Personal, [photo], [])
                { Destination = State == "file-history-stale" ? null : new(SynologyPhotoSpace.Personal, 3, 1, "/Synthetic destination") },
                    State == "file-history-stale" ? SynologyPhotoFileState.Completed : State == "file-history-cold" ? SynologyPhotoFileState.PendingReview : State == "file-history-cancel" ? SynologyPhotoFileState.Ready : SynologyPhotoFileState.Failed,
                    null, State == "file-history-resume" ? SynologyPhotoFailure.Permission : null, false, State is "file-history-resume" or "file-history-cancel"));
            }
        }
        return Task.FromResult<IReadOnlyList<SynologyPhotoFileChange>>(_fileChanges.ToArray());
    }
    public async Task<SynologyPhotoFileChange> ReviewFileChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await FileChangesAsync(); FileReviews++; var index = _fileChanges!.FindIndex(change => change.Id == operationId);
        if (State == "file-history-cold") _fileChanges[index] = _fileChanges[index] with { State = SynologyPhotoFileState.Completed, Counts = new(1, 1, 0, 0, 0) };
        return _fileChanges[index];
    }
    public async Task<SynologyPhotoFileChange> ContinueFileChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await FileChangesAsync(); FileContinues++; var index = _fileChanges!.FindIndex(change => change.Id == operationId);
        return _fileChanges[index] = _fileChanges[index] with { State = SynologyPhotoFileState.Completed, CanContinue = false, Counts = new(1, 1, 0, 0, 0) };
    }
    public async Task<SynologyPhotoFileChange> CancelFileChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await FileChangesAsync(); var index = _fileChanges!.FindIndex(change => change.Id == operationId);
        return _fileChanges[index] = _fileChanges[index] with { State = SynologyPhotoFileState.Cancelled, CanContinue = false };
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoFilesAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repository = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repository, new WindowsTransferSavePicker(() => null));
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        await model.SelectSectionAsync(SynologyPhotosSection.Folders); await Task.Delay(100); repository.EditingFiles = true;
        var l = Localization.LocalizationService.Current;
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        var history = state.StartsWith("file-history-", StringComparison.Ordinal);
        if (!history)
        {
            typeof(SynologyPhotosPage).GetMethod("SetPhotoSelection", flags)!.Invoke(page, [true]);
            var grid = (GridView)page.FindName("LibraryGrid");
            foreach (var cell in grid.Items.OfType<SynologyPhotoCell>().Where(cell => cell.Photo is not null).Take(state is "file-partial" or "file-safety" ? 2 : 1)) grid.SelectedItems.Add(cell);
            if (state is "file-mixed" or "file-safety") grid.SelectedItems.Add(grid.Items.OfType<SynologyPhotoCell>().First(cell => cell.Collection?.Id == 2));
        }
        var moreButton = (Button)page.FindName("MoreButton"); moreButton.Flyout.ShowAt(moreButton); await Task.Delay(100);
        if (state is "file-safety" or "file-disable-all")
        {
            if (((MenuFlyoutItem)page.FindName("DeletePhotoFilesMenu")).IsEnabled) throw new InvalidOperationException("扩展删除保护未生效。");
            if (state == "file-disable-all") { moreButton.Flyout.Hide(); await WriteSnapshotAsync(page, markComplete: false); MarkSnapshotComplete(); return; }
        }
        var menu = (MenuFlyoutItem)page.FindName(history ? "PhotoFileChangesMenu" : state == "file-delete" ? "DeletePhotoFilesMenu" : state is "file-move" or "file-safety" ? "MovePhotoFilesMenu" : "CopyPhotoFilesMenu");
        if (!menu.IsEnabled || menu.Visibility != Visibility.Visible) throw new InvalidOperationException("文件菜单不可用。");
        ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        try
        {
            await Task.Delay(300); var dialog = Dialog() ?? throw new InvalidOperationException("文件菜单未打开表单。");
            if (state == "file-safety" && Nodes(dialog).OfType<ComboBox>().Any(box => box.Visibility == Visibility.Visible))
                throw new InvalidOperationException("未开放跨来源移动或覆盖时仍显示对应选择。");
            if (!history && state is not ("file-delete" or "file-loading" or "file-error"))
            {
                var folders = Nodes(dialog).OfType<ListView>().Single(list => list.DisplayMemberPath == nameof(SynologyPhotoCollection.Name));
                if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("原目录不应可作为目标。");
                if (state == "file-pages")
                {
                    Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, l.Get("PhotosLoadOlder")))); await Task.Delay(100);
                    if (folders.Items.Count != 101) throw new InvalidOperationException("目标目录分页不完整。");
                }
                if (state == "file-cross")
                {
                    Nodes(dialog).OfType<ComboBox>().Single(box => Equals(box.Header, l.Get("PhotosChooseSource"))).SelectedIndex = 1; await Task.Delay(100);
                    if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("跨来源同编号目录被误拒绝。");
                }
                else
                {
                    folders.SelectedItem = folders.Items.OfType<SynologyPhotoCollection>().Single(folder => folder.Id == 3);
                    Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, l.Get("PhotosOpenFolder")))); await Task.Delay(100);
                    if (!dialog.IsPrimaryButtonEnabled || folders.Items.Count != 0) throw new InvalidOperationException("空目标目录不能选择。");
                }
            }
            if (state is "file-loading" or "file-error" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("未加载目标仍可提交。");
            if (state == "file-history-resume")
            {
                Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, l.Get("PhotosContinueFiles"))));
                for (var attempt = 0; attempt < 100 && (Dialog() is null || Equals(Dialog()?.Title, l.Get("PhotosFileChanges"))); attempt++) await Task.Delay(30);
                dialog = Dialog() ?? throw new InvalidOperationException("继续操作缺少确认窗口。");
                if (Equals(dialog.Title, l.Get("PhotosFileChanges")) || repository.FileContinues != 0) throw new InvalidOperationException("未确认就继续原操作。");
                for (var attempt = 0; attempt < 100 && (!dialog.IsLoaded || dialog.ActualWidth == 0 || !Nodes(dialog).OfType<TextBlock>().Any(text => text.Text.Contains("/Synthetic destination", StringComparison.Ordinal))); attempt++) await Task.Delay(30);
                if (!Nodes(dialog).OfType<TextBlock>().Any(text => text.Text.Contains("/Synthetic destination", StringComparison.Ordinal))) throw new InvalidOperationException("继续没有显示原目标。");
            }
            if (state is "file-submit" or "file-partial" or "file-unknown" or "file-delete" or "file-move" or "file-mixed" or "file-cross" or "file-history-resume")
            {
                Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText)));
                for (var attempt = 0; attempt < 100 && !Equals(Dialog()?.Title, l.Get("PhotosFileChanges")); attempt++) await Task.Delay(30);
                dialog = Dialog() ?? throw new InvalidOperationException("提交后没有操作记录。"); await Task.Delay(100);
                if (state == "file-history-resume" ? repository.FileContinues != 1 || repository.FileWrites != 0 : repository.FileWrites != 1) throw new InvalidOperationException("写入次数不正确。");
                if (state == "file-mixed" && repository.SubmittedFiles is not { Photos.Count: 1, Folders.Count: 1, Destination.Id: 3 }) throw new InvalidOperationException("混合选择或目标丢失。");
                if (state == "file-cross" && repository.SubmittedFiles is not { Space: SynologyPhotoSpace.Personal, Destination.Space: SynologyPhotoSpace.Shared, Destination.Id: 1 }) throw new InvalidOperationException("跨来源目标被替换。");
                if (state == "file-partial" && model.Items.Count != 8) throw new InvalidOperationException("部分完成错误移除了未知项目。");
                if (state is "file-delete" or "file-move" && model.Items.Count != 7) throw new InvalidOperationException("完成后原列表没有移除本项。");
                if (state == "file-unknown")
                {
                    var count = repository.FileReviews;
                    Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, l.Get("PhotosRefresh")))); await Task.Delay(100);
                    if (repository.FileReviews <= count || repository.FileWrites != 1 || Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, l.Get("PhotosContinueFiles"))).IsEnabled)
                        throw new InvalidOperationException("未知结果刷新重复写入或可继续提交。");
                }
            }
            if (state == "file-history-cold" && (repository.FileReviews < 1 || repository.FileWrites != 0 || (await repository.FileChangesAsync()).Single().State != SynologyPhotoFileState.Completed))
                throw new InvalidOperationException("冷恢复未自动只读更新。");
            if (state == "file-history-stale" && (model.Items.Count != 8 || repository.FileReviews != 0 || repository.FileWrites != 0))
                throw new InvalidOperationException("历史终态重新隐藏了后来恢复的照片。");
            if (state == "file-history-cancel")
            {
                Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, l.Get("PhotosCancelFiles")))); await Task.Delay(100);
                if ((await repository.FileChangesAsync()).Single().State != SynologyPhotoFileState.Cancelled || repository.FileWrites != 0) throw new InvalidOperationException("取消未开始任务错误。");
            }
            if (state == "file-cancel")
            {
                Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.CloseButtonText)));
                for (var attempt = 0; attempt < 100 && Dialog() is not null; attempt++) await Task.Delay(30);
                if (repository.FileWrites != 0 || Dialog() is not null) throw new InvalidOperationException("取消表单仍提交了写操作。");
                await WriteSnapshotAsync(page, markComplete: false); MarkSnapshotComplete(); return;
            }
            dialog.UpdateLayout(); if (dialog.ActualWidth <= 0 || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("文件窗口布局或主题不正确。");
            foreach (var control in Nodes(dialog).OfType<Control>().Where(control => control.Visibility == Visibility.Visible && control.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("文件控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); MarkSnapshotComplete();
        }
        finally { repository.FileRelease.TrySetResult(); Dialog()?.Hide(); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(value); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, i))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
