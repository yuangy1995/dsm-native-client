using LanStash.App.Features.Files.Locations;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.ViewModels;

internal sealed class SmokeVfsRepository(string state) : IFileVfsCloudRepository, IFileVfsBrowserRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public bool CanManageVfs => state != "readonly";
    public bool CanBrowseVfs => true;
    public bool CanDownloadVfs => state != "readonly";
    public int SourceChecks;
    public async Task<FileVfsFolder> ListVfsFolderAsync(FileVfsProfile profile, string path, CancellationToken token)
    {
        if (state == "loading") await Task.Delay(Timeout.Infinite, token);
        if (state == "error") throw new InvalidDataException("synthetic");
        IReadOnlyList<FileItem> items = state == "empty" ? [] : [
            new(path + "/Folder", "Folder", true, 0, null, null, false, false),
            new(path + "/Example report.pdf", "Example report.pdf", false, 20480, DateTimeOffset.UnixEpoch, null, false, false),
            new(path + "/Notes.txt", "Notes.txt", false, 0, DateTimeOffset.UnixEpoch, null, false, false)];
        return new(profile, path, items);
    }
    public Task ValidateVfsDownloadAsync(FileVfsDownloadSource source, CancellationToken token)
    { if (!source.IsValid) throw new InvalidOperationException("远程下载来源无效。"); SourceChecks++; return Task.CompletedTask; }
    public Task<FileRangeReadResult> ReadVfsRangeAsync(FileVfsDownloadSource source, long offset, long length, string? version, CancellationToken token) => throw new NotSupportedException();
    public int Writes, Reviews;
    private FileVfsProgress? _pending;
    private FileVfsConfiguration _configuration = new("sftp", "remote.invalid", 22, "Example server", "sample", Folder: "Documents");
    private bool _removed;
    private FileVfsProfile? _cloudProfile;
    private FileVfsState _state = state == "remove" ? FileVfsState.Disconnected : FileVfsState.Connected;
    public Task<IReadOnlyList<FileVfsProtocol>> ListVfsProtocolsAsync(CancellationToken token) => Task.FromResult<IReadOnlyList<FileVfsProtocol>>([
        new("sftp", "SFTP", 22, false), new("ftp", "FTP", 21, false), new("dav", "WebDAV", 80, false), new("davs", "WebDAV HTTPS", 443, false), new("google", "Google Drive", 0, false)]);
    public async Task<IReadOnlyList<FileVfsProfile>> ListVfsProfilesAsync(CancellationToken token)
    {
        if (state == "loading") await Task.Delay(Timeout.Infinite, token);
        if (state == "error") throw new InvalidDataException("synthetic");
        if (state.StartsWith("cloud", StringComparison.Ordinal)) return _cloudProfile is null ? [] : [_cloudProfile];
        if (_removed || state is "empty" or "create" or "cleartext" && Writes == 0) return [];
        return [Profile()];
    }
    private FileVfsProfile Profile() => new(ProfileId, "opaque-1", _configuration.Protocol, "SFTP", "sftp://opaque-1",
        _configuration.Hostname, _configuration.Port, _configuration.Alias, _configuration.Account, _configuration.Codepage, _state);
    public Task<FileVfsDetail> LoadVfsDetailAsync(FileVfsProfile profile, CancellationToken token) => Task.FromResult(new FileVfsDetail(profile, _configuration));
    public Task<IReadOnlyList<FileVfsProgress>> GetVfsOperationsAsync(CancellationToken token) => Task.FromResult<IReadOnlyList<FileVfsProgress>>(_pending is null ? [] : [_pending]);
    public Task<FileVfsProgress> ChangeVfsAsync(FileVfsChange change, string? password, CancellationToken token)
    {
        if (!change.Confirmed || change.Configuration?.UsesCleartext == true && !change.ConfirmedCleartext) throw new InvalidOperationException("VFS 缺少确认。");
        if (change.Action == FileVfsAction.Update && password is not null) throw new InvalidOperationException("VFS 保留密码时仍提交密码。");
        Writes++; if (change.Configuration is { } configuration) _configuration = configuration;
        if (change.Action == FileVfsAction.Disconnect) _state = FileVfsState.Disconnected;
        if (change.Action == FileVfsAction.RemoveSavedProfile) _removed = true;
        var result = Result(change, state == "unknown"); _pending = result.Outcome.RequiresRefresh ? result : null; return Task.FromResult(result);
    }
    public Task<FileVfsCloudRequest> PrepareVfsCloudAsync(string protocol, FileVfsProfile? existing, CancellationToken token) => Task.FromResult(new FileVfsCloudRequest(
        Guid.NewGuid(), ProfileId, protocol, new("https://synooauth.synology.com/FileStation/Cloud/login.php?major=7&minor=2&type=google"), DateTimeOffset.UtcNow.AddMinutes(10), existing));
    public void CancelVfsCloud(Guid id) { }
    public Task<FileVfsProgress> AuthorizeVfsAsync(FileVfsChange change, FileVfsCloudAuthorization authorization, CancellationToken token)
    {
        if (!change.Confirmed || change.CloudIdentity?.Account != authorization.Account) throw new InvalidOperationException("云连接缺少原账号确认。");
        Writes++; var identity = change.CloudIdentity!;
        _cloudProfile = new(ProfileId, "opaque-cloud", identity.Protocol, "Google Drive", "google://opaque-cloud", "", null, identity.Alias, identity.Account, null, FileVfsState.Connected);
        var result = Result(change, state == "cloud-unknown"); _pending = result.Outcome.RequiresRefresh ? result : null; return Task.FromResult(result);
    }
    public Task<FileVfsProgress?> ReviewVfsAsync(Guid id, CancellationToken token)
    { Reviews++; var result = _pending is null ? null : Result(_pending.Change, false); _pending = null; return Task.FromResult(result); }
    private static FileVfsProgress Result(FileVfsChange change, bool pending) => new(change,
        new(1, pending ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess, "fileVfs", true, pending, new(pending ? 0 : 1, 0, pending ? 1 : 0)));
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveVfsBrowserAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "list";
        var repository = new SmokeVfsRepository(state);
        var profile = new FileVfsProfile(repository.ProfileId, "opaque-1", "sftp", "SFTP", "sftp://opaque-1", "remote.invalid", 22, "Example server", "sample", "UTF-8", FileVfsState.Connected);
        using var model = new FileVfsBrowserViewModel(repository, profile); var downloads = 0;
        using var dialog = new FileVfsBrowserDialog(model, root.XamlRoot, async (source, current, token) =>
        {
            if (!current()) throw new InvalidOperationException("浏览来源已失效。");
            await repository.ValidateVfsDownloadAsync(source, token);
            if (state == "download-error") throw new IOException("synthetic");
            downloads++; return true;
        });
        var showing = dialog.ShowAsync().AsTask(); await Task.Delay(250);
        if (state == "loading" && !model.IsBusy || state == "error" && !model.HasError || state == "empty" && model.Items.Count != 0)
            throw new InvalidOperationException("远程浏览五态错误。");
        if (state == "filtered") Nodes(dialog).OfType<TextBox>().Single(box => AutomationProperties.GetAutomationId(box) == "VfsBrowserFilter").Text = "missing";
        if (state is "navigate" or "download" or "download-error" or "readonly")
        {
            var list = Nodes(dialog).OfType<ListView>().Single();
            list.SelectedIndex = state == "navigate" ? 0 : 1;
            if (state == "navigate")
            {
                await Click(ById("VfsBrowserOpen")); if (!model.CanUp || !model.Path.EndsWith("/Folder", StringComparison.Ordinal)) throw new InvalidOperationException("远程文件夹未打开。");
                await Click(ById("VfsBrowserUp")); if (model.CanUp || model.Path != profile.Uri) throw new InvalidOperationException("远程上一级越过根目录。");
            }
            else if (state == "readonly") { if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("下载能力缺失仍可提交。"); }
            else
            {
                await Click(Nodes(dialog).OfType<Button>().Single(b => Equals(b.Content, dialog.PrimaryButtonText)));
                if (repository.SourceChecks != 1 || state == "download" && (downloads != 1 || !model.DownloadStarted) || state == "download-error" && (!model.DownloadFailed || downloads != 0))
                    throw new InvalidOperationException("远程下载未保持显式提交/失败恢复。");
            }
        }
        dialog.UpdateLayout(); await Task.Delay(100); await WriteSnapshotAsync(dialog, markComplete: false);
        dialog.Hide(); dialog.Dispose(); await showing.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();
        Button ById(string id) => Nodes(dialog).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == id);
        static IEnumerable<DependencyObject> Nodes(DependencyObject element)
        { yield return element; for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(element); i++) foreach (var child in Nodes(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(element, i))) yield return child; }
        static async Task Click(Button button)
        { ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke(); await Task.Delay(120); }
    }

    private static async Task SaveVfsAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "edit";
        var repository = new SmokeVfsRepository(state);
        using var model = new FileVfsViewModel(repository);
        using var client = new HttpClient();
        using var dialog = new FileVfsDialog(model, root.XamlRoot, async uri =>
        {
            if (state is "cloud-waiting" or "cloud-cancel") return true;
            var fields = uri.Query.TrimStart('?').Split('&').Select(p => p.Split('=', 2)).ToDictionary(p => p[0], p => Uri.UnescapeDataString(p[1]));
            using var response = await client.PostAsync(fields["host"], new FormUrlEncodedContent(new Dictionary<string, string>
            { ["callback"] = fields["callback"], ["account"] = "sample@example.invalid", ["access_token"] = "synthetic-smoke-access" }));
            return response.IsSuccessStatusCode;
        });
        var opening = dialog.ShowAsync().AsTask(); await Task.Delay(250);
        var text = Localization.LocalizationService.Current;
        if (state == "error" && !model.LoadFailed || state == "loading" && !model.IsBusy) throw new InvalidOperationException("VFS 加载状态错误。");
        if (state.StartsWith("cloud", StringComparison.Ordinal))
        {
            await Click(ById("VfsCloudNew")); ByText("VfsAlias").Text = "Example cloud";
            if (state != "cloud-form")
            {
                await Click(ById("VfsCloudAuthorize"));
                if (state is "cloud-waiting" or "cloud-cancel")
                {
                    if (!model.IsAuthorizing || dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("云授权等待状态错误。");
                    if (state == "cloud-cancel") { await Click(ById("VfsCloudCancel")); if (model.IsBusy || model.HasCloudAuthorization) throw new InvalidOperationException("云授权取消后仍有凭据。"); }
                }
                else
                {
                    var deadline = DateTimeOffset.UtcNow.AddSeconds(5);
                    while (model.IsAuthorizing && DateTimeOffset.UtcNow < deadline) await Task.Delay(25);
                    if (!model.HasCloudAuthorization || !dialog.IsPrimaryButtonEnabled || repository.Writes != 0)
                        throw new InvalidOperationException($"云授权未等待明确保存：busy={model.IsBusy}, authorized={model.HasCloudAuthorization}, enabled={dialog.IsPrimaryButtonEnabled}, message={model.MessageKey}。");
                }
            }
        }
        if (state == "filtered") Nodes(dialog).OfType<TextBox>().Single(box => Equals(box.Header, text.Get("VfsFilter"))).Text = "no-match";
        if (state is "edit" or "run" or "unknown" or "disconnect" or "remove" or "readonly")
        {
            Nodes(dialog).OfType<ListView>().Single().SelectedIndex = 0; await Task.Delay(50);
            if (state == "readonly" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("只读 VFS 可提交。");
            if (state is "edit" or "run" or "unknown")
            {
                await Click(ById("VfsEdit"));
                if (model.ReplacePassword || Nodes(dialog).OfType<PasswordBox>().Single().Visibility != Visibility.Collapsed) throw new InvalidOperationException("编辑连接回显密码。");
                if (state != "edit") ByText("VfsAlias").Text = "Updated server";
            }
            else if (state is "disconnect" or "remove") await Click(ById(state == "disconnect" ? "VfsDisconnect" : "VfsRemove"));
        }
        if (state is "create" or "cleartext")
        {
            await Click(ById("VfsNew"));
            if (state == "cleartext") Nodes(dialog).OfType<ComboBox>().Single().SelectedIndex = 1;
            ByText("VfsAlias").Text = "Example server"; ByText("VfsHost").Text = "remote.invalid"; ByText("VfsAccount").Text = "sample";
            if (state == "cleartext" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("VFS 明文连接缺少独立确认。");
        }
        if (state is "run" or "unknown" or "disconnect" or "remove" or "cloud-run" or "cloud-unknown")
        {
            var primary = Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText) &&
                AutomationProperties.GetAutomationId(button) is not ("VfsDisconnect" or "VfsRemove" or "VfsConnect"));
            await Click(primary);
            if (repository.Writes != 1 || dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("VFS 重复提交或未提交。");
            if (state == "remove" && model.Profiles.Count != 0 || state == "disconnect" && model.Profiles.Single().State != FileVfsState.Disconnected) throw new InvalidOperationException("VFS 修改后清单未刷新。");
            if (state is "unknown" or "cloud-unknown")
            {
                if (!model.IsPending) throw new InvalidOperationException("VFS 未保留未知操作。");
                await Click(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, text.Get("FileShareRefreshAction"))));
                if (repository.Reviews != 1 || repository.Writes != 1 || model.IsPending) throw new InvalidOperationException("VFS 恢复发生重放。");
            }
        }
        dialog.UpdateLayout(); await Task.Delay(120);
        if (dialog.ActualTheme != ((FrameworkElement)root.XamlRoot.Content).ActualTheme) throw new InvalidOperationException("VFS 主题错误。");
        await WriteSnapshotAsync(dialog, markComplete: false); dialog.Hide(); dialog.Dispose(); await opening.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();

        Button ById(string id) => Nodes(dialog).OfType<Button>().Single(button => AutomationProperties.GetAutomationId(button) == id);
        TextBox ByText(string id) => Nodes(dialog).OfType<TextBox>().Single(box => AutomationProperties.GetAutomationId(box) == id);
        static IEnumerable<DependencyObject> Nodes(DependencyObject element)
        {
            yield return element;
            for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(element); i++)
                foreach (var child in Nodes(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(element, i))) yield return child;
        }
        static async Task Click(Button button)
        {
            button.StartBringIntoView(); await Task.Delay(40);
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
                .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke(); await Task.Delay(100);
        }
    }
}
