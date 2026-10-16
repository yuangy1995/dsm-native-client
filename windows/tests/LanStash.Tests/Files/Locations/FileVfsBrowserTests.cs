using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Transfers;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Locations;

public sealed class FileVfsBrowserTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task AllPagesUseOriginalUriFixedVersionAndReadOnlyFiles(string format)
    {
        using var server = new Server(format) { Count = 503 };
        var result = await server.Repository.ListVfsFolderAsync(server.Profile, server.Profile.Uri);
        Assert.Equal(503, result.Items.Count); Assert.Equal(new[] { "0", "500" }, server.ListRequests.Select(r => r["offset"]));
        Assert.All(server.ListRequests, r => { Assert.Equal("2", r["version"]); Assert.Equal("500", r["limit"]);
            Assert.Equal(format == "JSON" ? JsonSerializer.Serialize(server.Profile.Uri) : server.Profile.Uri, r["folder_path"]); });
        Assert.All(result.Items, file => { Assert.False(file.CanWrite); Assert.False(file.CanDelete); });
    }

    [Theory]
    [InlineData("outside")][InlineData("nested")][InlineData("duplicate")][InlineData("offset")][InlineData("total")]
    [InlineData("empty-page")][InlineData("string-size")][InlineData("missing-size")][InlineData("negative-size")]
    [InlineData("string-directory")][InlineData("bad-time")][InlineData("bad-name")][InlineData("total-changed")]
    public async Task InvalidListingNeverBecomesDownloadable(string failure)
    {
        using var server = new Server { Failure = failure, Count = failure == "total-changed" ? 501 : 2 };
        await Assert.ThrowsAnyAsync<Exception>(() => server.Repository.ListVfsFolderAsync(server.Profile, server.Profile.Uri));
        Assert.Equal(0, server.Downloads);
    }

    [Theory]
    [InlineData("sftp://opaque-other/a")][InlineData("sftp://opaque-1/../a")][InlineData("sftp://opaque-1/./a")]
    [InlineData("sftp://opaque-1/a\nb")][InlineData("/share/file")][InlineData("sftp://opaque-1/a\\b")]
    public async Task RootEscapeHasNoRequests(string path)
    {
        using var server = new Server();
        await Assert.ThrowsAnyAsync<Exception>(() => server.Repository.ListVfsFolderAsync(server.Profile, path));
        Assert.Equal(0, server.Requests);
    }

    [Theory]
    [InlineData("profile")][InlineData("account")][InlineData("disconnected")][InlineData("unknown")]
    [InlineData("file-size")][InlineData("file-time")][InlineData("file-name")][InlineData("file-absent")]
    public async Task ChangedConnectionOrFileStopsDownloadBeforeBinaryRead(string change)
    {
        using var server = new Server();
        var source = await server.Source();
        server.Change = change;
        await Assert.ThrowsAnyAsync<Exception>(() => server.Repository.ValidateVfsDownloadAsync(source));
        await Assert.ThrowsAnyAsync<Exception>(() => server.Repository.ReadVfsRangeAsync(source, 0, 4));
        Assert.Equal(0, server.Downloads);
    }

    [Fact]
    public async Task SingleFileUsesExistingTransactionalDownloadAndCredentialsNeverEnterUrl()
    {
        using var server = new Server(); var source = await server.Source(); var target = new Destination();
        await server.Repository.ValidateVfsDownloadAsync(source);
        await new SafeFileDownloadService().DownloadAsync(new FileVfsRangeReader(server.Repository, source), source.File.Path, source.File.Size, target);
        Assert.Equal(1, server.Downloads); Assert.Equal(new byte[] { 1, 2, 3, 4 }, target.Bytes.ToArray()); Assert.True(target.Committed); Assert.False(target.Aborted);
        Assert.True(server.ProfileReads >= 3);
    }

    [Fact]
    public async Task ZeroByteStillRequiresFreshParentAndConnectedProfile()
    {
        using var server = new Server { Size = 0 }; var source = await server.Source();
        await server.Repository.ValidateVfsDownloadAsync(source);
        var target = new Destination();
        await new SafeFileDownloadService().DownloadAsync(new FileVfsRangeReader(server.Repository, source), source.File.Path, 0, target);
        Assert.True(target.Committed); Assert.Equal(0, server.Downloads);
        server.Change = "disconnected";
        await Assert.ThrowsAnyAsync<Exception>(() => server.Repository.ValidateVfsDownloadAsync(source));
    }

    [Fact]
    public async Task RangeBindingRejectsDifferentPathOrLengthWithoutRequest()
    {
        using var server = new Server(); var source = await server.Source(); var reader = new FileVfsRangeReader(server.Repository, source);
        var before = server.Requests;
        await Assert.ThrowsAnyAsync<Exception>(() => reader.ReadFileRangeResultAsync(source.File.Path + "x", 0, 4, expectedTotalLength: 4));
        await Assert.ThrowsAnyAsync<Exception>(() => reader.ReadFileRangeResultAsync(source.File.Path, 0, 4, expectedTotalLength: 5));
        Assert.Equal(before, server.Requests);
    }

    [Fact]
    public async Task NativeModelNavigatesFiltersSortsAndKeepsDownloadExplicit()
    {
        using var server = new Server { WithFolder = true }; using var model = new FileVfsBrowserViewModel(server.Repository, server.Profile);
        await model.LoadAsync(); Assert.False(model.CanUp);
        model.SetFilter("absent"); Assert.Empty(model.VisibleItems); Assert.False(model.CanDownload);
        model.SetFilter(""); model.SetSort(FileListSortField.Size); model.Select(model.Items.First(f => f.IsDirectory));
        await model.OpenAsync(); Assert.True(model.CanUp); Assert.EndsWith("/folder", model.Path);
        await model.UpAsync(); Assert.Equal(server.Profile.Uri, model.Path); Assert.False(model.CanUp);
        model.Select(model.Items.First(f => !f.IsDirectory)); var calls = 0;
        await model.DownloadAsync(async (source, current, token) => { Assert.True(current()); Assert.Equal(model.Path, source.Parent); await server.Repository.ValidateVfsDownloadAsync(source, token); calls++; return true; });
        Assert.Equal(1, calls); Assert.True(model.DownloadStarted); Assert.Equal(0, server.Downloads);
        server.Failure = "total"; await model.LoadAsync(); Assert.True(model.HasError); Assert.Empty(model.Items); Assert.False(model.CanDownload);
    }

    [Fact]
    public async Task ClosedModelIgnoresLateListingAndCannotStartDownload()
    {
        using var server = new Server(); server.Block = new(TaskCreationOptions.RunContinuationsAsynchronously);
        using var model = new FileVfsBrowserViewModel(server.Repository, server.Profile);
        var loading = model.LoadAsync(); model.Dispose(); server.Block.SetResult(); await loading;
        Assert.Empty(model.Items); Assert.False(model.CanDownload);
    }

    private sealed class Destination : ITransactionalDownloadDestination
    {
        public List<byte> Bytes = []; public bool Committed, Aborted;
        public ValueTask WriteAsync(ReadOnlyMemory<byte> bytes, CancellationToken token) { Bytes.AddRange(bytes.ToArray()); return ValueTask.CompletedTask; }
        public ValueTask CommitAsync(CancellationToken token) { Committed = true; return ValueTask.CompletedTask; }
        public ValueTask AbortAsync(CancellationToken token) { Aborted = true; return ValueTask.CompletedTask; }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    private sealed class Server : HttpMessageHandler
    {
        private readonly HttpClient _http; private readonly string _format;
        public readonly DsmRepository Repository;
        public readonly FileVfsProfile Profile;
        public int Count = 1, Requests, Downloads, ProfileReads;
        public long Size = 4; public bool WithFolder;
        public string? Failure, Change; public TaskCompletionSource? Block;
        public List<Dictionary<string, string>> ListRequests = [];
        public Server(string format = "FORM")
        {
            _format = format; _http = new(this, false); var id = Guid.NewGuid();
            Profile = new(id, "opaque-1", "sftp", "SFTP", "sftp://opaque-1", "remote.invalid", 22, "Example", "sample", "UTF-8", FileVfsState.Connected);
            var capabilities = new[] { "SYNO.FileStation.VFS.Profile", "SYNO.FileStation.List", "SYNO.FileStation.Download" }
                .ToDictionary(api => api, api => new ApiCapability(api, "entry.cgi", 1, 9, format));
            Repository = new(new(id, "Example", "nas.invalid", null, "sample"), new(id, "synthetic-session", "synthetic-token", null), new DsmApiClient(_http), capabilities);
        }
        public async Task<FileVfsDownloadSource> Source()
        { var folder = await Repository.ListVfsFolderAsync(Profile, Profile.Uri); return new(Profile, folder.Path, folder.Items.First(f => !f.IsDirectory)); }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Requests++; var raw = request.Method == HttpMethod.Get ? request.RequestUri!.Query.TrimStart('?') : await request.Content!.ReadAsStringAsync(token);
            var values = raw.Split('&').Select(v => v.Split('=', 2)).ToDictionary(v => WebUtility.UrlDecode(v[0]), v => WebUtility.UrlDecode(v[1]));
            JsonObject data;
            if (values["api"] == "SYNO.FileStation.VFS.Profile")
            {
                ProfileReads++;
                data = new() { ["profiles"] = new JsonArray(new JsonObject { ["id"] = Change == "profile" ? "other" : Profile.Id,
                    ["protocol"] = Profile.Protocol, ["protocol_name"] = Profile.ProtocolName, ["uri"] = Profile.Uri,
                    ["hostname"] = Profile.Hostname, ["port"] = Profile.Port, ["alias"] = Profile.Alias, ["account"] = Change == "account" ? "other" : Profile.Account,
                    ["codepage"] = Profile.Codepage, ["connect_status"] = Change == "disconnected" ? 0 : Change == "unknown" ? 4 : 1 }) };
            }
            else if (values["api"] == "SYNO.FileStation.List")
            {
                if (Block is not null) await Block.Task;
                ListRequests.Add(values); var offset = int.Parse(values["offset"]); var path = _format == "JSON" ? JsonSerializer.Deserialize<string>(values["folder_path"])! : values["folder_path"];
                var count = Change == "file-absent" ? 0 : Count; var rows = new JsonArray();
                for (var i = offset; i < Math.Min(offset + 500, count); i++) rows.Add(new JsonObject { ["path"] = path + "/file-" + i,
                    ["name"] = Change == "file-name" ? "changed" : "file-" + i, ["isdir"] = false,
                    ["additional"] = new JsonObject { ["size"] = Change == "file-size" ? Size + 1 : Size,
                        ["time"] = new JsonObject { ["mtime"] = Change == "file-time" ? 2 : 1 } } });
                if (WithFolder && offset == 0) rows.Add(new JsonObject { ["path"] = path + "/folder", ["name"] = "Folder", ["isdir"] = true });
                if (rows.FirstOrDefault() is JsonObject first)
                {
                    switch (Failure)
                    {
                        case "outside": first["path"] = "sftp://other/file"; break;
                        case "nested": first["path"] = path + "/folder/file"; break;
                        case "duplicate": rows[1] = first.DeepClone(); break;
                        case "string-directory": first["isdir"] = "false"; break;
                        case "bad-name": first["name"] = "a/b"; break;
                        case "string-size": first["additional"]!["size"] = "4"; break;
                        case "missing-size": first["additional"]!.AsObject().Remove("size"); break;
                        case "negative-size": first["additional"]!["size"] = -1; break;
                        case "bad-time": first["additional"]!["time"]!["mtime"] = "today"; break;
                        case "empty-page": rows.Clear(); break;
                    }
                }
                data = new() { ["files"] = rows, ["offset"] = Failure == "offset" ? offset + 1 : offset,
                    ["total"] = Failure == "total" ? -1 : Failure == "total-changed" && offset > 0 ? count + 1 : count + (WithFolder ? 1 : 0) };
            }
            else
            {
                Downloads++; Assert.Equal("2", values["version"]); Assert.Equal("download", values["method"]);
                Assert.False(values.ContainsKey("_sid")); Assert.DoesNotContain("synthetic-", request.RequestUri!.AbsoluteUri);
                Assert.Equal("id=synthetic-session", request.Headers.GetValues("Cookie").Single());
                Assert.Equal("synthetic-token", request.Headers.GetValues("X-SYNO-TOKEN").Single());
                var response = new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = new ByteArrayContent([1, 2, 3, 4]) };
                response.Content.Headers.ContentRange = new(0, 3, 4); response.Headers.ETag = new("\"original\""); return response;
            }
            return new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString()) };
        }
        protected override void Dispose(bool disposing) { if (disposing) _http.Dispose(); base.Dispose(disposing); }
    }
}
