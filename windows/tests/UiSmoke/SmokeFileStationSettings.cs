using LanStash.App.Features.Files.Settings;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.ViewModels;

internal sealed class SmokeFileStationSettingsRepository(string state) : IFileStationThemeRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public int Writes, Reviews; private FileStationSettingsProgress? _pending;
    public Task<bool> CanWriteFileStationSettingsAsync(CancellationToken token) => Task.FromResult(state is not ("readonly" or "theme-readonly"));
    public async Task<FileStationTheme> LoadFileStationThemeAsync(CancellationToken token)
    {
        if (state == "theme-loading") await Task.Delay(Timeout.Infinite, token);
        if (state == "theme-error") throw new InvalidDataException("synthetic");
        return new(ProfileId, true, FileStationLogoPosition.TopRight, true, FileStationBackgroundPosition.Fill, "#234567", "Example sharing page", false, "logo", "background");
    }
    public Task<IReadOnlyList<FileStationThemeImage>> ListFileStationThemeImagesAsync(FileStationThemeImageKind kind, CancellationToken token) =>
        Task.FromResult<IReadOnlyList<FileStationThemeImage>>(state == "theme-empty" ? [] : [new(kind, FileStationThemeImageSource.History, "history/example.png", "Example image", 0)]);
    public Task<byte[]> ReadFileStationThemeImageAsync(FileStationThemeImage image, CancellationToken token) => Task.FromResult(ThemeBytes);
    public static byte[] ThemeBytes => Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGPQqDgBAAI0AWkYRiUPAAAAAElFTkSuQmCC");
    public Task<FileStationThemeUploadResult> UploadFileStationThemeImageAsync(FileStationThemeImageKind kind, string filename, ReadOnlyMemory<byte> content, bool confirmed, CancellationToken token)
    {
        if (!confirmed || state == "theme-readonly") throw new InvalidOperationException("图片上传缺少确认或权限。");
        return Task.FromResult(new FileStationThemeUploadResult(new(1, state == "theme-upload-unknown" ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess,
            "fileThemeUpload", true, state == "theme-upload-unknown", new(state == "theme-upload-unknown" ? 0 : 1, 0, state == "theme-upload-unknown" ? 1 : 0)),
            state == "theme-upload-unknown" ? null : new(kind, FileStationThemeImageSource.History, "history/uploaded.png", filename, 1)));
    }
    public async Task<FileStationGeneralSettings> LoadFileStationSettingsAsync(CancellationToken token)
    {
        if (state == "loading") await Task.Delay(Timeout.Infinite, token);
        if (state == "error") throw new InvalidDataException("synthetic");
        return new(ProfileId, false, true, false, FileStationAccess.Administrators, FileStationAccess.Administrators,
            FileStationAccess.Administrators, FileStationAccess.Administrators, [], [], 0, FileStationBandwidthPolicy.Disabled, "", false);
    }
    public Task<IReadOnlyList<FileStationPolicyAccount>> ListFileStationPolicyAccountsAsync(FileSharePrincipalKind kind, CancellationToken token) => Task.FromResult<IReadOnlyList<FileStationPolicyAccount>>([
        new(new(kind, 1), kind == FileSharePrincipalKind.User ? "Sample user" : "Example team", false), new(new(kind, 2), "Administrators", true)]);
    public Task<FileStationMountAccess> LoadFileStationMountAccessAsync(CancellationToken token) => Task.FromResult(new FileStationMountAccess(ProfileId, FileStationAccess.Selected));
    public Task<FileStationDirectories> LoadFileStationDirectoriesAsync(CancellationToken token) => Task.FromResult(new FileStationDirectories([
        new(FileStationDirectoryKind.Local), new(FileStationDirectoryKind.Ldap), new(FileStationDirectoryKind.Domain, "example-request", "Example domain")], state == "sources"));
    public Task<IReadOnlyList<FileStationMountAccount>> ListFileStationMountAccountsAsync(FileStationDirectory source, FileSharePrincipalKind kind, CancellationToken token) =>
        Task.FromResult<IReadOnlyList<FileStationMountAccount>>(state == "empty" ? [] : [new(ProfileId, source, new(kind, 1), "Sample account", false, true), new(ProfileId, source, new(kind, 2), "Administrators", true, false)]);
    public Task<IReadOnlyList<FileStationBandwidth>> ListFileStationBandwidthAsync(FileStationBandwidthOwner owner, CancellationToken token) => Task.FromResult<IReadOnlyList<FileStationBandwidth>>([
        new(ProfileId, "Sample account", owner, FileStationBandwidthPolicy.NotConfigured, "", 0, 0, 0, 0), new(ProfileId, "Example team", owner, FileStationBandwidthPolicy.Enabled, "", 128, 512, 0, 0)]);
    public Task<FileStationSettingsProgress> SaveFileStationSettingAsync(FileStationSettingsChange change, CancellationToken token)
    {
        if (!change.IsValid || state == "readonly") throw new InvalidOperationException("设置保存缺少授权或确认。"); Writes++;
        var result = Result(change, state == "unknown"); _pending = result.Outcome.RequiresRefresh ? result : null; return Task.FromResult(result);
    }
    public Task<IReadOnlyList<FileStationSettingsProgress>> GetFileStationSettingsOperationsAsync(CancellationToken token) => Task.FromResult<IReadOnlyList<FileStationSettingsProgress>>(_pending is null ? [] : [_pending]);
    public Task<FileStationSettingsProgress?> ReviewFileStationSettingAsync(Guid id, CancellationToken token) { Reviews++; return Task.FromResult(_pending); }
    private static FileStationSettingsProgress Result(FileStationSettingsChange change, bool pending) => new(change, new(1,
        pending ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess, "fileStationSettings", true, pending, new(pending ? 0 : 1, 0, pending ? 1 : 0)));
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveFileStationSettingsAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "general";
        var repository = new SmokeFileStationSettingsRepository(state); using var model = new FileStationSettingsViewModel(repository);
        using var dialog = new FileStationSettingsDialog(model, root.XamlRoot); var opening = dialog.ShowAsync().AsTask(); await Task.Delay(250);
        if (state.StartsWith("theme", StringComparison.Ordinal))
        {
            var loading = model.SelectSectionAsync(FileStationSettingsSection.Theme);
            if (state != "theme-loading") await loading; else await Task.Delay(100);
            if (state is "theme-picker" or "theme-empty" or "theme-filtered" or "theme-default" or "theme-preview" or "theme-upload" or "theme-upload-unknown")
            {
                await model.OpenThemePickerAsync(FileStationThemeImageKind.Background);
                if (state is "theme-default" or "theme-preview") await model.SetThemeSourceAsync(FileStationThemeImageSource.Default);
                if (state == "theme-filtered") model.SetThemeFilter("missing");
                if (state == "theme-preview") await model.PreviewThemeImageAsync(model.ThemeImages[9]);
                if (state is "theme-upload" or "theme-upload-unknown") await model.UploadThemeImageAsync("Example.png", SmokeFileStationSettingsRepository.ThemeBytes);
                if (state is "theme-preview" or "theme-upload")
                {
                    if (!model.CanUseThemeImage || repository.Writes != 0 || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("图片选择或独立保存边界错误。");
                }
                if (state == "theme-upload-unknown" && model.CanUseThemeImage) throw new InvalidOperationException("未知上传变成可应用图片。");
            }
            else if (state == "theme-run")
            {
                dialog.UpdateLayout(); await Task.Delay(100);
                Nodes(dialog).OfType<TextBox>().Single(b => AutomationProperties.GetAutomationId(b) == "FsThemeFooter").Text = "New footer";
                await Task.Delay(100);
                if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("外观草稿未启用保存。");
                Invoke(Nodes(dialog).OfType<Button>().Single(b => Equals(b.Content, dialog.PrimaryButtonText))); await Task.Delay(100);
                if (repository.Writes != 1) throw new InvalidOperationException("外观保存入口未提交。");
            }
            if (state == "theme-readonly" && model.CanEdit || state == "theme-error" && !model.LoadFailed || state == "theme-loading" && !model.IsBusy) throw new InvalidOperationException("外观五态错误。");
        }
        else if (state is "mount" or "accounts" or "sources" or "empty" or "filtered" or "locked")
        {
            await model.SelectSectionAsync(state == "mount" ? FileStationSettingsSection.MountAccess : FileStationSettingsSection.MountAccounts);
            if (state is "accounts" or "locked" or "sources") Nodes(dialog).OfType<ListView>().Single().SelectedIndex = state == "locked" ? 1 : 0;
            if (state == "filtered") Nodes(dialog).OfType<TextBox>().Single(b => AutomationProperties.GetAutomationId(b) == "FsSettingsFilter").Text = "missing";
            if (state == "locked" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("受保护账号仍可保存。");
        }
        else if (state is "bandwidth" or "schedule")
        {
            await model.SelectSectionAsync(FileStationSettingsSection.Bandwidth); Nodes(dialog).OfType<ListView>().Single().SelectedIndex = 0;
            if (model.Draft is not FileStationBandwidth { Policy: FileStationBandwidthPolicy.NotConfigured } value) throw new InvalidOperationException("未配置限速被改写。");
            if (state == "schedule")
            {
                var choice = Nodes(dialog).OfType<ComboBox>().Single(c => AutomationProperties.GetAutomationId(c) == "FsSettingsAccountPolicy"); choice.SelectedIndex = 2;
                if (model.Draft is not FileStationBandwidth { Policy: FileStationBandwidthPolicy.Scheduled, Schedule.Length: 168 }) throw new InvalidOperationException("限速时间表没有建立。");
                dialog.UpdateLayout(); await Task.Delay(100);
                Nodes(dialog).OfType<ComboBox>().Single(c => AutomationProperties.GetAutomationId(c) == "FsSettingsScheduleFillMode").SelectedIndex = 2;
                Invoke(Nodes(dialog).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "FsSettingsScheduleFillDay"));
                var daySchedule = ((FileStationBandwidth)model.Draft).Schedule;
                if (daySchedule[..24] != new string('2', 24) || daySchedule[24..] != new string('1', 144)) throw new InvalidOperationException("整天填充修改了其他日期。");
                Invoke(Nodes(dialog).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "FsSettingsScheduleFillWeek"));
                if (((FileStationBandwidth)model.Draft).Schedule != new string('2', 168) || repository.Writes != 0) throw new InvalidOperationException("整周填充或显式保存边界错误。");
                var scroll = Nodes(dialog).OfType<ScrollViewer>().First(s => s.Content is StackPanel p && p.Children.OfType<ContentControl>().Any());
                scroll.ChangeView(null, scroll.ScrollableHeight, null, disableAnimation: true); await Task.Delay(100);
            }
        }
        else if (state == "members")
        {
            var choice = Nodes(dialog).OfType<ComboBox>().Single(c => AutomationProperties.GetAutomationId(c) == "FsSettingsSharing"); choice.SelectedIndex = 2;
            dialog.UpdateLayout(); await Task.Delay(100);
            if (model.Draft is not FileStationGeneralSettings { Sharing: FileStationAccess.Selected }) throw new InvalidOperationException("具名授权选择未更新草稿。");
            if (!Nodes(dialog).OfType<CheckBox>().Any(c => c.Tag is FileStationAccountId && c.IsEnabled)) throw new InvalidOperationException("具名授权列表未显示。");
        }
        else if (state is "run" or "unknown")
        {
            Nodes(dialog).OfType<CheckBox>().Single(c => AutomationProperties.GetAutomationId(c) == "FsSettingsRecordTransfers").IsChecked = true;
            if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("普通保存意外需要额外确认。");
            var save = Nodes(dialog).OfType<Button>().Single(b => Equals(b.Content, dialog.PrimaryButtonText));
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(save).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            await Task.Delay(100); if (repository.Writes != 1 || state == "unknown" && (!model.IsPending || dialog.IsPrimaryButtonEnabled)) throw new InvalidOperationException("设置结果或防重复失效。");
        }
        if (state == "readonly" && model.CanEdit || state == "error" && !model.LoadFailed || state == "loading" && !model.IsBusy) throw new InvalidOperationException("设置五态错误。");
        dialog.UpdateLayout(); await Task.Delay(100); await WriteSnapshotAsync(dialog, markComplete: false);
        dialog.Hide(); dialog.Dispose(); await opening.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();
        static IEnumerable<DependencyObject> Nodes(DependencyObject node)
        { yield return node; for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Nodes(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(node, i))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
