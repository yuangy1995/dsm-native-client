using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class FileUploadIntegrityWireTests
{
    [Theory]
    [InlineData("FORM", "ok")]
    [InlineData("JSON", "ok")]
    [InlineData("FORM", "corrupt")]
    [InlineData("JSON", "read-error")]
    [InlineData("FORM", "lost-receipt")]
    [InlineData("JSON", "denied")]
    public async Task RealMultipartReceiptAndFullContentDetermineOutcome(string format, string scenario)
    {
        using var server = new Server(format, scenario);
        using var http = new HttpClient(server);
        var api = new DsmApiClient(http);
        var repository = Repository(api, format);
        var content = Encoding.UTF8.GetBytes("第一行\nsecond line\n");
        var result = await repository.UploadFileAsync(new(new MemoryStream(content), content.Length, "/projects", "文件.txt"));
        Assert.Equal(scenario == "ok" ? MutationResultStatus.ConfirmedSuccess : scenario == "denied"
            ? MutationResultStatus.ConfirmedFailure : MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.Equal(content, server.Uploaded);
        Assert.Equal(1, server.Uploads);
        if (scenario is "read-error" or "corrupt" or "lost-receipt")
        {
            var duplicate = await Repository(api, format).UploadFileAsync(new(new MemoryStream(content), content.Length, "/projects", "文件.txt"));
            Assert.Equal(MutationErrorCategory.Conflict, duplicate.ErrorCategory); Assert.False(duplicate.Submitted); Assert.Equal(1, server.Uploads);
            server.Recovered = true;
            var refreshed = await Repository(api, format).ReviewFileUploadAsync("/projects", "文件.txt");
            Assert.Equal(scenario == "lost-receipt" ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess, refreshed!.Status);
            Assert.Equal(1, server.Uploads);
        }
    }

    [Fact]
    public async Task DifferentTargetsDoNotShareTheLongRunningUploadLock()
    {
        using var server = new Server("FORM", "ok") { Hold = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using var http = new HttpClient(server);
        var api = new DsmApiClient(http);
        var repository = Repository(api, "FORM");
        var first = repository.UploadFileAsync(new(new MemoryStream([1]), 1, "/projects", "文件.txt"));
        await server.Started.Task.WaitAsync(TimeSpan.FromSeconds(3));
        var second = repository.UploadFileAsync(new(new MemoryStream([2]), 1, "/projects", "other.txt"));
        await server.SecondStarted.Task.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.Equal(2, server.Uploads);
        server.Hold.SetResult();
        await Task.WhenAll(first, second);
    }

    private static DsmRepository Repository(IDsmApiClient api, string format)
    {
        var profile = new NasProfile(Guid.Parse("11111111-1111-1111-1111-111111111111"), "synthetic", "nas.invalid", 5001, "tester");
        return new(profile, new(profile.Id, "synthetic-session", null, null), api, new[]
        {
            new ApiCapability("SYNO.FileStation.Upload", "entry.cgi", 1, 2, "MULTIPART"),
            new ApiCapability("SYNO.FileStation.Download", "entry.cgi", 1, 20, format),
            new ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2, format),
            new ApiCapability("SYNO.FileStation.CheckPermission", "entry.cgi", 1, 3, format),
        }.ToDictionary(capability => capability.Name));
    }

    private sealed class Server(string format, string scenario) : HttpMessageHandler
    {
        public int Uploads;
        public byte[] Uploaded = [];
        public bool Recovered;
        public TaskCompletionSource? Hold;
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource SecondStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly HashSet<string> _targets = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Assert.Equal("nas.invalid", request.RequestUri!.Host);
            var body = request.Method == HttpMethod.Get ? request.RequestUri.Query.TrimStart('?') : await request.Content!.ReadAsStringAsync(token);
            if (request.Content?.Headers.ContentType?.MediaType == "multipart/form-data")
            {
                Interlocked.Increment(ref Uploads);
                Assert.Contains("name=\"version\"\r\n\r\n2", body);
                Assert.Contains("name=\"overwrite\"\r\n\r\nfalse", body);
                var start = body.IndexOf("\r\n\r\n", body.IndexOf("filename=", StringComparison.Ordinal), StringComparison.Ordinal) + 4;
                Uploaded = Encoding.UTF8.GetBytes(body[start..body.IndexOf("\r\n--", start, StringComparison.Ordinal)]);
                var nameStart = body.IndexOf("filename=\"", StringComparison.Ordinal) + 10;
                lock (_targets) _targets.Add("/projects/" + body[nameStart..body.IndexOf('"', nameStart)]);
                Started.TrySetResult(); if (Uploads == 2) SecondStarted.TrySetResult();
                if (Hold is not null) await Hold.Task.WaitAsync(token);
                if (scenario == "lost-receipt") throw new HttpRequestException("合成回执丢失");
                return scenario == "denied" ? new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}") } : Json(new());
            }
            var fields = body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(pair => WebUtility.UrlDecode(pair[0]), pair => WebUtility.UrlDecode(pair[1]));
            var api = fields["api"];
            if (api == "SYNO.FileStation.CheckPermission")
            {
                Assert.Equal("3", fields["version"]); Assert.Equal("true", fields["create_only"]);
                Assert.Equal(format == "JSON" ? JsonSerializer.Serialize("/projects") : "/projects", fields["path"]);
                return Json(new());
            }
            if (api == "SYNO.FileStation.Download")
            {
                Assert.Equal("2", fields["version"]);
                var range = request.Headers.Range!.Ranges.Single();
                var bytes = Uploaded.AsSpan((int)range.From!.Value, (int)(range.To!.Value - range.From.Value + 1)).ToArray();
                if (scenario == "corrupt" && !Recovered) bytes[0] ^= 1;
                var response = new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = new ByteArrayContent(bytes) };
                response.Content.Headers.ContentRange = new(range.From.Value, range.To.Value, Uploaded.Length);
                response.Headers.ETag = new EntityTagHeaderValue("\"synthetic-v1\"");
                return response;
            }
            Assert.Equal("SYNO.FileStation.List", api);
            if (Uploads > 0 && scenario == "read-error" && !Recovered) throw new HttpRequestException("合成回读失败");
            var path = fields["method"] == "getinfo" ? JsonSerializer.Deserialize<string[]>(fields["path"])!.Single() : "/projects/文件.txt";
            bool exists; lock (_targets) exists = _targets.Contains(path);
            var row = !exists ? new JsonObject { ["path"] = path, ["code"] = 408 } : new JsonObject
            {
                ["path"] = path, ["name"] = path.Split('/').Last(), ["isdir"] = false,
                ["additional"] = new JsonObject { ["size"] = Uploaded.Length, ["time"] = new JsonObject { ["mtime"] = 1700000000 } },
            };
            return fields["method"] == "getinfo" ? Json(new() { ["files"] = new JsonArray(row) }) :
                Json(new() { ["files"] = new JsonArray(row), ["offset"] = 0, ["total"] = 1 });
        }
        private static HttpResponseMessage Json(JsonObject data) => new(HttpStatusCode.OK)
        { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
    }
}
