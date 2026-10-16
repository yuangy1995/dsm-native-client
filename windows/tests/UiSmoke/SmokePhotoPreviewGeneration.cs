using LanStash.App.Features.Photos.Synology;
using LanStash.App.Features.Transfers;
using LanStash.App.Views;
using LanStash.App.Views.Photos;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal sealed partial class SmokePhotosRepository
{
    internal int PreviewGenerationStarts, PreviewGenerationContinues, PreviewGenerationReviews, PreviewGenerationStops;
    internal readonly List<SynologyPhotoSpace> PreviewQueueReads = [];
    internal readonly TaskCompletionSource PreviewGenerationRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal SynologyPhotoPreviewGenerationRequest? PreviewGenerationRequest;
    private List<SynologyPhotoPreviewGeneration>? _previewGenerations;
    public bool SupportsPreviewGeneration(SynologyPhotoSpace space) => State.StartsWith("regen-", StringComparison.Ordinal) && State != "regen-capability";
    public Task PreparePreviewGenerationAsync(SynologyPhotoPreviewGenerationRequest request, CancellationToken cancellationToken = default)
    { if (State == "regen-denied") throw new SynologyPhotoException(SynologyPhotoFailure.Permission); return Task.CompletedTask; }
    private SynologyPhoto GenerationPhoto(SynologyPhotoSpace space = SynologyPhotoSpace.Personal, long id = 1) => new(new(ProfileId, space, id), $"Sample-{id:000}.jpg", 2048,
        new(2026, 9, 16, 0, 0, 0, TimeSpan.Zero), new(2026, 9, 16, 0, 0, 0, TimeSpan.Zero), 1, "photo") { Thumbnail = new(id, "synthetic") };
    public async Task<IReadOnlyList<SynologyPhoto>> PendingPreviewGenerationsAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    {
        PreviewQueueReads.Add(space);
        if (State == "regen-queue-loading" || State == "regen-queue-switch" && space == SynologyPhotoSpace.Personal) await PreviewGenerationRelease.Task;
        if (State == "regen-queue-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return State == "regen-queue-empty" ? [] : [GenerationPhoto(space), GenerationPhoto(space, 2)];
    }
    public async Task<SynologyPhotoPreviewGeneration> GeneratePreviewsAsync(Guid operationId, SynologyPhotoPreviewGenerationRequest request, CancellationToken cancellationToken = default)
    {
        PreviewGenerationStarts++; PreviewGenerationRequest = request; _previewGenerations ??= [];
        var hold = State is "regen-running" or "regen-stop" or "regen-late";
        var result = new SynologyPhotoPreviewGeneration(operationId, request.Resuming, request.Photos.Select((photo, index) => new SynologyPhotoPreviewGenerationItem(photo,
            hold ? index == 0 ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Ready : State == "regen-unknown" ? SynologyPhotoChangeState.PendingReview :
            State == "regen-partial" && index == 1 ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Completed,
            !hold && State != "regen-unknown" ? photo with { Thumbnail = new(photo.Id.ItemId, "generated-preview") } : null)).ToArray(), hold, false);
        _previewGenerations.Add(result);
        if (hold)
        {
            await PreviewGenerationRelease.Task;
            result = _previewGenerations.Single(value => value.Id == operationId);
            if (result.Running) { result = result with { Running = false, Items = result.Items.Select(item => item with { State = SynologyPhotoChangeState.Completed, Updated = item.Original with { Thumbnail = new(item.Original.Id.ItemId, "generated-preview") } }).ToArray() }; _previewGenerations[_previewGenerations.FindIndex(value => value.Id == operationId)] = result; }
        }
        return result;
    }
    public Task<IReadOnlyList<SynologyPhotoPreviewGeneration>> PreviewGenerationsAsync(CancellationToken cancellationToken = default)
    {
        if (_previewGenerations is null)
        {
            _previewGenerations = [];
            if (State.StartsWith("regen-history-", StringComparison.Ordinal) && State != "regen-history-empty")
                _previewGenerations.Add(new(Guid.NewGuid(), false, [new(GenerationPhoto(), State == "regen-history-cold" ? SynologyPhotoChangeState.PendingReview : State == "regen-history-retry" ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Ready)], false, State == "regen-history-resume"));
        }
        return Task.FromResult<IReadOnlyList<SynologyPhotoPreviewGeneration>>(_previewGenerations.ToArray());
    }
    public async Task<SynologyPhotoPreviewGeneration> ReviewPreviewGenerationAsync(Guid operationId, CancellationToken cancellationToken = default)
    { PreviewGenerationReviews++; return (await PreviewGenerationsAsync()).Single(value => value.Id == operationId); }
    public async Task<SynologyPhotoPreviewGeneration> ContinuePreviewGenerationAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        PreviewGenerationContinues++; var value = (await PreviewGenerationsAsync()).Single(item => item.Id == operationId);
        value = value with { CanContinue = false, Items = value.Items.Select(item => item with { State = SynologyPhotoChangeState.Completed, Updated = item.Original with { Thumbnail = new(item.Original.Id.ItemId, "generated-preview") } }).ToArray() };
        _previewGenerations![_previewGenerations.FindIndex(item => item.Id == operationId)] = value; return value;
    }
    public async Task<SynologyPhotoPreviewGeneration> CancelPreviewGenerationAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        PreviewGenerationStops++; var value = (await PreviewGenerationsAsync()).Single(item => item.Id == operationId);
        value = value with { Running = false, CanContinue = false, Items = value.Items.Select(item => item.State == SynologyPhotoChangeState.Ready ? item with { State = SynologyPhotoChangeState.Cancelled } : item).ToArray() };
        _previewGenerations![_previewGenerations.FindIndex(item => item.Id == operationId)] = value; PreviewGenerationRelease.TrySetResult(); return value;
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoPreviewGenerationAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(220);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!; await model.LoadIfNeededAsync();
        var l = Localization.LocalizationService.Current; var verified = false;
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        Button Button(string key) => Nodes(Dialog()!).OfType<Button>().Single(value => Equals(value.Content, l.Get(key)));
        async Task Menu(string name)
        {
            var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(80);
            var item = (MenuFlyoutItem)page.FindName(name); if (!item.IsEnabled || item.Visibility != Visibility.Visible) throw new InvalidOperationException("预览任务菜单不可用。");
            ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(item).GetPattern(PatternInterface.Invoke)).Invoke();
        }
        try
        {
            if (state is "regen-frozen-preview" or "regen-frozen-bulk")
            { await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCollectionAsync(new(41, "Synthetic frozen album") { IsFrozen = true }); }
            var queue = state.StartsWith("regen-queue-", StringComparison.Ordinal); var history = state.StartsWith("regen-history-", StringComparison.Ordinal);
            if (queue) await Menu("PendingPhotoPreviewsMenu");
            else if (history) await Menu("PhotoPreviewHistoryMenu");
            else if (state is "regen-multi" or "regen-partial" or "regen-stop" or "regen-frozen-bulk")
            {
                typeof(SynologyPhotosPage).GetMethod("SetPhotoSelection", flags)!.Invoke(page, [true]); var grid = (GridView)page.FindName("LibraryGrid");
                foreach (var cell in grid.Items.OfType<SynologyPhotoCell>().Where(cell => cell.Photo is not null).Take(2).ToArray()) grid.SelectedItems.Add(cell);
                await Menu("GeneratePhotoPreviewsMenu");
            }
            else
            {
                if (state == "regen-decode-error") repo.SlideDecodeFails = true;
                await model.Preview.OpenAsync(model.Items[0]); await Wait(() => state == "regen-decode-error" ? ((InfoBar)page.FindName("PreviewErrorBar")).IsOpen : ((Image)page.FindName("PreviewImage")).Source is not null);
                var button = (AppBarButton)page.FindName("GeneratePhotoPreviewButton");
                if (state is "regen-capability" or "regen-frozen-preview") { if (button.Visibility != Visibility.Collapsed) throw new InvalidOperationException("缺失能力或冻结预览仍显示重建入口。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
                await Wait(() => button.IsEnabled);
                if (button.IsInOverflow) { ((CommandBar)page.FindName("PreviewCommandBar")).IsOpen = true; await Task.Delay(60); }
                ((IInvokeProvider)new AppBarButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
            }
            await Wait(() => Dialog()?.IsLoaded == true); await Task.Delay(140); var dialog = Dialog()!;
            if (queue)
            {
                var list = Nodes(dialog).OfType<ListView>().Single(); var source = Nodes(dialog).OfType<ComboBox>().Single();
                if (state is "regen-queue-loading" or "regen-queue-error" or "regen-queue-empty")
                { if (dialog.IsPrimaryButtonEnabled || list.Items.Count != 0 || repo.PreviewGenerationStarts != 0) throw new InvalidOperationException("预览队列未就绪仍可提交。"); }
                else
                {
                    if (state == "regen-queue-switch") { source.SelectedIndex = 1; await Wait(() => list.Items.Count == 2); repo.PreviewGenerationRelease.TrySetResult(); await Task.Delay(100); if (list.Items.Cast<SynologyPhoto>().Any(photo => photo.Id.Space != SynologyPhotoSpace.Shared)) throw new InvalidOperationException("迟到的个人队列覆盖共享队列。"); }
                    await Wait(() => list.Items.Count == 2); list.SelectedItems.Add(list.Items[0]); if (!dialog.IsPrimaryButtonEnabled || repo.PreviewGenerationStarts != 0) throw new InvalidOperationException("选择队列直接写入或没有启用继续。");
                    if (state == "regen-queue-continue")
                    { Invoke(Button("PhotosPreviewContinue")); await Wait(() => Dialog() is { IsLoaded: true } current && !ReferenceEquals(current, dialog)); dialog = Dialog()!; await Wait(() => dialog.IsPrimaryButtonEnabled); Invoke(Button("PhotosPreviewContinue")); await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosPreviewHistory"))); dialog = Dialog()!; await Wait(() => repo.PreviewGenerationStarts == 1); if (repo.PreviewGenerationRequest?.Resuming != true) throw new InvalidOperationException("继续队列误用全新生成。"); }
                }
            }
            else if (history)
            {
                if (state == "regen-history-cold") { if (repo.PreviewGenerationReviews == 0 || Button("PhotosPreviewContinue").IsEnabled || repo.PreviewGenerationContinues != 0 || repo.PreviewGenerationStarts != 0) throw new InvalidOperationException("历史未知任务没有保持只读。"); }
                else if (state == "regen-history-resume") { Invoke(Button("PhotosPreviewContinue")); await Wait(() => repo.PreviewGenerationContinues == 1); await Task.Delay(120); if (repo.PreviewGenerationStarts != 0) throw new InvalidOperationException("继续重建了任务。"); }
                else if (state == "regen-history-retry") { Invoke(Button("PhotosPreviewRetry")); await Wait(() => Dialog() is { IsLoaded: true } current && !ReferenceEquals(current, dialog)); dialog = Dialog()!; if (repo.PreviewGenerationStarts != 0) throw new InvalidOperationException("重试跳过确认。"); }
            }
            else
            {
                if (repo.PreviewGenerationStarts != 0) throw new InvalidOperationException("预览生成跳过确认。");
                if (state == "regen-denied") { if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("权限拒绝后可提交。"); }
                else
                {
                    await Wait(() => dialog.IsPrimaryButtonEnabled);
                    if (state == "regen-confirm-cancel") { Invoke(Button("PhotosCancel")); await Wait(() => Dialog() is null); if (repo.PreviewGenerationStarts != 0) throw new InvalidOperationException("取消确认仍生成预览。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
                    if (state is not ("regen-confirm" or "regen-decode-error"))
                    {
                        if (!Button("PhotosGeneratePreviews").Focus(FocusState.Keyboard)) throw new InvalidOperationException("生成确认不能键盘聚焦。");
                        var month = model.SelectedMonth; Invoke(Button("PhotosGeneratePreviews")); await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosPreviewHistory"))); dialog = Dialog()!;
                        await Wait(() => repo.PreviewGenerationStarts == 1); await Task.Delay(140);
                        if (state == "regen-unknown") { Invoke(Button("PhotosRefresh")); await Task.Delay(80); if (Button("PhotosPreviewContinue").IsEnabled || repo.PreviewGenerationContinues != 0 || repo.PreviewGenerationStarts != 1) throw new InvalidOperationException("未知生成重复提交。"); }
                        if (state == "regen-stop") { Invoke(Button("PhotosCancelRemainingChanges")); await Wait(() => repo.PreviewGenerationStops == 1); await Task.Delay(100); var task = (await repo.PreviewGenerationsAsync()).Single(); if (!task.Pending || task.Items[1].State != SynologyPhotoChangeState.Cancelled) throw new InvalidOperationException("停止丢失已提交事实。"); }
                        if (state == "regen-late") { Invoke(Button("PhotosClose")); await Wait(() => Dialog() is null); await model.SelectSpaceAsync(SynologyPhotoSpace.Shared); repo.PreviewGenerationRelease.TrySetResult(); await Task.Delay(100); if (model.Items.Any(photo => photo.Id.Space != SynologyPhotoSpace.Shared) || model.Preview.Photo is not null) throw new InvalidOperationException("迟到结果更新其他来源。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
                        if (model.SelectedMonth != month) throw new InvalidOperationException("生成预览改变月份。");
                        if (state is "regen-complete" or "regen-multi") { await Wait(() => Nodes(dialog).OfType<TextBlock>().Any(text => text.Text == l.Get("PhotosPreviewCompleted"))); if (model.Items[0].Thumbnail?.Revision != "generated-preview") throw new InvalidOperationException("完成后未刷新缩略图。"); }
                        if (state == "regen-multi" && repo.PreviewGenerationRequest?.Photos.Count != 2) throw new InvalidOperationException("多选预览丢失项目。");
                    }
                }
            }
            await Task.Delay(180); dialog.UpdateLayout();
            foreach (var control in Nodes(dialog).OfType<Control>().Where(control => control.Visibility == Visibility.Visible && control.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("预览任务控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); verified = true;
        }
        finally
        {
            repo.PreviewGenerationRelease.TrySetResult();
            if (Dialog() is { } open)
            { var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); void Closed(ContentDialog sender, ContentDialogClosedEventArgs args) { sender.Closed -= Closed; closed.TrySetResult(); } open.Closed += Closed; open.Hide(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
            page.Dispose(); if (verified) MarkSnapshotComplete();
        }
        static async Task Wait(Func<bool> ready) { for (var attempt = 0; attempt < 160 && !ready(); attempt++) await Task.Delay(25); if (!ready()) throw new InvalidOperationException("预览任务窗口未就绪。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value) { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    }
}
