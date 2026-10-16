using LanStash.App.Features.NasAdmin;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.ViewModels;

public partial class SmokeNasServiceSettingsRepository
{
    private NasPackageInstallProgress? _centerProgress;
    private NasPackageCenterSettings _centerSettings = new(false, false, true, NasPackageUpdatePolicy.Manual, "/synthetic-one",
        [new("/synthetic-one", "Synthetic volume 1"), new("/synthetic-two", "Synthetic volume 2")], [new("synthetic", "Synthetic Package", true, NasPackageSingleUpdatePolicy.Manual)]);
    private IReadOnlyList<NasPackageSource> _centerSources = [new("Synthetic Source", "https://packages.invalid")];
    public bool InstallationTokenCanCancel { get; private set; }
    private static NasPackageCatalogEntry CenterEntry(string id, bool beta = false, bool official = true, bool update = false) =>
        new(id, "Synthetic " + id, "2.0", "<p>Synthetic package description.</p>", "<b>Synthetic release notes</b>", "Synthetic publisher", ["tools"], beta, official, 1024, update ? "1.0" : null, update);
    private static NasPackageInstallConfiguration CenterConfiguration() => new("Synthetic Package", "2.0", "<p>Synthetic license terms.</p>",
        [new("description", "Synthetic setup instructions", NasPackageOptionKind.Description, new(Text: ""), []),
         new("name", "Synthetic name", NasPackageOptionKind.Text, new(Text: "Example"), [], Required: true, MinimumLength: 1, MaximumLength: 30),
         new("password", "Synthetic password", NasPackageOptionKind.Password, new(Text: ""), []),
         new("enabled", "Synthetic option", NasPackageOptionKind.Toggle, new(Flag: true), []),
         new("first", "Synthetic first choice", NasPackageOptionKind.Radio, new(Flag: true), [], "group"),
         new("second", "Synthetic second choice", NasPackageOptionKind.Radio, new(Flag: false), [], "group"),
         new("mode", "Synthetic mode", NasPackageOptionKind.Choice, new(Text: "one"), [new("one", "Synthetic one"), new("two", "Synthetic two")])],
        [new("/synthetic-one", "Synthetic volume 1")], "/synthetic-one", true, false);
    private bool TryPackageCenter(string name, object?[]? args, out object? result)
    {
        result = null; var permitted = State != "pkg-center-protected";
        switch (name)
        {
            case "get_PackageCenterAvailability": result = new NasPackageCenterAvailability(true, permitted, permitted, true, true, permitted, permitted); return true;
            case "LoadPackageCatalogAsync": result = ReadCenterCatalogAsync((CancellationToken)args![0]!); return true;
            case "GetPackageInstallationAsync":
                if (State is "pkg-center-options" or "pkg-center-configure") _centerProgress ??= new(Guid.NewGuid(), "Synthetic Package", 0, 1, NasPackageInstallPhase.NeedsOptions, Configuration: CenterConfiguration(), CanCancel: true);
                if (State == "pkg-center-unknown") _centerProgress ??= new(Guid.NewGuid(), "", 0, 1, NasPackageInstallPhase.Interrupted);
                result = Task.FromResult(_centerProgress); return true;
            case "LoadPackageActivitiesAsync": result = Task.FromResult<IReadOnlyList<NasPackageActivity>>([]); return true;
            case "PreparePackageInstallationAsync": result = PrepareCenterAsync(); return true;
            case "StartPackageInstallationAsync": result = StartCenterAsync((NasPackageInstallRequest)args![0]!, (CancellationToken)args[1]!); return true;
            case "ConfigurePackageInstallationAsync":
                var options = (NasPackageConfigureRequest)args![0]!;
                if (!options.LicenseAccepted || !options.RiskConfirmed || !CenterConfiguration().Accepts(options.Values)) throw new InvalidOperationException("安装选项或许可确认丢失。");
                Writes++; _centerProgress = new(options.ActivityId, "Synthetic Package", 1, 1, NasPackageInstallPhase.Completed); result = Task.FromResult(_centerProgress); return true;
            case "LoadPackageCenterSettingsAsync": result = Task.FromResult(_centerSettings); return true;
            case "SavePackageCenterSettingsAsync":
                var settings = (NasPackageSettingsRequest)args![0]!;
                if (!settings.RiskConfirmed || settings.Baseline != _centerSettings) throw new InvalidOperationException("套件设置原快照丢失。");
                Writes++; _centerSettings = settings.Desired; result = Task.FromResult(new NasPackageActivity(settings.RequestId, NasPackageActivityKind.Settings, DateTimeOffset.UtcNow, NasPackageStepStage.Confirmed, true, true, 1, 1)); return true;
            case "LoadPackageSourcesAsync": result = Task.FromResult(_centerSources); return true;
            case "SavePackageSourceAsync":
                var source = (NasPackageSourceRequest)args![0]!; if (!source.RiskConfirmed) throw new InvalidOperationException("来源确认丢失。");
                Writes++; _centerSources = source.Desired is { } desired ? [desired] : [];
                result = Task.FromResult(new NasPackageActivity(source.RequestId, NasPackageActivityKind.SaveSource, DateTimeOffset.UtcNow, NasPackageStepStage.Confirmed, true, true, 1, 1)); return true;
            default: return false;
        }
    }
    private async Task<NasPackageCatalog> ReadCenterCatalogAsync(CancellationToken token)
    {
        if (State == "pkg-center-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "pkg-center-error") throw new IOException("合成套件目录读取失败");
        return new(State == "pkg-center-empty" ? [] : [CenterEntry("Package"), CenterEntry("Update", update: true), CenterEntry("Beta", beta: true), CenterEntry("Community", official: false)],
            [new("tools", "Synthetic tools")], State != "pkg-center-community-error");
    }
    private async Task<NasPackageInstallPlan> PrepareCenterAsync()
    {
        if (State == "pkg-center-cancel-prepare") await Task.Delay(350);
        return new(Guid.NewGuid(), Guid.Parse("11111111-1111-1111-1111-111111111111"),
            [new(CenterEntry("Package"), [new("/synthetic-one", "Synthetic volume 1"), new("/synthetic-two", "Synthetic volume 2")], "/synthetic-one")], ["Synthetic dependent service"]);
    }
    private async Task<NasPackageInstallProgress> StartCenterAsync(NasPackageInstallRequest request, CancellationToken token)
    {
        if (!request.RiskConfirmed || request.Volumes.Count != 1) throw new InvalidOperationException("安装缺少确认或位置。");
        Writes++; InstallationTokenCanCancel = token.CanBeCanceled;
        if (State == "pkg-center-close-install") await Task.Delay(800);
        _centerProgress = new(request.RequestId, "Synthetic Package", 0, 1, NasPackageInstallPhase.Installing, .25); return _centerProgress;
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task ExercisePackageCenterAsync(ContentDialog dialog, SmokeNasServiceSettingsRepository fake, string state)
    {
        var content = (NasPackageSettingsDialogContent)dialog.Content;
        async Task Snapshot() { await Task.Delay(160); await WriteSnapshotAsync(dialog); }
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        void Click(string name) => typeof(NasPackageSettingsDialogContent).GetMethod(name, System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.Invoke(content, [content, new RoutedEventArgs()]);
        if (state == "pkg-center-loading")
        { if (!Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("目录加载状态缺失。"); await Snapshot(); return; }
        if (state == "pkg-center-error")
        { if (!Control<InfoBar>("CenterErrorNotice").IsOpen) throw new InvalidOperationException("目录错误未显示。"); await Snapshot(); return; }
        if (state is "pkg-center-settings" or "pkg-center-save-settings" or "pkg-center-policy")
        {
            Click("Preferences_Click"); await Task.Delay(80);
            if (Control<StackPanel>("PreferencesPanel").Visibility != Visibility.Visible) throw new InvalidOperationException("套件设置未打开。");
            if (state == "pkg-center-policy") Control<ComboBox>("UpdatePolicy").SelectedIndex = 3;
            if (state == "pkg-center-save-settings")
            {
                Control<CheckBox>("EmailEnabled").IsChecked = true; Click("SavePreferences_Click");
                if (fake.Writes != 0) throw new InvalidOperationException("套件设置未确认即写入。"); Click("ConfirmCenter_Click"); await Task.Delay(80);
                if (fake.Writes != 1 || !Control<InfoBar>("CenterFeedbackNotice").IsOpen) throw new InvalidOperationException("套件设置保存失败。");
            }
            await Snapshot(); return;
        }
        if (state is "pkg-center-sources" or "pkg-center-add-source" or "pkg-center-remove-source" or "pkg-center-source-invalid")
        {
            Click("Sources_Click"); await Task.Delay(80);
            if (Control<ListView>("SourceList").Items.Count != 1) throw new InvalidOperationException("来源未显示。");
            if (state == "pkg-center-remove-source") { Control<ListView>("SourceList").SelectedIndex = 0; Click("RemoveSource_Click"); }
            else if (state != "pkg-center-sources")
            { Click("NewSource_Click"); Control<TextBox>("SourceName").Text = "Synthetic new"; Control<TextBox>("SourceUrl").Text = state == "pkg-center-source-invalid" ? "https://user:password@source.invalid" : "http://source.invalid"; Click("SaveSource_Click"); }
            if (state == "pkg-center-source-invalid")
            { if (!Control<InfoBar>("CenterErrorNotice").IsOpen || fake.Writes != 0) throw new InvalidOperationException("无效来源未拒绝。"); }
            else if (state != "pkg-center-sources")
            { if (fake.Writes != 0) throw new InvalidOperationException("来源未确认即写入。"); Click("ConfirmCenter_Click"); await Task.Delay(80); if (fake.Writes != 1) throw new InvalidOperationException("来源确认没有写入。"); }
            await Snapshot(); return;
        }
        if (state is "pkg-center-options" or "pkg-center-configure")
        {
            if (Control<StackPanel>("InstallFields").Children.Count != 7) throw new InvalidOperationException("原生安装字段缺失。");
            if (Control<TextBlock>("LicenseText").Text.Contains('<')) throw new InvalidOperationException("许可未转为纯文本。");
            Click("Configure_Click"); if (fake.Writes != 0) throw new InvalidOperationException("未接受许可即安装。");
            if (state == "pkg-center-options")
            {
                await Task.Delay(2200);
                if (!Control<InfoBar>("CenterErrorNotice").IsOpen) throw new InvalidOperationException("后台读取清除了尚未处理的表单错误。");
                if (Control<ScrollViewer>("ContentScroll").VerticalOffset > 1) throw new InvalidOperationException("表单错误未完整进入可视区域。");
            }
            if (state == "pkg-center-configure")
            { Control<CheckBox>("AcceptLicense").IsChecked = true; Click("Configure_Click"); await Task.Delay(80); if (fake.Writes != 1) throw new InvalidOperationException("原生设置未提交。"); }
            await Snapshot(); return;
        }
        if (state == "pkg-center-unknown")
        { if (Control<Button>("StartButton").IsEnabled || Control<Button>("UploadButton").IsEnabled) throw new InvalidOperationException("未知安装未保护套件写入。"); await Snapshot(); return; }
        Control<ComboBox>("SectionChoice").SelectedIndex = state == "pkg-center-updates" ? 1 : state == "pkg-center-beta" ? 3 : state == "pkg-center-community-error" ? 4 : 2;
        await Task.Delay(70); var list = Control<ListView>("CatalogList");
        if (state == "pkg-center-empty")
        { if (list.Items.Count != 0 || Control<TextBlock>("CatalogEmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("空目录没有恢复提示。"); }
        else if (state == "pkg-center-filter")
        { Control<TextBox>("CatalogSearchInput").Text = "no-match"; await Task.Delay(80); if (list.Items.Count != 0) throw new InvalidOperationException("目录筛选错误。"); }
        else
        {
            if (list.Items.Count == 0) throw new InvalidOperationException("套件目录缺失。"); list.SelectedIndex = 0;
            if (state is "pkg-center-prepare" or "pkg-center-install" or "pkg-center-close-install" or "pkg-center-cancel-prepare" or "pkg-center-protected")
            {
                Click("Prepare_Click");
                if (state == "pkg-center-cancel-prepare")
                { Click("CancelPreparation_Click"); await Task.Delay(450); if (Control<StackPanel>("PreparationPanel").Visibility == Visibility.Visible) throw new InvalidOperationException("取消准备后迟到计划复活。"); }
                else
                {
                    await Task.Delay(80); if (Control<StackPanel>("PlanItems").Children.Count != 2 || fake.Writes != 0) throw new InvalidOperationException("依赖安装准备缺失或发生写入。");
                    if (state == "pkg-center-protected") { if (Control<Button>("InstallButton").IsEnabled || Control<Button>("UploadButton").IsEnabled) throw new InvalidOperationException("安装保护失效。"); }
                    else if (state is "pkg-center-install" or "pkg-center-close-install")
                    { Click("Install_Click"); await Task.Delay(80); if (fake.Writes != 1 || fake.InstallationTokenCanCancel) throw new InvalidOperationException("安装未归属原连接或重复提交。"); }
                    else if (!Control<Button>("InstallButton").Focus(FocusState.Keyboard)) throw new InvalidOperationException("安装确认不可键盘聚焦。");
                }
            }
        }
        await Snapshot();
    }
}
