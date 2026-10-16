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
    private SynologyPhotoGlobalSettings? _globalPreferences;
    internal SynologyPhotoGlobalSettings GlobalPreferences => _globalPreferences ??= new(ProfileId, 19,
        State == "pref-global-empty" ? null : true, State == "pref-global-empty" ? null : true, State == "pref-global-empty" ? null : true,
        State == "pref-global-empty" ? null : true, State == "pref-global-empty" ? null : false, State == "pref-global-empty" ? null : true,
        State == "pref-global-empty" ? null : ["RAW", "legacy.ext"], State != "pref-global-codec", true, true, SynologyPhotoSharedRole.Management, true, true, true, true, true, true);
    internal int CacheWrites;
    public async Task<SynologyPhotoGlobalSettings> GlobalSettingsAsync(CancellationToken cancellationToken = default)
    {
        if (State == "pref-global-loading") await PreferenceRelease.Task.WaitAsync(cancellationToken);
        if (State == "pref-global-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return GlobalPreferences;
    }
    public Task<SynologyPhotoConversionCache> ConversionCacheAsync(CancellationToken cancellationToken = default) =>
        State == "pref-global-cache-error" ? Task.FromException<SynologyPhotoConversionCache>(new IOException()) : Task.FromResult(new SynologyPhotoConversionCache(ProfileId, 19, CacheWrites == 0 ? 5242880 : 512, State == "pref-global-clearing"));
    public async Task<SynologyPhotoSettingsChange> SetGlobalSettingsAsync(Guid operationId, SynologyPhotoGlobalSettings original, SynologyPhotoGlobalSettings updated, bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (!confirmed) throw new InvalidOperationException("全局设置提交前缺少确认。"); PreferenceWrites++;
        if (State == "pref-global-close") await PreferenceRelease.Task;
        var pending = State == "pref-global-unknown"; var partial = State is "pref-global-partial" or "pref-global-category-partial";
        _globalPreferences = pending ? original : partial ? updated with { PersonalPeople = true, SharedPeople = true } : updated;
        PreferenceChange = new(operationId, null, pending ? SynologyPhotoChangeState.PendingReview : partial ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Completed, false)
        { Global = new(original, updated), GlobalResult = _globalPreferences, CompletedSteps = partial ? 1 : pending ? 0 : 3, TotalSteps = 3 };
        return PreferenceChange;
    }
    public Task<SynologyPhotoSettingsChange> ClearConversionCacheAsync(Guid operationId, SynologyPhotoConversionCache original, bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (!confirmed) throw new InvalidOperationException("缓存清理前缺少确认。"); CacheWrites++;
        return Task.FromResult(PreferenceChange = new(operationId, null, SynologyPhotoChangeState.Completed, false)
        { Cache = original, CacheResult = original with { SizeBytes = 512 }, CompletedSteps = 1, TotalSteps = 1 });
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoGlobalPreferencesAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        if (state == "pref-global-cold") repo.PreferenceChange = new(Guid.NewGuid(), null, SynologyPhotoChangeState.PendingReview, false)
        { Global = new(repo.GlobalPreferences, repo.GlobalPreferences with { GuestInfo = true }) };
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(180);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!; await model.LoadIfNeededAsync();
        if (state.StartsWith("pref-global-category", StringComparison.Ordinal) || state == "pref-global-close")
        { await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCategoryAsync(SynologyPhotoCategory.People); if (model.Category != SynologyPhotoCategory.People || model.Collections.Count == 0) throw new InvalidOperationException("人物分类没有实际打开。"); }
        var month = model.SelectedMonth; var ids = model.Items.Select(item => item.Id).ToArray(); var l = Localization.LocalizationService.Current; var verified = false;
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        async Task Wait(Func<bool> ready) { for (var i = 0; i < 180 && !ready(); i++) await Task.Delay(30); if (!ready()) throw new InvalidOperationException("全局设置界面未达到预期状态。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject node) { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(node, i))) yield return child; }
        static void Click(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
        ToggleSwitch Toggle(string key) => Nodes(Dialog()!).OfType<ToggleSwitch>().Single(value => AutomationProperties.GetAutomationId(value) == key);
        Button Button(string id) => Nodes(Dialog()!).OfType<Button>().Single(value => AutomationProperties.GetAutomationId(value) == id);
        Button Primary(string key) => Nodes(Dialog()!).OfType<Button>().Single(value => value.Name == "PrimaryButton" && Equals(value.Content, l.Get(key)));
        try
        {
            var menu = (MenuFlyoutItem)page.FindName("PhotoGlobalSettingsMenu");
            if (state == "pref-global-nonadmin")
            { if (menu.Visibility != Visibility.Collapsed) throw new InvalidOperationException("普通用户出现全局管理入口。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
            if (state == "pref-global-save")
            {
                var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(70);
                ((IInvokeProvider)new MenuFlyoutItemAutomationPeer((MenuFlyoutItem)page.FindName("SelectPhotosMenu")).GetPattern(PatternInterface.Invoke)).Invoke();
                var grid = (GridView)page.FindName("LibraryGrid"); await Wait(() => grid.SelectionMode == ListViewSelectionMode.Multiple && grid.Items.Count > 2);
                grid.SelectedItems.Add(grid.Items[0]); grid.SelectedItems.Add(grid.Items[1]);
            }
            var moreButton = (Button)page.FindName("MoreButton"); moreButton.Flyout.ShowAt(moreButton); await Task.Delay(70);
            ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(menu).GetPattern(PatternInterface.Invoke)).Invoke(); await Wait(() => Dialog()?.IsLoaded == true);
            if (state is "pref-global-loading" or "pref-global-error" or "pref-global-cold")
            { await Task.Delay(160); if (Dialog()!.IsPrimaryButtonEnabled || repo.PreferenceWrites != 0) throw new InvalidOperationException("未就绪时允许保存。"); }
            else
            {
                await Wait(() => Nodes(Dialog()!).OfType<ToggleSwitch>().Count() == (state == "pref-global-empty" ? 0 : 6) && Nodes(Dialog()!).OfType<TextBlock>().Any(value => value.Text.Contains(l.Get("PhotosConversionCache"), StringComparison.Ordinal)));
                await Task.Delay(120);
                if (state == "pref-global-codec" && Toggle("PhotosGlobalOriginalJpeg").IsEnabled) throw new InvalidOperationException("缺编解码支持时可修改JPEG。");
                if (state == "pref-global-locked" && (Toggle("PhotosGlobalUserSharing").IsEnabled || Toggle("PhotosGlobalGuestInfo").IsEnabled || !Toggle("PhotosCategoryPeople").IsEnabled)) throw new InvalidOperationException("专项安全保护范围错误。");
                if (state is "pref-global-clearing" or "pref-global-cache-error")
                { if (Button("PhotoClearConversionCache").IsEnabled) throw new InvalidOperationException("无可清理缓存时可以提交。"); Toggle("PhotosCategoryPeople").IsOn = false; await Wait(() => Dialog()!.IsPrimaryButtonEnabled); }
                if (state is "pref-global-save" or "pref-global-confirm" or "pref-global-unknown" or "pref-global-partial" or "pref-global-clear" or "pref-global-formats" or "pref-global-category-off" or "pref-global-category-partial" or "pref-global-close")
                {
                    Toggle("PhotosCategoryPeople").IsOn = false; await Wait(() => Dialog()!.IsPrimaryButtonEnabled);
                    if (state == "pref-global-formats")
                    {
                        var expander = Nodes(Dialog()!).OfType<Expander>().Single(); expander.IsExpanded = true;
                        await Wait(() => Nodes(Dialog()!).OfType<CheckBox>().Any(value => Equals(value.Content, "legacy.ext")));
                        Nodes(Dialog()!).OfType<CheckBox>().Single(value => Equals(value.Content, "legacy.ext")).IsChecked = false;
                        Nodes(Dialog()!).OfType<CheckBox>().Single(value => Equals(value.Content, "PNG")).IsChecked = true;
                    }
                    if (state == "pref-global-clear") Click(Button("PhotoClearConversionCache")); else Click(Primary("PhotosSaveChanges"));
                    await Wait(() => Dialog()!.PrimaryButtonText == l.Get(state == "pref-global-clear" ? "PhotosClearConversionCache" : "PhotosSharedConfirm"));
                    if (repo.PreferenceWrites + repo.CacheWrites != 0) throw new InvalidOperationException("确认前已提交。");
                    if (state == "pref-global-confirm") { await WriteSnapshotAsync(Dialog()!, markComplete: false); verified = true; return; }
                    Click(Primary(state == "pref-global-clear" ? "PhotosClearConversionCache" : "PhotosSharedConfirm"));
                    await Wait(() => repo.PreferenceWrites + repo.CacheWrites == 1);
                    if (state == "pref-global-close") { Dialog()!.Hide(); repo.PreferenceRelease.TrySetResult(); }
                    if (state == "pref-global-clear")
                    { await Wait(() => Dialog()!.PrimaryButtonText == l.Get("PhotosSaveChanges")); if (Toggle("PhotosCategoryPeople").IsOn || !Dialog()!.IsPrimaryButtonEnabled) throw new InvalidOperationException("清缓存丢失了尚未保存的设置草稿。"); }
                    else if (state is "pref-global-unknown" or "pref-global-partial") await Wait(() => !Dialog()!.IsPrimaryButtonEnabled);
                    else
                    {
                        await Wait(() => Dialog() is null);
                        if (state.StartsWith("pref-global-category", StringComparison.Ordinal) || state == "pref-global-close")
                        { if (model.Category is not null || model.Section != SynologyPhotosSection.Albums) throw new InvalidOperationException("实际关闭分类后没有回到相册。"); }
                        else if (model.SelectedMonth != month || !ids.SequenceEqual(model.Items.Select(item => item.Id))) throw new InvalidOperationException("全局设置刷新了照片位置。");
                        if (state == "pref-global-save" && ((GridView)page.FindName("LibraryGrid")).SelectedItems.Count != 2) throw new InvalidOperationException("保存设置丢失多选。");
                        if (state == "pref-global-formats" && (repo.GlobalPreferences.ExcludedExtensions!.Contains("legacy.ext") || !repo.GlobalPreferences.ExcludedExtensions!.Contains("PNG"))) throw new InvalidOperationException("格式选择未保存。");
                    }
                }
            }
            await Task.Delay(120); await WriteSnapshotAsync(Dialog() is { IsLoaded: true } dialog ? dialog : page, markComplete: false); verified = true;
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
