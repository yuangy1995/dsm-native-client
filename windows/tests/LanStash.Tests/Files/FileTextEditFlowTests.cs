using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Files.Preview;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files;

public sealed class FileTextEditFlowTests
{
    [Theory]
    [InlineData("FORM", "hello", "新内容")]
    [InlineData("JSON", "", "first")]
    [InlineData("FORM", "hello", "")]
    public async Task ActualTransportSavesExactUtf8AndReadsBack(string format, string original, string desired)
    {
        using var server = new Server(format, original);
        var repo = server.Repository();
        var snapshot = await repo.DownloadTextContentSnapshotAsync(Server.Path, server.Bytes.Length, 1024);
        var result = await repo.SaveTextContentAsync(Server.Path, desired, snapshot);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(desired, Encoding.UTF8.GetString(server.Bytes));
        Assert.Equal(1, server.Uploads); Assert.Equal(1, server.PermissionChecks);
        Assert.Null(await repo.ReviewTextContentSaveAsync(Server.Path));
    }

    [Fact]
    public async Task NoChangesMakeNoUploadOrPermissionRequest()
    {
        using var server = new Server("FORM", "hello"); var repo = server.Repository();
        var snapshot = await repo.DownloadTextContentSnapshotAsync(Server.Path, 5, 1024);
        var result = await repo.SaveTextContentAsync(Server.Path, "hello", snapshot);
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, result.Status); Assert.False(result.Submitted);
        Assert.Equal(0, server.Uploads); Assert.Equal(0, server.PermissionChecks);
    }

    [Theory]
    [InlineData("changed")] [InlineData("permission")] [InlineData("empty-changed")]
    public async Task PreflightRejectsChangedTargetOrPermission(string fault)
    {
        using var server = new Server("FORM", fault == "empty-changed" ? "" : "hello");
        var repo = server.Repository(); var snapshot = await repo.DownloadTextContentSnapshotAsync(Server.Path, server.Bytes.Length, 1024);
        if (fault == "permission") server.PermissionDenied = true;
        else { server.Version++; if (fault != "empty-changed") server.Bytes = Encoding.UTF8.GetBytes("other"); }
        var result = await repo.SaveTextContentAsync(Server.Path, "desired", snapshot);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Status);
        Assert.Equal(fault == "permission" ? MutationErrorCategory.Permission : MutationErrorCategory.Conflict, result.ErrorCategory);
        Assert.Equal(0, server.Uploads);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task UnknownSaveBlocksReopenAndOnlyQueries(bool lostReceipt)
    {
        using var server = new Server("FORM", "hello") { LoseReceipt = lostReceipt, FailReadback = !lostReceipt };
        var repo = server.Repository(); var original = await repo.DownloadTextContentSnapshotAsync(Server.Path, 5, 1024);
        var result = await repo.SaveTextContentAsync(Server.Path, "saved", original);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        var reopened = server.Repository();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await reopened.SaveTextContentAsync(Server.Path, "different", original)).Status);
        Assert.Equal(1, server.Uploads);
        server.FailReadback = false;
        var review = await reopened.ReviewTextContentSaveAsync(Server.Path);
        Assert.Equal(lostReceipt ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess, review!.Status);
        Assert.Equal(1, server.Uploads);
    }

    [Fact]
    public async Task ConcurrentRepositoryCannotSubmitSecondUpload()
    {
        using var server = new Server("FORM", "hello") { HoldUpload = new() };
        var repo = server.Repository(); var snapshot = await repo.DownloadTextContentSnapshotAsync(Server.Path, 5, 1024);
        var first = repo.SaveTextContentAsync(Server.Path, "saved", snapshot);
        await server.UploadStarted.Task.WaitAsync(TimeSpan.FromSeconds(3));
        var second = await server.Repository().SaveTextContentAsync(Server.Path, "other", snapshot);
        Assert.Equal(MutationErrorCategory.Conflict, second.ErrorCategory); Assert.False(second.Submitted);
        server.HoldUpload.SetResult();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await first).Status); Assert.Equal(1, server.Uploads);
    }

    [Fact]
    public async Task UnknownTextWriteAlsoBlocksRenameOfTheSameFile()
    {
        using var server = new Server("FORM", "hello") { LoseReceipt = true };
        var repo = server.Repository(); var snapshot = await repo.DownloadTextContentSnapshotAsync(Server.Path, 5, 1024);
        await repo.SaveTextContentAsync(Server.Path, "saved", snapshot);
        var mutation = (IFileMutationRepository)server.Repository();
        var outcome = await mutation.RenameAsync(new(new(repo.ProfileId, Server.Path, "file.txt", false, 5, null, true), "new.txt"));
        Assert.Equal(MutationErrorCategory.Conflict, outcome.Result.ErrorCategory);
        Assert.Equal(1, server.Uploads);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task ListWriteFlagDoesNotReplaceActualOverwritePermission(bool denied)
    {
        using var server = new Server("FORM", "hello") { CanWrite = false, RejectUpload = denied };
        var repo = server.Repository(); var snapshot = await repo.DownloadTextContentSnapshotAsync(Server.Path, 5, 1024);
        var result = await repo.SaveTextContentAsync(Server.Path, "saved", snapshot);
        Assert.Equal(denied ? MutationResultStatus.ConfirmedFailure : MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(denied ? "hello" : "saved", Encoding.UTF8.GetString(server.Bytes));
        Assert.Equal(1, server.PermissionChecks); Assert.Equal(1, server.Uploads);
        Assert.Null(await repo.ReviewTextContentSaveAsync(Server.Path));
    }

    [Fact]
    public async Task CancelledBeforeSaveNeverUploadsAndReadOnlyLocationCannotEdit()
    {
        using var server = new Server("FORM", "hello"); var repo = server.Repository();
        var snapshot = await repo.DownloadTextContentSnapshotAsync(Server.Path, 5, 1024);
        var result = await repo.SaveTextContentAsync(Server.Path, "saved", snapshot, new CancellationToken(true));
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, result.Status); Assert.Equal(0, server.Uploads);
        using var editor = new FileTextEditViewModel(); editor.Attach(new Editor(), Item() with { CanWrite = false });
        Assert.True(editor.CanEdit);
        editor.Attach(new Editor(), Item(), editableLocation: false); Assert.False(editor.CanEdit);
    }

    [Theory]
    [InlineData("EFBBBF80")] [InlineData("FFFE00")] [InlineData("FEFF00")]
    public async Task InvalidBomContentNeverBecomesEditable(string hex)
    {
        using var server = new Server("FORM", "") { Bytes = Convert.FromHexString(hex) };
        await Assert.ThrowsAsync<InvalidOperationException>(() => server.Repository().DownloadTextContentSnapshotAsync(Server.Path, server.Bytes.Length, 1024));
    }

    [Fact]
    public async Task FailureKeepsDraftAndAllowsExplicitRetryWhileSaveFreezesInput()
    {
        var repo = new Editor(); using var model = new FileTextEditViewModel(); model.Attach(repo, Item());
        Assert.True(await model.EnterEditModeAsync()); model.EditableText = "draft";
        repo.SaveCompletion = new(); var saving = model.SaveAsync();
        Assert.True(model.HasUnsavedChanges); Assert.False(model.RequestClose());
        model.EditableText = "changed during save"; model.CancelEdit();
        Assert.Equal("draft", model.EditableText); Assert.Equal(FileTextEditState.Saving, model.State);
        repo.SaveCompletion.SetResult(Result(MutationResultStatus.ConfirmedFailure)); await saving;
        Assert.True(model.IsEditing); Assert.True(model.HasUnsavedChanges); Assert.True(model.CanSubmitSave);
        repo.SaveCompletion = null; await model.SaveAsync();
        Assert.Equal("draft", model.SavedText); Assert.False(model.HasUnsavedChanges);
        Assert.True(await model.EnterEditModeAsync()); Assert.Equal(5, repo.LastExpectedSize);
    }

    [Theory]
    [InlineData("open")] [InlineData("format")] [InlineData("save")]
    public async Task LateOldFileCompletionNeverTouchesNewTarget(string operation)
    {
        var repo = new Editor(); using var model = new FileTextEditViewModel(); model.Attach(repo, Item());
        Task pending;
        if (operation == "open") { repo.OpenCompletion = new(); pending = model.EnterEditModeAsync(); }
        else
        {
            await model.EnterEditModeAsync(); model.EditableText = "draft";
            if (operation == "format") { repo.FormatCompletion = new(); pending = model.FormatAsync(); }
            else { repo.SaveCompletion = new(); pending = model.SaveAsync(); }
        }
        model.Attach(repo, Item() with { Path = "/sample/new.json", Name = "new.json" });
        repo.OpenCompletion?.SetResult(Snapshot("old result"));
        repo.FormatCompletion?.SetResult("old formatted");
        repo.SaveCompletion?.SetResult(Result(MutationResultStatus.ConfirmedSuccess)); await pending;
        Assert.Equal("new.json", model.ItemName); Assert.Equal(string.Empty, model.EditableText);
        Assert.Equal(FileTextEditState.Viewing, model.State); Assert.Null(model.SavedText);
    }

    [Fact]
    public async Task FormatFailureKeepsOriginalAndUnknownSaveOnlyRefreshes()
    {
        var repo = new Editor(); using var model = new FileTextEditViewModel(); model.Attach(repo, Item());
        await model.EnterEditModeAsync(); model.EditableText = "draft"; repo.FormatCompletion = new();
        var formatting = model.FormatAsync(); repo.FormatCompletion.SetException(new InvalidDataException()); await formatting;
        Assert.Equal("draft", model.EditableText); Assert.Equal("FileTextEdit_FormatFailed", model.SaveMessage);
        repo.SaveCompletion = new(); var saving = model.SaveAsync();
        repo.SaveCompletion.SetResult(Result(MutationResultStatus.SubmittedButUnverified)); await saving;
        Assert.False(model.CanSubmitSave); Assert.False(model.CanFormat); Assert.True(model.HasUnsavedChanges);
        await model.SaveAsync(); Assert.Equal(1, repo.SaveCount);
        repo.Review = Result(MutationResultStatus.ConfirmedSuccess); await model.ReviewAsync();
        Assert.Equal("draft", model.SavedText); Assert.Equal(1, repo.SaveCount);
    }

    private static FileItem Item() => new("/sample/file.json", "file.json", false, 2, null, null, true, false);
    private static FileTextContentSnapshot Snapshot(string text) => new(text, Encoding.UTF8.GetByteCount(text), "v1", "synthetic");
    private static MutationResult Result(MutationResultStatus status) => new(1, status, "saveTextContent", status != MutationResultStatus.ConfirmedFailure,
        status == MutationResultStatus.SubmittedButUnverified, new(status == MutationResultStatus.ConfirmedSuccess ? 1 : 0,
        status == MutationResultStatus.ConfirmedFailure ? 1 : 0, status == MutationResultStatus.SubmittedButUnverified ? 1 : 0));

    private sealed class Editor : IFilePreviewRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public FileMD5Availability MD5Availability => new(false);
        public int SaveCount { get; private set; }
        public long LastExpectedSize { get; private set; }
        public TaskCompletionSource<FileTextContentSnapshot>? OpenCompletion { get; set; }
        public TaskCompletionSource<string>? FormatCompletion { get; set; }
        public TaskCompletionSource<MutationResult>? SaveCompletion { get; set; }
        public MutationResult? Review { get; set; }
        public FileTextEditAvailability GetTextEditAvailability() => new(true, true, ["json"]);
        public Task<FileTextContentSnapshot> DownloadTextContentSnapshotAsync(string path, long size, long max, CancellationToken token = default)
        { LastExpectedSize = size; return OpenCompletion?.Task ?? Task.FromResult(Snapshot("{}")); }
        public Task<MutationResult> SaveTextContentAsync(string path, string content, FileTextContentSnapshot original, CancellationToken token = default)
        { SaveCount++; return SaveCompletion?.Task ?? Task.FromResult(Result(MutationResultStatus.ConfirmedSuccess)); }
        public Task<MutationResult?> ReviewTextContentSaveAsync(string path, CancellationToken token = default) => Task.FromResult(Review);
        public Task<string> FormatTextContentAsync(string text, TextFormatKind kind, CancellationToken token = default) => FormatCompletion?.Task ?? Task.FromResult("formatted");
        public Task<string> CalculateMD5Async(string path, CancellationToken token = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(string path, long offset, long length, CancellationToken token = default) => throw new NotSupportedException();
        public Task<FileRangeReadResult> ReadFileRangeResultAsync(string path, long offset, long length,
            string? version = null, long? total = null, CancellationToken token = default) => throw new NotSupportedException();
    }

    private sealed class Server : HttpMessageHandler
    {
        public const string Path = "/sample/file.txt";
        private readonly HttpClient _http;
        private readonly DsmApiClient _api;
        private readonly NasProfile _profile = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "editor");
        private readonly string _format;
        public byte[] Bytes { get; set; }
        public int Version { get; set; } = 1;
        public int Uploads { get; private set; }
        public int PermissionChecks { get; private set; }
        public bool CanWrite { get; set; } = true;
        public bool PermissionDenied { get; set; }
        public TaskCompletionSource? HoldUpload { get; set; }
        public TaskCompletionSource UploadStarted { get; } = new();
        public bool RejectUpload { get; set; }
        public bool LoseReceipt { get; set; }
        public bool FailReadback { get; set; }
        public Server(string format, string text) { _format = format; Bytes = Encoding.UTF8.GetBytes(text); _http = new(this); _api = new(_http); }
        public IFilePreviewRepository Repository() => new DsmRepository(_profile, new(_profile.Id, "synthetic-session", null, null), _api,
            new[] { new ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2, _format),
                new ApiCapability("SYNO.FileStation.Rename", "entry.cgi", 1, 2, "FORM"),
                new ApiCapability("SYNO.FileStation.Download", "entry.cgi", 1, 2, "FORM"),
                new ApiCapability("SYNO.FileStation.Upload", "entry.cgi", 1, 2, "MULTIPART"),
                new ApiCapability("SYNO.FileStation.CheckPermission", "entry.cgi", 1, 3, _format) }.ToDictionary(cap => cap.Name));
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            if (request.Method == HttpMethod.Get)
            {
                if (Uploads > 0 && FailReadback) throw new HttpRequestException("synthetic read failure");
                var range = request.Headers.Range!.Ranges.Single();
                var content = new ByteArrayContent(Bytes[(int)range.From!.Value..(Math.Min(Bytes.Length, (int)range.To!.Value + 1))]);
                content.Headers.ContentRange = new ContentRangeHeaderValue(range.From.Value, Bytes.Length - 1, Bytes.Length);
                var response = new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = content };
                response.Headers.ETag = new EntityTagHeaderValue("\"v" + Version + "\""); return response;
            }
            var body = await request.Content!.ReadAsStringAsync(token);
            if (request.Content.Headers.ContentType!.MediaType == "multipart/form-data")
            {
                Uploads++; UploadStarted.TrySetResult();
                if (HoldUpload is not null) await HoldUpload.Task;
                if (RejectUpload) return new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}") };
                Assert.Contains("name=\"overwrite\"\r\n\r\ntrue", body);
                var fileHeader = body.IndexOf("filename=", StringComparison.Ordinal);
                Assert.True(fileHeader >= 0);
                var begin = body.IndexOf("\r\n\r\n", fileHeader, StringComparison.Ordinal) + 4;
                var end = body.IndexOf("\r\n--", begin, StringComparison.Ordinal);
                Bytes = Encoding.UTF8.GetBytes(body[begin..end]); Version++;
                if (LoseReceipt) throw new HttpRequestException("synthetic lost response");
                return Json(new JsonObject());
            }
            var fields = body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(pair => WebUtility.UrlDecode(pair[0]), pair => WebUtility.UrlDecode(pair[1]));
            if (fields["api"] == "SYNO.FileStation.CheckPermission")
            {
                PermissionChecks++; Assert.Equal("3", fields["version"]); Assert.Equal("true", fields["create_only"]);
                Assert.Equal(_format == "JSON" ? JsonSerializer.Serialize("/sample") : "/sample", fields["path"]);
                Assert.Contains("LanStash-Write-Check-", fields["filename"]);
                if (PermissionDenied) return new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}") };
                return Json(new JsonObject());
            }
            Assert.Equal("getinfo", fields["method"]); Assert.Equal("2", fields["version"]);
            if (Uploads > 0 && FailReadback) throw new HttpRequestException("synthetic read failure");
            return Json(new JsonObject { ["files"] = new JsonArray(new JsonObject { ["path"] = Path, ["name"] = "file.txt", ["isdir"] = false,
                ["additional"] = new JsonObject { ["size"] = Bytes.Length, ["time"] = new JsonObject { ["mtime"] = 1700000000 + Version },
                    ["perm"] = new JsonObject { ["write"] = CanWrite } } }) });
        }
        private static HttpResponseMessage Json(JsonObject data) => new(HttpStatusCode.OK) { Content = new StringContent(
            new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
    }
}
