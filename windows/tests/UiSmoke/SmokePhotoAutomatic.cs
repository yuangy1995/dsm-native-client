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
    internal bool AutomaticEnabled = State is "auto-enabled" or "auto-disable" or "auto-current" or "auto-running" or "auto-complete" or "auto-failed" or "auto-cold" or "auto-paused" or "auto-hide" or "auto-manual";
    internal int AutomaticStarts, AutomaticSettingsWrites, AutomaticReviews;
    internal readonly List<SynologyPhotoAutomaticCandidate> AutomaticCandidates = [];
    internal readonly TaskCompletionSource AutomaticRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly List<SynologyPhotoAutomaticPreview> _automatic = [];
    private SynologyPhotoSettingsChange? _automaticSetting;
    public bool SupportsAutomaticPreview(SynologyPhotoSpace space) => State.StartsWith("auto-", StringComparison.Ordinal);
    public Task<SynologyPhotoConversionSupport> PreviewConversionSupportAsync(CancellationToken cancellationToken = default) => Task.FromResult(new SynologyPhotoConversionSupport(State != "auto-unsupported", false, State != "auto-unsupported"));
    public async Task<bool> AutomaticPreviewEnabledAsync(CancellationToken cancellationToken = default)
    {
        if (State == "auto-loading") await AutomaticRelease.Task.WaitAsync(cancellationToken);
        if (State == "auto-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return AutomaticEnabled;
    }
    public Task<SynologyPhotoSettingsChange> SetAutomaticPreviewAsync(Guid operationId, bool original, bool enabled, CancellationToken cancellationToken = default)
    {
        if (original != AutomaticEnabled) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        AutomaticSettingsWrites++; if (State != "auto-setting-unknown") AutomaticEnabled = enabled;
        _automaticSetting = new(operationId, new(original, enabled), State == "auto-setting-unknown" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Completed, false);
        return Task.FromResult(_automaticSetting);
    }
    public Task<IReadOnlyList<SynologyPhotoSettingsChange>> SettingsChangesAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<SynologyPhotoSettingsChange>>(new[] { _automaticSetting, PreferenceChange }.OfType<SynologyPhotoSettingsChange>().ToArray());
    public Task<SynologyPhotoSettingsChange> ReviewSettingsChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Task.FromResult(BackgroundOperation?.Id == operationId ? BackgroundOperation : PreferenceChange?.Id == operationId ? PreferenceChange : _automaticSetting!);
    public Task<IReadOnlyList<SynologyPhotoAutomaticCandidate>> AutomaticPreviewCandidatesAsync(SynologyPhotoSpace space, SynologyPhotoConversionSupport support, CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<SynologyPhotoAutomaticCandidate>>([]);
    private SynologyPhotoAutomaticCandidate AutomaticCandidate(SynologyPhoto photo) => new(ProfileId, photo.Id.Space, photo.Thumbnail!.UnitId, photo.Filename, 0, true, false, photo, SynologyPhotoAutomaticPriority.Standard);
    public Task<IReadOnlyList<SynologyPhotoAutomaticCandidate>> AutomaticPreviewCandidatesAsync(SynologyPhoto photo, SynologyPhotoConversionSupport support, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<SynologyPhotoAutomaticCandidate>>(State is "auto-current" or "auto-running" or "auto-complete" or "auto-failed" or "auto-hide" or "auto-manual" ? [AutomaticCandidate(photo)] : []);
    public async Task<SynologyPhotoAutomaticPreview> GenerateAutomaticPreviewAsync(Guid operationId, SynologyPhotoAutomaticCandidate candidate, SynologyPhotoConversionSupport support, CancellationToken cancellationToken = default)
    {
        AutomaticStarts++; AutomaticCandidates.Add(candidate);
        var state = State == "auto-failed" ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Completed;
        if (State is "auto-running" or "auto-current" or "auto-hide" or "auto-manual")
        { try { await AutomaticRelease.Task.WaitAsync(cancellationToken); } catch (OperationCanceledException) { state = SynologyPhotoChangeState.PendingReview; } }
        var result = new SynologyPhotoAutomaticPreview(operationId, candidate, state, false, Updated: state == SynologyPhotoChangeState.Completed ? candidate.SourcePhoto : null);
        _automatic.Add(result); return result;
    }
    public Task<IReadOnlyList<SynologyPhotoAutomaticPreview>> AutomaticPreviewsAsync(CancellationToken cancellationToken = default)
    {
        if (State == "auto-cold" && _automatic.Count == 0) _automatic.Add(new(Guid.NewGuid(), AutomaticCandidate(GenerationPhoto()), SynologyPhotoChangeState.PendingReview, false));
        return Task.FromResult<IReadOnlyList<SynologyPhotoAutomaticPreview>>(_automatic.ToArray());
    }
    public Task<SynologyPhotoAutomaticPreview> ReviewAutomaticPreviewAsync(Guid operationId, CancellationToken cancellationToken = default)
    { AutomaticReviews++; return Task.FromResult(_automatic.Single(value => value.Id == operationId)); }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoAutomaticAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(180);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!; await model.LoadIfNeededAsync();
        var l = Localization.LocalizationService.Current; var verified = false; var originalMonth = model.SelectedMonth;
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        async Task Menu()
        {
            var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(70);
            var item = (MenuFlyoutItem)page.FindName("AutomaticPhotoPreviewsMenu");
            if (item.Visibility != Visibility.Visible) throw new InvalidOperationException("自动预览设置入口缺失。");
            ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(item).GetPattern(PatternInterface.Invoke)).Invoke();
        }
        try
        {
            var workflow = state is "auto-current" or "auto-running" or "auto-complete" or "auto-failed" or "auto-cold" or "auto-paused" or "auto-hide" or "auto-manual";
            if (!workflow)
            {
                await Menu(); await Wait(() => Dialog()?.IsLoaded == true); var dialog = Dialog()!;
                if (state is not ("auto-loading" or "auto-error")) await Wait(() => model.Automatic.CanChangeSetting);
                await Task.Delay(100); var toggle = Nodes(dialog).OfType<ToggleSwitch>().Single();
                if (state is "auto-loading" or "auto-error")
                { if (toggle.IsEnabled || dialog.IsPrimaryButtonEnabled || repo.AutomaticSettingsWrites != 0) throw new InvalidOperationException("设置未读取仍允许提交。"); }
                else if (state is "auto-enable" or "auto-disable" or "auto-setting-unknown")
                {
                    toggle.IsOn = !toggle.IsOn; await Wait(() => dialog.IsPrimaryButtonEnabled);
                    Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, l.Get("PhotosSaveChanges"))));
                    await Wait(() => repo.AutomaticSettingsWrites == 1);
                    if (state == "auto-setting-unknown")
                    { await Wait(() => model.Automatic.PendingSetting is not null); if (toggle.IsEnabled || dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("未知设置仍允许重复保存。"); }
                    else { await Wait(() => Dialog() is null); await Menu(); await Wait(() => Dialog()?.IsLoaded == true); dialog = Dialog()!; await Task.Delay(100); }
                }
                if (repo.AutomaticStarts != 0) throw new InvalidOperationException("设置窗口执行了自动转换。");
                await Task.Delay(120); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
            }
            else
            {
                if (state == "auto-paused") model.Automatic.Pause();
                if (state is "auto-current" or "auto-manual")
                {
                    // 明确建立当前预览后再领取；本例不把打开前已领取的可见项误当优先级错误。
                    model.Automatic.Pause();
                    var grid = (GridView)page.FindName("LibraryGrid");
                    await Wait(() => grid.ContainerFromIndex(3) is GridViewItem item && item.IsLoaded && Nodes(item).OfType<Image>().Any(image => image.Source is not null));
                    await model.Preview.OpenAsync(model.Items[3]);
                    await Wait(() => ((Image)page.FindName("PreviewImage")).Source is not null && ((AppBarButton)page.FindName("SaveButton")).IsEnabled);
                    model.Automatic.Resume();
                }
                if (state is "auto-cold") await Wait(() => model.Automatic.HasPending && repo.AutomaticReviews > 0);
                else if (state != "auto-paused") await Wait(() => repo.AutomaticStarts > 0, 260);
                if (state == "auto-current" && repo.AutomaticCandidates[0].SourcePhoto?.Id != model.Items[3].Id) throw new InvalidOperationException("当前预览没有优先生成。");
                if (state == "auto-complete")
                { await Wait(() => !model.Automatic.IsRunning); if (model.SelectedMonth != originalMonth || model.Automatic.ErrorKey is not null) throw new InvalidOperationException("预览完成改变了月份或误报失败。"); }
                if (state == "auto-hide")
                { page.SetWindowVisible(false); await Wait(() => !model.Automatic.IsRunning); if (!model.Automatic.HasPending) throw new InvalidOperationException("隐藏窗口丢失已提交结果。"); page.SetWindowVisible(true); }
                if (state == "auto-manual")
                {
                    var button = (AppBarButton)page.FindName("EditPhotoButton"); await Wait(() => button.IsEnabled);
                    if (button.IsInOverflow) { ((CommandBar)page.FindName("PreviewCommandBar")).IsOpen = true; await Task.Delay(60); }
                    ((IInvokeProvider)new AppBarButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
                    await Wait(() => Dialog()?.IsLoaded == true);
                    if (model.Automatic.IsRunning || !model.Automatic.HasPending) throw new InvalidOperationException("手动入口没有让出转换或丢失未知结果。");
                    await WriteSnapshotAsync(Dialog()!, markComplete: false); verified = true; return;
                }
                if (state == "auto-paused" && repo.AutomaticStarts != 0 || state == "auto-cold" && repo.AutomaticStarts != 0) throw new InvalidOperationException("暂停或冷恢复重新提交了转换。");
                await Task.Delay(120); await WriteSnapshotAsync(page, markComplete: false);
            }
            verified = true;
        }
        finally
        {
            model.Automatic.SetActive(false); repo.AutomaticRelease.TrySetResult();
            if (Dialog() is { } open)
            { var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); void Closed(ContentDialog sender, ContentDialogClosedEventArgs args) { sender.Closed -= Closed; closed.TrySetResult(); } open.Closed += Closed; open.Hide(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
            page.Dispose(); if (verified) MarkSnapshotComplete();
        }
        static async Task Wait(Func<bool> ready, int count = 180) { for (var attempt = 0; attempt < count && !ready(); attempt++) await Task.Delay(25); if (!ready()) throw new InvalidOperationException("自动预览未达到预期状态。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value) { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
    }
}
