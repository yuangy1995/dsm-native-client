using LanStash.App.Features.Photos.Synology;
using LanStash.App.Features.Transfers;
using LanStash.App.Views;
using LanStash.App.Views.Photos;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal sealed partial class SmokePhotosRepository
{
    internal SynologyPhotoDisplaySettings DisplayPreferences = new(SynologyPhotoGrouping.Day, SynologyPhotoDateFormat.YearDash, false, new(), false);
    internal SynologyPhotoDuplicateSettings DuplicatePreferences = new(SynologyPhotoDuplicatePolicy.KeepBoth, SynologyPhotoFileDuplicate.Skip);
    internal SynologyPhotoRecognitionSettings RecognitionPreferences = new(true, true, false, true, true, true, true);
    internal int PreferenceWrites;
    internal readonly TaskCompletionSource PreferenceRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal SynologyPhotoSettingsChange? PreferenceChange;
    private async Task PreferenceRead(CancellationToken token)
    {
        if (State == "pref-loading") await PreferenceRelease.Task.WaitAsync(token);
        if (State == "pref-error") throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
    }
    public async Task<SynologyPhotoDisplaySettings> DisplaySettingsAsync(CancellationToken cancellationToken = default)
    { await PreferenceRead(cancellationToken); return DisplayPreferences; }
    public Task<SynologyPhotoDuplicateSettings> DuplicateSettingsAsync(CancellationToken cancellationToken = default) => Task.FromResult(DuplicatePreferences);
    public Task<SynologyPhotoRecognitionSettings> RecognitionSettingsAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(State == "pref-recognition-locked" ? RecognitionPreferences with { PersonalEnabled = false } : RecognitionPreferences);
    private SynologyPhotoChangeState PreferenceResult => State is "pref-unknown" or "pref-cold" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Completed;
    public Task<SynologyPhotoSettingsChange> SetDisplaySettingsAsync(Guid operationId, SynologyPhotoDisplaySettings original, SynologyPhotoDisplaySettings updated, CancellationToken cancellationToken = default)
    {
        PreferenceWrites++; PreferenceChange = new(operationId, null, PreferenceResult, false) { Display = new(original, updated) };
        if (!PreferenceChange.Pending) DisplayPreferences = updated; return Task.FromResult(PreferenceChange);
    }
    public Task<SynologyPhotoSettingsChange> SetDuplicateSettingsAsync(Guid operationId, SynologyPhotoDuplicateSettings original, SynologyPhotoDuplicateSettings updated, CancellationToken cancellationToken = default)
    {
        PreferenceWrites++; DuplicatePreferences = updated;
        return Task.FromResult(PreferenceChange = new(operationId, null, SynologyPhotoChangeState.Completed, false) { Duplicates = new(original, updated) });
    }
    public Task<SynologyPhotoSettingsChange> SetRecognitionSettingsAsync(Guid operationId, SynologyPhotoRecognitionSettings original, SynologyPhotoRecognitionSettings updated, CancellationToken cancellationToken = default)
    {
        PreferenceWrites++; RecognitionPreferences = updated;
        return Task.FromResult(PreferenceChange = new(operationId, null, SynologyPhotoChangeState.Completed, false) { Recognition = new(original, updated) });
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoPreferencesAsync(FrameworkElement root)
    {
        if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE")?.StartsWith("pref-tasks", StringComparison.Ordinal) == true) { await SavePhotoBackgroundTasksAsync(root); return; }
        if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE")?.StartsWith("pref-maint", StringComparison.Ordinal) == true || Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE")?.StartsWith("pref-codec", StringComparison.Ordinal) == true) { await SavePhotoMaintenanceAsync(root); return; }
        if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE")?.StartsWith("pref-members", StringComparison.Ordinal) == true) { await SavePhotoSharedMembersAsync(root); return; }
        if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE")?.StartsWith("pref-global", StringComparison.Ordinal) == true) { await SavePhotoGlobalPreferencesAsync(root); return; }
        if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE")?.StartsWith("pref-shared", StringComparison.Ordinal) == true) { await SavePhotoSharedPreferencesAsync(root); return; }
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        if (state == "pref-cold") repo.PreferenceChange = new(Guid.NewGuid(), null, SynologyPhotoChangeState.PendingReview, false)
            { Display = new(repo.DisplayPreferences, repo.DisplayPreferences with { ShowsPreviewInfo = true }) };
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(180);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        await model.LoadIfNeededAsync(); var month = model.SelectedMonth; var ids = model.Items.Select(item => item.Id).ToArray();
        var l = Localization.LocalizationService.Current; var verified = false;
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        async Task Wait(Func<bool> ready) { for (var i = 0; i < 180 && !ready(); i++) await Task.Delay(30); if (!ready()) throw new InvalidOperationException("个人设置界面未达到预期状态。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject node)
        { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(node, i))) yield return child; }
        async Task Open()
        {
            var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(70);
            var name = state.StartsWith("pref-duplicate", StringComparison.Ordinal) ? "PhotoDuplicateSettingsMenu" : state.StartsWith("pref-recognition", StringComparison.Ordinal) ? "PhotoRecognitionSettingsMenu" : "PhotoDisplaySettingsMenu";
            var menu = (MenuFlyoutItem)page.FindName(name);
            if (menu.Visibility != Visibility.Visible || !menu.IsEnabled) throw new InvalidOperationException("个人设置入口不可用。");
            ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(menu).GetPattern(PatternInterface.Invoke)).Invoke(); await Wait(() => Dialog()?.IsLoaded == true);
        }
        try
        {
            if (state == "pref-save")
            {
                var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(70);
                ((IInvokeProvider)new MenuFlyoutItemAutomationPeer((MenuFlyoutItem)page.FindName("SelectPhotosMenu")).GetPattern(PatternInterface.Invoke)).Invoke();
                var grid = (GridView)page.FindName("LibraryGrid"); await Wait(() => grid.SelectionMode == ListViewSelectionMode.Multiple && grid.Items.Count > 2);
                grid.SelectedItems.Add(grid.Items[0]); grid.SelectedItems.Add(grid.Items[1]);
            }
            await Open(); var dialog = Dialog()!;
            if (state is "pref-loading" or "pref-error" or "pref-cold")
            {
                await Task.Delay(160); if (dialog.IsPrimaryButtonEnabled || repo.PreferenceWrites != 0) throw new InvalidOperationException("未加载或冷恢复时允许保存。");
            }
            else if (state == "pref-recognition-locked")
            {
                await Wait(() => Nodes(dialog).OfType<ToggleSwitch>().Count() == 3);
                if (dialog.IsPrimaryButtonEnabled || Nodes(dialog).OfType<ToggleSwitch>().Any(value => value.IsEnabled)) throw new InvalidOperationException("个人图库关闭后仍可修改识别。");
            }
            else
            {
                await Wait(() => state.StartsWith("pref-recognition", StringComparison.Ordinal) ? Nodes(dialog).OfType<ToggleSwitch>().Count() == 3 : Nodes(dialog).OfType<ComboBox>().Any());
                if (state is "pref-display" or "pref-duplicates" or "pref-recognition")
                { if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("原值未变化却允许保存。"); }
                else
                {
                    if (state.StartsWith("pref-recognition", StringComparison.Ordinal)) Nodes(dialog).OfType<ToggleSwitch>().First().IsOn = false;
                    else if (state.StartsWith("pref-duplicate", StringComparison.Ordinal)) Nodes(dialog).OfType<ComboBox>().First().SelectedIndex = 0;
                    else
                    {
                        Nodes(dialog).OfType<ComboBox>().Single(value => AutomationProperties.GetAutomationId(value) == "PhotosDisplayGrouping").SelectedIndex = 1;
                        Nodes(dialog).OfType<ToggleSwitch>().Single().IsOn = true;
                    }
                    await Wait(() => dialog.IsPrimaryButtonEnabled);
                    var button = Nodes(dialog).OfType<Button>().Single(value => Equals(value.Content, l.Get("PhotosSaveChanges")));
                    ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke(); await Wait(() => repo.PreferenceWrites == 1);
                    if (state == "pref-unknown")
                    { await Wait(() => !dialog.IsPrimaryButtonEnabled); if (repo.PreferenceChange?.Pending != true) throw new InvalidOperationException("未知保存未保留。"); }
                    else
                    {
                        await Wait(() => Dialog() is null);
                        if (model.SelectedMonth != month || !model.Items.Select(item => item.Id).SequenceEqual(ids)) throw new InvalidOperationException("保存偏好清空了月份或照片。");
                        if (state == "pref-save" && ((GridView)page.FindName("LibraryGrid")).SelectedItems.Count != 2) throw new InvalidOperationException("分组变化丢失了原生照片选择。");
                        if (state == "pref-preview")
                        {
                            await model.Preview.OpenAsync(model.Items[0]); await Wait(() => ((Image)page.FindName("PreviewImage")).Source is not null);
                            if (((Border)page.FindName("PreviewPhotoInfo")).Visibility != Visibility.Visible || model.DisplaySettings?.Grouping != SynologyPhotoGrouping.Month) throw new InvalidOperationException("显示偏好未应用到实际预览与时间线。");
                            var details = (AppBarButton)page.FindName("DetailsButton");
                            if (details.IsInOverflow) { ((CommandBar)page.FindName("PreviewCommandBar")).IsOpen = true; await Task.Delay(70); }
                            ((IInvokeProvider)new AppBarButtonAutomationPeer(details).GetPattern(PatternInterface.Invoke)).Invoke(); await Wait(() => Dialog()?.IsLoaded == true);
                            if (((Border)page.FindName("PreviewPhotoInfo")).Visibility != Visibility.Collapsed) throw new InvalidOperationException("详细信息打开后重复叠加了预览信息。");
                            Dialog()!.Hide(); await Wait(() => Dialog() is null && ((Border)page.FindName("PreviewPhotoInfo")).Visibility == Visibility.Visible);
                            await Task.Delay(100); await WriteSnapshotAsync(page, markComplete: false); verified = true; return;
                        }
                        await Open(); dialog = Dialog()!; await Task.Delay(100);
                    }
                }
            }
            await Task.Delay(120); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false); verified = true;
        }
        finally
        {
            repo.PreferenceRelease.TrySetResult();
            if (Dialog() is { } dialog)
            {
                var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                void Closed(ContentDialog sender, ContentDialogClosedEventArgs args) { sender.Closed -= Closed; closed.TrySetResult(); }
                dialog.Closed += Closed; dialog.Hide(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(5));
            }
            page.Dispose(); if (verified) MarkSnapshotComplete();
        }
    }
}
