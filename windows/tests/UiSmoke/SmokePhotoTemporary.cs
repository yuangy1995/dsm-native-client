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
    private List<SynologyPhotoTemporaryChange>? _temporaryChanges;
    internal readonly TaskCompletionSource TemporaryRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal int TemporaryCreates, TemporaryStops, TemporaryCancels, TemporaryContinues, TemporaryKeeps, TemporaryReviews;
    internal bool? TemporaryKeepCopy;
    public async Task<SynologyPhotoTemporaryChange> CreateTemporarySharingAsync(Guid operationId, string name, IReadOnlyList<SynologyPhoto> photos, CancellationToken cancellationToken = default)
    {
        await TemporarySharingChangesAsync(); TemporaryCreates++;
        var change = new SynologyPhotoTemporaryChange(operationId, State == "tmp-unknown" ? null : 41, null,
            State is "tmp-creating-cancel" or "tmp-unknown" ? SynologyPhotoTemporaryStage.Create : SynologyPhotoTemporaryStage.Configure,
            State is "tmp-creating-cancel" or "tmp-unknown" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Ready,
            null, true, false, false, State == "tmp-creating-cancel", false, SyntheticSharing());
        _temporaryChanges!.Add(change);
        if (State == "tmp-creating-cancel")
        {
            await TemporaryRelease.Task; var index = _temporaryChanges.FindIndex(value => value.Id == operationId);
            change = _temporaryChanges[index] with { Running = false, State = SynologyPhotoChangeState.Completed, Stage = SynologyPhotoTemporaryStage.Finished };
            _temporaryChanges[index] = change;
        }
        return change;
    }
    public async Task<SynologyPhotoTemporaryChange> StopTemporarySharingAsync(Guid operationId, SynologyPhotoSharing original, bool keepCopy, CancellationToken cancellationToken = default)
    {
        await TemporarySharingChangesAsync(); TemporaryStops++; TemporaryKeepCopy = keepCopy;
        var change = new SynologyPhotoTemporaryChange(operationId, 41, keepCopy ? 42 : null, SynologyPhotoTemporaryStage.Finished, SynologyPhotoChangeState.Completed,
            null, false, keepCopy, false, false, false, null); _temporaryChanges!.Add(change); return change;
    }
    public Task<IReadOnlyList<SynologyPhotoTemporaryChange>> TemporarySharingChangesAsync(CancellationToken cancellationToken = default)
    {
        if (_temporaryChanges is null)
        {
            _temporaryChanges = [];
            if (State.StartsWith("tmp-history-", StringComparison.Ordinal) && State != "tmp-history-empty")
                _temporaryChanges.Add(new(Guid.Parse("66666666-6666-6666-6666-666666666666"), 41, 42,
                    State == "tmp-history-configure" ? SynologyPhotoTemporaryStage.Configure : SynologyPhotoTemporaryStage.Close,
                    State == "tmp-history-cold" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Ready,
                    null, State == "tmp-history-configure", true, false, false, State is "tmp-history-resume" or "tmp-history-keep", null));
        }
        return Task.FromResult<IReadOnlyList<SynologyPhotoTemporaryChange>>(_temporaryChanges.ToArray());
    }
    public async Task<SynologyPhotoTemporaryChange> ReviewTemporarySharingAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await TemporarySharingChangesAsync(); TemporaryReviews++; var index = _temporaryChanges!.FindIndex(value => value.Id == operationId);
        if (State == "tmp-history-cold") _temporaryChanges[index] = _temporaryChanges[index] with { State = SynologyPhotoChangeState.Ready, CanContinue = true };
        return _temporaryChanges[index];
    }
    public async Task<SynologyPhotoTemporaryChange> ContinueTemporarySharingAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await TemporarySharingChangesAsync(); TemporaryContinues++; var index = _temporaryChanges!.FindIndex(value => value.Id == operationId);
        return _temporaryChanges[index] = _temporaryChanges[index] with { State = SynologyPhotoChangeState.Completed, Stage = SynologyPhotoTemporaryStage.Finished, CanContinue = false };
    }
    public async Task<SynologyPhotoTemporaryChange> CancelTemporaryCreationAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await TemporarySharingChangesAsync(); TemporaryCancels++; var index = _temporaryChanges!.FindIndex(value => value.Id == operationId);
        if (index < 0) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var change = _temporaryChanges[index] with { CancelRequested = true };
        if (!change.Pending) change = change with { State = SynologyPhotoChangeState.Completed, Stage = SynologyPhotoTemporaryStage.Finished };
        return _temporaryChanges[index] = change;
    }
    public async Task<SynologyPhotoTemporaryChange> KeepTemporaryAlbumsAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await TemporarySharingChangesAsync(); TemporaryKeeps++; var index = _temporaryChanges!.FindIndex(value => value.Id == operationId);
        return _temporaryChanges[index] = _temporaryChanges[index] with { State = SynologyPhotoChangeState.Cancelled, Stage = SynologyPhotoTemporaryStage.Finished, CanContinue = false };
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoTemporaryAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null));
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        var history = state.StartsWith("tmp-history-", StringComparison.Ordinal);
        var creating = state is "tmp-form" or "tmp-create" or "tmp-configure-cancel" or "tmp-creating-cancel" or "tmp-unknown" or "tmp-safety" or "tmp-cancel";
        await model.SelectSectionAsync(creating ? SynologyPhotosSection.Timeline : SynologyPhotosSection.Albums);
        if (state == "tmp-stop-open") await model.OpenCollectionAsync(model.Collections[0]);
        var grid = (GridView)page.FindName("LibraryGrid");
        if (creating)
        { typeof(SynologyPhotosPage).GetMethod("SetPhotoSelection", flags)!.Invoke(page, [true]); grid.SelectedItems.Add(grid.Items.OfType<SynologyPhotoCell>().First(value => value.Photo is not null)); }
        else grid.SelectedIndex = 0;
        var l = Localization.LocalizationService.Current;
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
        var menu = (MenuFlyoutItem)page.FindName(history ? "TemporarySharingChangesMenu" : creating ? "CreateTemporarySharingMenu" : "StopTemporarySharingMenu");
        if (!menu.IsEnabled || menu.Visibility != Visibility.Visible) throw new InvalidOperationException("临时分享原生入口不可用。");
        ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        for (var attempt = 0; attempt < 100 && (Dialog() is null || !Dialog()!.IsLoaded); attempt++) await Task.Delay(30);
        var dialog = Dialog() ?? throw new InvalidOperationException("没有临时分享窗口。"); await Task.Delay(160);
        Button Button(string key) => Nodes(Dialog()!).OfType<Button>().Single(value => Equals(value.Content, l.Get(key)));
        async Task WaitTitle(string key)
        { for (var attempt = 0; attempt < 100 && !Equals(Dialog()?.Title, l.Get(key)); attempt++) await Task.Delay(30); dialog = Dialog() ?? throw new InvalidOperationException("缺少下一步窗口。"); await Task.Delay(160); if (!Equals(dialog.Title, l.Get(key))) throw new InvalidOperationException("下一步窗口错误。"); }
        try
        {
            if (creating)
            {
                if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("空名称可创建。");
                Nodes(dialog).OfType<TextBox>().Single().Text = "Synthetic temporary album"; await Task.Delay(100);
                if (dialog.IsPrimaryButtonEnabled == (state == "tmp-safety")) throw new InvalidOperationException("创建按钮或安全限制错误。");
            }
            if (state is "tmp-loading" or "tmp-error" or "tmp-ordinary" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("不可用相册仍可清理。");
            if (state == "tmp-cancel")
            { Invoke(Nodes(dialog).OfType<Button>().Single(value => Equals(value.Content, dialog.CloseButtonText))); await Task.Delay(300); if (repo.TemporaryCreates != 0 || repo.TemporaryCancels != 0) throw new InvalidOperationException("取消草稿触发写入。"); await WriteSnapshotAsync(page); return; }
            if (state is "tmp-create" or "tmp-configure-cancel" or "tmp-creating-cancel" or "tmp-unknown")
            {
                Invoke(Nodes(dialog).OfType<Button>().Single(value => Equals(value.Content, dialog.PrimaryButtonText)));
                if (state == "tmp-creating-cancel")
                {
                    await Task.Delay(120); if (dialog.IsPrimaryButtonEnabled || repo.TemporaryCreates != 1) throw new InvalidOperationException("创建中防重失败。");
                    Invoke(Nodes(dialog).OfType<Button>().Single(value => Equals(value.Content, dialog.CloseButtonText)));
                    for (var attempt = 0; attempt < 100 && repo.TemporaryCancels == 0; attempt++) await Task.Delay(30);
                    if (repo.TemporaryCancels == 0) throw new InvalidOperationException("关闭创建窗口未保存取消。");
                    repo.TemporaryRelease.TrySetResult(); await Task.Delay(250); await WriteSnapshotAsync(page); return;
                }
                await WaitTitle(state == "tmp-unknown" ? "PhotosTemporaryChanges" : "PhotosShareAlbum");
                if (repo.TemporaryCreates != 1) throw new InvalidOperationException("临时相册创建次数错误。");
                if (state == "tmp-unknown" && (Button("PhotosShareContinue").IsEnabled || repo.TemporaryContinues != 0)) throw new InvalidOperationException("未知创建可重新提交。");
                if (state == "tmp-configure-cancel")
                {
                    Invoke(Nodes(dialog).OfType<Button>().Single(value => Equals(value.Content, dialog.CloseButtonText)));
                    for (var attempt = 0; attempt < 100 && repo.TemporaryCancels == 0; attempt++) await Task.Delay(30);
                    if (repo.TemporaryCancels != 1 || repo.SharingWrites != 0) throw new InvalidOperationException("取消分享设置没有清理临时相册。");
                    await Task.Delay(200); await WriteSnapshotAsync(page); return;
                }
            }
            if (state is "tmp-stop" or "tmp-stop-nocopy" or "tmp-stop-open")
            {
                var copy = Nodes(dialog).OfType<CheckBox>().Single(); if (copy.IsChecked != true) throw new InvalidOperationException("没有默认保留副本。");
                if (state == "tmp-stop-nocopy") copy.IsChecked = false;
                Invoke(Nodes(dialog).OfType<Button>().Single(value => Equals(value.Content, dialog.PrimaryButtonText))); await WaitTitle("PhotosTemporaryChanges");
                if (repo.TemporaryStops != 1 || repo.TemporaryKeepCopy != (state != "tmp-stop-nocopy")) throw new InvalidOperationException("停止选项没有进入原流程。");
                if (state == "tmp-stop-open")
                {
                    Invoke(Nodes(dialog).OfType<Button>().Single(value => Equals(value.Content, dialog.CloseButtonText)));
                    for (var attempt = 0; attempt < 100 && model.Album is not null; attempt++) await Task.Delay(30);
                    if (model.Album is not null || model.CurrentAlbum is not null) throw new InvalidOperationException("已清理相册仍留在详情页。");
                    await Task.Delay(200); await WriteSnapshotAsync(page); return;
                }
            }
            if (state == "tmp-history-cold" && (repo.TemporaryReviews == 0 || repo.TemporaryContinues != 0)) throw new InvalidOperationException("冷恢复不是只读。");
            if (state == "tmp-history-resume") { Invoke(Button("PhotosShareContinue")); await Task.Delay(100); if (repo.TemporaryContinues != 1) throw new InvalidOperationException("继续没有执行原任务。"); }
            if (state == "tmp-history-keep") { Invoke(Button("PhotosTemporaryKeepAlbums")); await Task.Delay(100); if (repo.TemporaryKeeps != 1 || repo.TemporaryStops != 0) throw new InvalidOperationException("保留相册仍执行写入。"); }
            if (state == "tmp-history-configure") { Invoke(Button("PhotosTemporaryConfigureButton")); await WaitTitle("PhotosShareAlbum"); if (repo.TemporaryCreates != 0) throw new InvalidOperationException("设置已有分享重复创建。"); }
            await Task.Delay(450); dialog.UpdateLayout();
            if (dialog.ActualWidth <= 0 || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("临时分享窗口主题或布局错误。");
            foreach (var control in Nodes(dialog).OfType<Control>().Where(value => value.Visibility == Visibility.Visible && value.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("临时分享控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); MarkSnapshotComplete();
        }
        finally { repo.SharingRelease.TrySetResult(); repo.TemporaryRelease.TrySetResult(); Dialog()?.Hide(); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
