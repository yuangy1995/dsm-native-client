using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Office;

internal sealed class OfficeTestStore : IProtectedTaskStore
{
    public Dictionary<Guid, byte[]> Records { get; } = [];
    public int Saves { get; private set; }
    public int FailAtSave { get; set; } = -1;
    public Task<IReadOnlyDictionary<Guid, byte[]>> LoadAsync() => Task.FromResult<IReadOnlyDictionary<Guid, byte[]>>(Records.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray()));
    public Task SaveAsync(Guid id, byte[] record)
    {
        Saves++;
        if (Saves == FailAtSave) throw new IOException("合成持久化失败");
        Records[id] = record.ToArray(); return Task.CompletedTask;
    }
    public OfficeTestStore Reopen()
    { var copy = new OfficeTestStore(); foreach (var pair in Records) copy.Records.Add(pair.Key, pair.Value.ToArray()); return copy; }
}

internal sealed class OfficeTestServer : HttpMessageHandler
{
    private readonly HttpClient _http;
    internal readonly DsmApiClient Api;
    internal readonly NasProfile Profile = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-editor");
    public string RemotePath { get; set; } = "/sample/document.docx";
    public string Format { get; set; } = "FORM";
    public byte[] Bytes { get; set; } = Encoding.UTF8.GetBytes("合成文档 original");
    public int Version { get; set; } = 1;
    public int Uploads, Permissions, Reads, Md5Starts, Renames;
    public bool DenyPermission, RejectUpload, LoseReceipt, FailReadback, CanWrite = true, Missing, Link, MalformedMd5;
    public string? MountType;
    public TaskCompletionSource? HoldUpload;
    public bool IgnoreUploadCancellation;
    public TaskCompletionSource? HoldMd5, HoldList;
    public TaskCompletionSource Md5Held { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource ListHeld { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Action? AfterMd5;
    public OfficeTestServer() { _http = new(this); Api = new(_http); }
    public DsmRepository Repository(IProtectedTaskStore? store = null, bool enabled = true, string? user = null, bool md5 = true, bool freshClient = false) =>
        new(Profile with { Username = user ?? Profile.Username }, new(Profile.Id, "synthetic-session-never-persist", null, null), freshClient ? new DsmApiClient(_http) : Api,
            new[]
            {
                new ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2, Format),
                new ApiCapability("SYNO.FileStation.Download", "entry.cgi", 1, 2, "FORM"),
                new ApiCapability("SYNO.FileStation.Upload", "entry.cgi", 1, 2, "MULTIPART"),
                new ApiCapability("SYNO.FileStation.CheckPermission", "entry.cgi", 1, 3, Format),
                new ApiCapability("SYNO.FileStation.MD5", "entry.cgi", 1, 2, "FORM"),
                new ApiCapability("SYNO.FileStation.Rename", "entry.cgi", 1, 2, "FORM"),
                new ApiCapability("SYNO.FileStation.CopyMove", "entry.cgi", 1, 3, "FORM"),
                new ApiCapability("SYNO.FileStation.Delete", "entry.cgi", 1, 2, "FORM"),
                new ApiCapability("SYNO.FileStation.Compress", "entry.cgi", 1, 3, "FORM"),
                new ApiCapability("SYNO.FileStation.Extract", "entry.cgi", 1, 2, "FORM"),
            }.Where(cap => md5 || cap.Name != "SYNO.FileStation.MD5").ToDictionary(cap => cap.Name), officeEditingStore: store)
        { OfficeAutomaticUploadEnabled = enabled, FileMD5InitialPollDelay = TimeSpan.Zero };

    public async Task<OfficeEditingSessionInfo> BeginAsync(DsmRepository repo)
    {
        await repo.InitializeOfficeRecoveryAsync();
        return await repo.CreateOfficeSessionAsync(Guid.NewGuid(), Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + Path.GetExtension(RemotePath)),
            await repo.ReadOfficeRemoteAsync(RemotePath), Fingerprint(Bytes));
    }
    public static OfficeContentFingerprint Fingerprint(byte[] bytes) => new(bytes.LongLength,
        Convert.ToHexString(MD5.HashData(bytes)), Convert.ToHexString(SHA256.HashData(bytes)));
    public static Task<OfficeEditingSessionInfo> SaveAsync(IOfficeEditingRepository repo, Guid id, string content, CancellationToken token = default)
    {
        var bytes = Encoding.UTF8.GetBytes(content);
        return SaveBytesAsync(repo, id, bytes, token);
    }
    private static async Task<OfficeEditingSessionInfo> SaveBytesAsync(IOfficeEditingRepository repo, Guid id, byte[] bytes, CancellationToken token)
    { using var stream = new MemoryStream(bytes); return await repo.SaveOfficeSessionAsync(id, stream, Fingerprint(bytes), token); }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        Assert.Equal("nas.invalid", request.RequestUri!.Host);
        if (request.Content?.Headers.ContentType?.MediaType == "multipart/form-data")
        {
            Uploads++;
            var body = Encoding.Latin1.GetString(await request.Content.ReadAsByteArrayAsync(token));
            Assert.Contains("name=\"overwrite\"\r\n\r\ntrue", body);
            Assert.Contains("name=\"version\"\r\n\r\n2", body);
            var start = body.IndexOf("\r\n\r\n", body.IndexOf("filename=", StringComparison.Ordinal), StringComparison.Ordinal) + 4;
            var bytes = Encoding.Latin1.GetBytes(body[start..body.IndexOf("\r\n--", start, StringComparison.Ordinal)]);
            Started.TrySetResult();
            if (HoldUpload is not null)
            {
                if (IgnoreUploadCancellation) await HoldUpload.Task;
                else await HoldUpload.Task.WaitAsync(token);
            }
            if (RejectUpload) return Rejected();
            Bytes = bytes; Version++;
            if (LoseReceipt) throw new HttpRequestException("合成回执丢失");
            return Json(new());
        }
        Reads++;
        var encoded = request.Method == HttpMethod.Get ? request.RequestUri.Query.TrimStart('?') : await request.Content!.ReadAsStringAsync(token);
        var fields = encoded.Split('&').Select(part => part.Split('=', 2)).ToDictionary(pair => WebUtility.UrlDecode(pair[0]), pair => WebUtility.UrlDecode(pair[1]));
        var api = fields["api"]; var method = fields["method"];
        if (api == "SYNO.FileStation.CheckPermission")
        {
            Permissions++; Assert.Equal("3", fields["version"]); Assert.Equal("true", fields["create_only"]);
            Assert.Contains("LanStash-Write-Check-", fields["filename"]);
            return DenyPermission ? Rejected() : Json(new());
        }
        if (api == "SYNO.FileStation.MD5")
        {
            Assert.Equal("2", fields["version"]);
            if (method == "start") { Md5Starts++; Assert.Equal(RemotePath, fields["file_path"]); return Json(new() { ["taskid"] = "synthetic-md5" }); }
            if (method == "stop") return Json(new());
            Assert.Equal("status", method);
            if (HoldMd5 is not null) { Md5Held.TrySetResult(); await HoldMd5.Task.WaitAsync(token); }
            var digest = MalformedMd5 ? "invalid" : Fingerprint(Bytes).Md5.ToLowerInvariant();
            AfterMd5?.Invoke();
            return Json(new() { ["finished"] = true, ["md5"] = digest });
        }
        if (Uploads > 0 && FailReadback) throw new HttpRequestException("合成回读不可用");
        if (api == "SYNO.FileStation.Download")
        {
            var range = request.Headers.Range!.Ranges.Single();
            var content = new ByteArrayContent(Bytes[(int)range.From!.Value..(int)(range.To!.Value + 1)]);
            content.Headers.ContentRange = new ContentRangeHeaderValue(range.From.Value, range.To.Value, Bytes.Length);
            return new(HttpStatusCode.PartialContent) { Content = content, Headers = { ETag = new EntityTagHeaderValue("\"synthetic-v" + Version + "\"") } };
        }
        if (api == "SYNO.FileStation.Rename") { Renames++; return Json(new()); }
        Assert.Equal("SYNO.FileStation.List", api); Assert.Equal("2", fields["version"]);
        if (HoldList is not null) { ListHeld.TrySetResult(); await HoldList.Task.WaitAsync(token); }
        var row = Missing ? new JsonObject { ["path"] = RemotePath, ["code"] = 408 } : new JsonObject
        {
            ["path"] = RemotePath, ["name"] = RemotePath.Split('/').Last(), ["isdir"] = false,
            ["additional"] = new JsonObject { ["size"] = Bytes.Length, ["time"] = new JsonObject { ["mtime"] = 1700000000 + Version },
                ["perm"] = new JsonObject { ["write"] = CanWrite }, ["type"] = Link ? "symlink" : "file", ["mount_point_type"] = MountType },
        };
        return method == "getinfo" ? Json(new() { ["files"] = new JsonArray(row) }) :
            Json(new() { ["files"] = new JsonArray(row), ["offset"] = 0, ["total"] = 1 });
    }
    private static HttpResponseMessage Rejected() => new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}") };
    private static HttpResponseMessage Json(JsonObject data) => new(HttpStatusCode.OK)
    { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
}

internal sealed class OfficeTestDirectory : IDisposable
{
    public string Path { get; } = System.IO.Path.GetFullPath(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "LanStash-office-test-" + Guid.NewGuid().ToString("N")));
    public OfficeTestDirectory() => Directory.CreateDirectory(Path);
    public string FilePath(string name = "document.docx") => System.IO.Path.Combine(Path, name);
    public void Dispose()
    {
        Assert.StartsWith(System.IO.Path.GetFullPath(System.IO.Path.GetTempPath()), Path, StringComparison.OrdinalIgnoreCase);
        if (Directory.Exists(Path)) Directory.Delete(Path, recursive: true);
    }
}
