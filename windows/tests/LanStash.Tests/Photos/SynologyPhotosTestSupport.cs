using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

internal sealed class SynologyPhotosTestRepository : ISynologyPhotosRepository
{
    public Guid ProfileId { get; } = Guid.NewGuid();
    public bool CanDeleteOriginals { get; set; } = true;
    public IReadOnlyList<SynologyPhotoSpace> Spaces { get; set; } = [SynologyPhotoSpace.Personal];
    public IReadOnlyList<SynologyPhotoDay> Days { get; set; } = [new(new(2026, 9, 1), 1), new(new(2026, 8, 1), 1)];
    public List<(SynologyPhotoQuery Query, int Offset)> Calls { get; } = [];
    public Func<SynologyPhotoQuery, int, CancellationToken, Task<SynologyPhotoPage>>? Read { get; set; }
    public Func<SynologyPhoto, CancellationToken, Task<byte[]>>? Thumbnail { get; set; }
    public Func<SynologyPhoto, CancellationToken, Task<IReadOnlyMediaSource>>? Video { get; set; }
    public Func<SynologyPhoto, string, CancellationToken, Task>? Download { get; set; }
    public Func<Task>? Prepare { get; set; }
    public SynologyPhotoDeletionResult DeleteResult { get; set; } = SynologyPhotoDeletionResult.PendingReview;
    public SynologyPhotoDeletionResult ReviewResult { get; set; } = SynologyPhotoDeletionResult.PendingReview;
    public int DeleteCalls { get; private set; }
    public int ReviewCalls { get; private set; }
    public SynologyPhoto Photo(long id = 1, string type = "photo") => new(
        new(ProfileId, SynologyPhotoSpace.Personal, id), $"synthetic-{id}.jpg", 8,
        DateTimeOffset.FromUnixTimeSeconds(1788220800), DateTimeOffset.FromUnixTimeSeconds(1788220900), 3, type)
        { Thumbnail = new(id + 100, "synthetic-revision") };
    public Task<SynologyPhotoAccess> AccessAsync(CancellationToken cancellationToken = default) => Task.FromResult(new SynologyPhotoAccess(Spaces, "synthetic"));
    public Task<IReadOnlyList<SynologyPhotoDay>> TimelineAsync(SynologyPhotoQuery? query = null, CancellationToken cancellationToken = default) => Task.FromResult(Days);
    public Task<SynologyPhotoPage> PhotosAsync(SynologyPhotoQuery query, int offset, int limit, CancellationToken cancellationToken = default)
    {
        Calls.Add((query, offset));
        return Read?.Invoke(query, offset, cancellationToken) ?? Task.FromResult(new SynologyPhotoPage([Photo()], offset, offset + 1, false));
    }
    public Task<SynologyPhoto> DetailsAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Task.FromResult(photo);
    public Task<byte[]> ThumbnailAsync(SynologyPhoto photo, bool large = false, CancellationToken cancellationToken = default) => Thumbnail?.Invoke(photo, cancellationToken) ?? Task.FromResult(new byte[] { 1 });
    public Task<IReadOnlyMediaSource> VideoSourceAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Video?.Invoke(photo, cancellationToken) ?? Task.FromResult<IReadOnlyMediaSource>(new SynologyPhotosTestMedia());
    public Task DownloadOriginalAsync(SynologyPhoto photo, string destination, IProgress<long>? progress = null, CancellationToken cancellationToken = default) =>
        Download?.Invoke(photo, destination, cancellationToken) ?? File.WriteAllBytesAsync(destination, new byte[checked((int)photo.SizeBytes)], cancellationToken);
    public Task PrepareDeletionAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Prepare?.Invoke() ?? Task.CompletedTask;
    public Task<SynologyPhotoDeletionResult> DeleteAsync(SynologyPhoto photo, Guid operationId, CancellationToken cancellationToken = default)
    { DeleteCalls++; return Task.FromResult(DeleteResult); }
    public Task<SynologyPhotoDeletionResult> ReviewDeletionAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    { ReviewCalls++; return Task.FromResult(ReviewResult); }
}

internal sealed class SynologyPhotosTestMedia : IReadOnlyMediaSource
{
    public bool Disposed { get; private set; }
    public long Length => 8;
    public string ContentType => "video/mp4";
    public Task<byte[]> ReadAsync(long offset, int count, CancellationToken cancellationToken = default) => Task.FromResult(new byte[count]);
    public void Dispose() => Disposed = true;
}

internal sealed class SynologyPhotosHttpFixture : IDisposable
{
    public Guid ProfileId { get; } = Guid.NewGuid();
    public NasProfile Profile => new(ProfileId, "Synthetic NAS", "nas.invalid", 5001, "synthetic-user");
    public DsmSession Session => new(ProfileId, "synthetic-sid", "synthetic-token", null);
    public DsmApiClient Api { get; }
    private readonly HttpClient _http;
    public List<Request> Requests { get; } = [];
    public bool Enabled { get; set; } = true;
    public Func<Request, CancellationToken, Task<HttpResponseMessage>>? Respond { get; set; }
    public Dictionary<string, ApiCapability> Capabilities { get; } = new[]
    {
        "UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Search.Search",
        "Browse.Item", "Browse.Folder", "Browse.Album", "Browse.Category", "Browse.Person", "Browse.Concept",
        "Browse.Geocoding", "Browse.GeneralTag", "Browse.RecentlyAdded", "Browse.Unit", "Browse.Filter", "Sharing.Misc",
        "PhotoRequest", "Streaming", "Download", "BackgroundTask.File"
    }.ToDictionary(suffix => "SYNO.Foto." + suffix, suffix => new ApiCapability("SYNO.Foto." + suffix, "entry.cgi", 1, 9, "JSON"));

    public SynologyPhotosHttpFixture()
    { _http = new(new Handler(this)); Api = new(_http); }
    public SynologyPhotosRepository Repository(bool delete = false) => new(Profile, Session, Api, Capabilities, delete);
    public SynologyPhoto Photo => new(new(ProfileId, SynologyPhotoSpace.Personal, 7), "synthetic.jpg", 8,
        DateTimeOffset.FromUnixTimeSeconds(1788220800), DateTimeOffset.FromUnixTimeSeconds(1788220900), 3, "photo")
        { Thumbnail = new(8, "synthetic-revision") };
    public JsonObject PhotoJson(string type = "photo") => new()
    {
        ["id"] = 7, ["filename"] = "synthetic.jpg", ["filesize"] = 8,
        ["time"] = 1788220800, ["indexed_time"] = 1788220900, ["folder_id"] = 3, ["type"] = type,
        ["additional"] = new JsonObject { ["thumbnail"] = new JsonObject { ["unit_id"] = 8, ["cache_key"] = "synthetic-revision" } }
    };
    public static HttpResponseMessage Json(JsonObject data) => new(HttpStatusCode.OK)
    { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
    public static JsonObject List(params JsonObject[] items) => new() { ["list"] = new JsonArray(items.Cast<JsonNode>().ToArray()) };
    public sealed record Request(string Api, int Version, string Method, IReadOnlyDictionary<string, string> Values,
        Uri Uri, HttpMethod HttpMethod, string? Cookie, string? Token, string? Range, string? IfRange);
    private sealed class Handler(SynologyPhotosHttpFixture owner) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage message, CancellationToken cancellationToken)
        {
            var encoded = message.Content is null ? message.RequestUri!.Query.TrimStart('?') : await message.Content.ReadAsStringAsync(cancellationToken);
            var values = encoded.Split('&', StringSplitOptions.RemoveEmptyEntries).Select(part => part.Split('=', 2))
                .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part.Length > 1 ? part[1] : ""));
            string? Header(string key) => message.Headers.TryGetValues(key, out var headers) ? string.Join(";", headers) : null;
            var request = new Request(values.GetValueOrDefault("api", ""), int.TryParse(values.GetValueOrDefault("version"), out var version) ? version : 0,
                values.GetValueOrDefault("method", ""), values, message.RequestUri!, message.Method, Header("Cookie"), Header("X-SYNO-TOKEN"), Header("Range"), Header("If-Range"));
            Assert.True(WindowsCertificateTrustHandler.TryGetConnectionContext(message, out var contextProfile, out var source));
            Assert.Equal(owner.ProfileId, contextProfile);
            Assert.Equal(DsmConnectionSource.DirectAddress, source);
            owner.Requests.Add(request);
            var access = request.Api switch
            {
                "SYNO.Foto.UserInfo" => new JsonObject { ["enabled"] = owner.Enabled },
                "SYNO.Foto.Setting.User" => new JsonObject { ["enable_home_service"] = true, ["team_space_permission"] = "none" },
                "SYNO.Foto.Setting.Admin" => new JsonObject { ["package_version"] = "synthetic" },
                "SYNO.Foto.Setting.TeamSpace" => new JsonObject { ["enabled"] = false },
                _ => null,
            };
            if (access is not null) return Json(access);
            return owner.Respond is { } respond ? await respond(request, cancellationToken) : Json(List(owner.PhotoJson()));
        }
    }
    public void Dispose() => _http.Dispose();
}
