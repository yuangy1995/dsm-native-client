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
    private SynologyPhotoSharedSettings? _sharedPreferences;
    internal SynologyPhotoSharedSettings SharedPreferences => _sharedPreferences ??= new(ProfileId, 19, State != "pref-shared-enable", State != "pref-shared-last",
        SynologyPhotoSharedRole.Management, State == "pref-shared-enable" ? true : null, true, true, true, false, true, true, true);
    public SynologyPhotoSettingsSafety SettingsSafety => State is "pref-shared-locked" or "pref-global-locked" or "pref-members-locked" ? new() : new(true, true, true, true);
    public async Task<SynologyPhotoSharedSettings> SharedSettingsAsync(CancellationToken cancellationToken = default)
    {
        if (State == "pref-shared-loading") await PreferenceRelease.Task.WaitAsync(cancellationToken);
        if (State == "pref-shared-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return SharedPreferences;
    }
    public Task<SynologyPhotoSettingsChange> SetSharedSettingsAsync(Guid operationId, SynologyPhotoSharedSettings original, SynologyPhotoSharedSettings updated, bool confirmed = false, CancellationToken cancellationToken = default)
        => SaveSharedPreference(operationId, original, updated, false, confirmed);
    public Task<SynologyPhotoSettingsChange> SetSharedEnabledAsync(Guid operationId, SynologyPhotoSharedSettings original, bool enabled, bool confirmed = false, CancellationToken cancellationToken = default)
        => SaveSharedPreference(operationId, original, original with { Enabled = enabled }, true, confirmed);
    private Task<SynologyPhotoSettingsChange> SaveSharedPreference(Guid id, SynologyPhotoSharedSettings original, SynologyPhotoSharedSettings updated, bool switching, bool confirmed)
    {
        if ((switching || original.PublicRoot != updated.PublicRoot) && !confirmed) throw new InvalidOperationException("共享设置未确认风险。");
        PreferenceWrites++; var pending = State == "pref-shared-unknown";
        if (!pending) _sharedPreferences = updated;
        PreferenceChange = new(id, null, pending ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Completed, false)
        { Shared = new(original, updated, switching), SharedResult = pending ? null : updated }; return Task.FromResult(PreferenceChange);
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoSharedPreferencesAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        if (state == "pref-shared-cold") repo.PreferenceChange = new(Guid.NewGuid(), null, SynologyPhotoChangeState.PendingReview, false)
            { Shared = new(repo.SharedPreferences, repo.SharedPreferences with { People = false }, false) };
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(180);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!; await model.LoadIfNeededAsync();
        if (state == "pref-shared-source-disabled") { await model.SelectSpaceAsync(SynologyPhotoSpace.Shared); await model.Preview.OpenAsync(model.Items[0]); }
        if (state == "pref-shared-category-off")
        {
            await model.SelectSpaceAsync(SynologyPhotoSpace.Shared); await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCategoryAsync(SynologyPhotoCategory.People);
            if (model.Category != SynologyPhotoCategory.People || model.Collections.Count == 0) throw new InvalidOperationException("共享人物分类没有实际打开。");
        }
        var month = model.SelectedMonth; var ids = model.Items.Select(item => item.Id).ToArray(); var l = Localization.LocalizationService.Current; var verified = false;
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        async Task Wait(Func<bool> ready) { for (var i = 0; i < 180 && !ready(); i++) await Task.Delay(30); if (!ready()) throw new InvalidOperationException("共享设置界面未达到预期状态。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject node) { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(node, i))) yield return child; }
        static void Click(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
        ToggleSwitch Toggle(string key) => Nodes(Dialog()!).OfType<ToggleSwitch>().Single(value => AutomationProperties.GetAutomationId(value) == key);
        Button Primary(string key) => Nodes(Dialog()!).OfType<Button>().Single(value => Equals(value.Content, l.Get(key)));
        async Task Open()
        {
            var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(70);
            var menu = (MenuFlyoutItem)page.FindName("PhotoSharedSettingsMenu");
            if (menu.Visibility != Visibility.Visible || !menu.IsEnabled) throw new InvalidOperationException("共享设置入口不可用。");
            ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(menu).GetPattern(PatternInterface.Invoke)).Invoke(); await Wait(() => Dialog()?.IsLoaded == true);
        }
        try
        {
            if (state == "pref-shared-nonadmin")
            {
                if (((MenuFlyoutItem)page.FindName("PhotoSharedSettingsMenu")).Visibility != Visibility.Collapsed) throw new InvalidOperationException("共享管理成员被当成系统管理员。");
                await WriteSnapshotAsync(page, markComplete: false); verified = true; return;
            }
            if (state == "pref-shared-save")
            {
                var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(70);
                ((IInvokeProvider)new MenuFlyoutItemAutomationPeer((MenuFlyoutItem)page.FindName("SelectPhotosMenu")).GetPattern(PatternInterface.Invoke)).Invoke();
                var grid = (GridView)page.FindName("LibraryGrid"); await Wait(() => grid.SelectionMode == ListViewSelectionMode.Multiple && grid.Items.Count > 2);
                grid.SelectedItems.Add(grid.Items[0]); grid.SelectedItems.Add(grid.Items[1]);
            }
            await Open();
            if (state is "pref-shared-loading" or "pref-shared-error" or "pref-shared-cold")
            {
                await Task.Delay(180); if (Dialog()!.IsPrimaryButtonEnabled || repo.PreferenceWrites != 0) throw new InvalidOperationException("未加载或未知设置允许提交。");
            }
            else
            {
                await Wait(() => Nodes(Dialog()!).OfType<ToggleSwitch>().Count() == 4);
                if (state is "pref-shared-last" or "pref-shared-locked")
                {
                    if (Nodes(Dialog()!).OfType<Button>().Single(value => AutomationProperties.GetAutomationId(value) == "PhotoSharedSwitch").IsEnabled) throw new InvalidOperationException("高风险保护或最后图库限制失效。");
                    if (state == "pref-shared-locked" && (Toggle("PhotosSharedPublicRoot").IsEnabled || !Toggle("PhotosCategoryPeople").IsEnabled)) throw new InvalidOperationException("专项保护错误影响普通识别设置。");
                }
                else if (state != "pref-shared")
                {
                    var switching = state is "pref-shared-enable" or "pref-shared-disable" or "pref-shared-source-disabled";
                    if (switching)
                    {
                        var old = Dialog(); Click(Nodes(old!).OfType<Button>().Single(value => AutomationProperties.GetAutomationId(value) == "PhotoSharedSwitch"));
                        await Wait(() => Dialog() is { IsLoaded: true } current && !ReferenceEquals(current, old) && Nodes(current).OfType<ToggleSwitch>().Count() == 1);
                        Toggle("PhotosSharedEnabled").IsOn = !repo.SharedPreferences.Enabled;
                    }
                    else if (state is "pref-shared-public" or "pref-shared-public-save") Toggle("PhotosSharedPublicRoot").IsOn = true;
                    else Toggle("PhotosCategoryPeople").IsOn = false;
                    await Wait(() => Dialog()!.IsPrimaryButtonEnabled); Click(Primary("PhotosSaveChanges"));
                    if (switching || state is "pref-shared-public" or "pref-shared-public-save")
                    {
                        await Wait(() => Equals(Dialog()!.PrimaryButtonText, l.Get("PhotosSharedConfirm")));
                        if (repo.PreferenceWrites != 0) throw new InvalidOperationException("确认风险前已提交共享设置。");
                        if (state == "pref-shared-public") { await Task.Delay(120); await WriteSnapshotAsync(Dialog()!, markComplete: false); verified = true; return; }
                        Click(Primary("PhotosSharedConfirm"));
                    }
                    await Wait(() => repo.PreferenceWrites == 1);
                    if (state == "pref-shared-unknown")
                    { await Wait(() => !Dialog()!.IsPrimaryButtonEnabled); if (repo.PreferenceChange?.Pending != true) throw new InvalidOperationException("未知保存未保留。"); }
                    else
                    {
                        await Wait(() => Dialog() is null);
                        if (state == "pref-shared-source-disabled")
                        { if (model.SelectedSpace == SynologyPhotoSpace.Shared || model.Preview.Photo is not null || model.Spaces.Contains(SynologyPhotoSpace.Shared)) throw new InvalidOperationException("停用后仍保留旧图库预览或访问入口。"); }
                        else if (state == "pref-shared-category-off")
                        { if (model.Category is not null || model.Section != SynologyPhotosSection.Albums || model.Categories.Contains(SynologyPhotoCategory.People)) throw new InvalidOperationException("关闭识别后仍停留在旧分类。"); }
                        else if (model.SelectedMonth != month || !model.Items.Select(item => item.Id).SequenceEqual(ids)) throw new InvalidOperationException("共享设置清空个人月份或照片。");
                        if (state == "pref-shared-save" && ((GridView)page.FindName("LibraryGrid")).SelectedItems.Count != 2) throw new InvalidOperationException("共享设置丢失个人照片选择。");
                        await Open(); await Wait(() => Nodes(Dialog()!).OfType<ToggleSwitch>().Count() == 4);
                    }
                }
            }
            await Task.Delay(140); Dialog()!.UpdateLayout(); await WriteSnapshotAsync(Dialog()!, markComplete: false); verified = true;
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
