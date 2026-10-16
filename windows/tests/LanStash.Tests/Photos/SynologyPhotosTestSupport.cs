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
    public bool SupportsFolderManagement => ReadFolder is not null;
    public Func<long, SynologyPhotoSpace, Task<SynologyPhotoFolder>>? ReadFolder { get; set; }
    public Func<long, int, bool, SynologyPhotoSpace, Task<IReadOnlyList<SynologyPhotoCollection>>>? ReadFolders { get; set; }
    public Func<SynologyPhotoBackgroundTask, CancellationToken, Task<IReadOnlyList<SynologyPhotoFolder>>>? ReadTaskLocation { get; set; }
    public Task<IReadOnlyList<SynologyPhotoFolder>> BackgroundTaskLocationAsync(SynologyPhotoBackgroundTask task, CancellationToken cancellationToken = default) => ReadTaskLocation!(task, cancellationToken);
    public Task<SynologyPhotoFolder> FolderAsync(long? id, SynologyPhotoSpace space, CancellationToken cancellationToken = default) => ReadFolder!(id ?? 1, space);
    public async Task<SynologyPhotoCollection> RootFolderAsync(CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) => (await FolderAsync(1, space, cancellationToken)).Collection;
    public Task<IReadOnlyList<SynologyPhotoCollection>> FoldersAsync(long id, int offset, int limit, CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) => FoldersAsync(id, offset, limit, false, cancellationToken, space);
    public Task<IReadOnlyList<SynologyPhotoCollection>> FoldersAsync(long id, int offset, int limit, bool descending, CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) =>
        ReadFolders?.Invoke(id, offset, descending, space) ?? Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>([]);
    public IReadOnlyList<SynologyPhotoSpace> Spaces { get; set; } = [SynologyPhotoSpace.Personal];
    public IReadOnlyList<SynologyPhotoCollection> Albums { get; set; } = [];
    public int AlbumCalls { get; private set; }
    internal IReadOnlyList<SynologyPhotoPerson> People = [];
    internal Func<CancellationToken, Task<IReadOnlyList<SynologyPhotoPerson>>>? ReadPeople;
    internal IReadOnlyList<SynologyPhotoConcept> Concepts = [];
    internal Func<CancellationToken, Task<IReadOnlyList<SynologyPhotoConcept>>>? ReadConcepts;
    internal Func<long, SynologyPhotoSpace, CancellationToken, Task<SynologyPhotoSimilarDetail?>>? ReadSimilar;
    public Task<SynologyPhotoSimilarDetail?> SimilarGroupAsync(long id, SynologyPhotoSpace space, CancellationToken cancellationToken = default) => ReadSimilar!(id, space, cancellationToken);
    public Task<IReadOnlyList<SynologyPhotoConcept>> ConceptsAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default) => ReadConcepts?.Invoke(cancellationToken) ?? Task.FromResult(Concepts);
    public async Task<SynologyPhotoConcept> ConceptAsync(long id, SynologyPhotoSpace space, CancellationToken cancellationToken = default) => (await ConceptsAsync(space, cancellationToken)).Single(value => value.Concept.Id == id);
    internal readonly List<int> CategoryOffsets = [];
    public Task<IReadOnlyList<SynologyPhotoPerson>> PeopleAsync(SynologyPhotoSpace space, bool includeHidden, CancellationToken cancellationToken = default) =>
        ReadPeople?.Invoke(cancellationToken) ?? Task.FromResult<IReadOnlyList<SynologyPhotoPerson>>(People.Where(person => includeHidden || person.Visible == true).ToArray());
    public Task<IReadOnlyList<SynologyPhotoCollection>> CategoryItemsAsync(SynologyPhotoCategory category, int offset, int limit, CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal)
    { CategoryOffsets.Add(offset); var values = category == SynologyPhotoCategory.Subjects ? Concepts.Where(value => value.AppearsInList).Select(value => value.Concept) : People.Where(person => person.Visible == true).Select(person => person.Person);
        return Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>(values.Skip(offset).Take(limit).Select(value => value with { Space = space }).ToArray()); }
    public bool SupportsAlbumManagement => ReadAlbum is not null;
    public Func<long, Task<SynologyPhotoAlbum>>? ReadAlbum { get; set; }
    public Func<SynologyPhotoAlbumListScope, Task<SynologyPhotoAlbumListSort>>? ReadAlbumSort { get; set; }
    public Func<Task<SynologyPhotoAlbumDisplay>>? ReadAlbumDisplay { get; set; }
    public List<(int Offset, SynologyPhotoAlbumDisplay Display, SynologyPhotoAlbumListSort Sort)> AlbumPages { get; } = [];
    public List<(SynologyPhotoShareScope Scope, int Offset, SynologyPhotoAlbumListSort? Sort)> SharePages { get; } = [];
    public IReadOnlyList<SynologyPhotoSharedEntry> Shares { get; set; } = [];
    public Task<SynologyPhotoAlbum> AlbumAsync(long id, CancellationToken cancellationToken = default) => ReadAlbum!(id);
    public Task<SynologyPhotoAlbumListSort> AlbumListSortAsync(SynologyPhotoAlbumListScope scope, CancellationToken cancellationToken = default) =>
        ReadAlbumSort?.Invoke(scope) ?? Task.FromResult(new SynologyPhotoAlbumListSort(SynologyPhotoAlbumListField.Name));
    public Task<SynologyPhotoAlbumDisplay> AlbumDisplayAsync(CancellationToken cancellationToken = default) => ReadAlbumDisplay?.Invoke() ?? Task.FromResult(SynologyPhotoAlbumDisplay.All);
    public Task<IReadOnlyList<SynologyPhotoCollection>> AlbumsAsync(int offset, int limit, SynologyPhotoAlbumDisplay display, SynologyPhotoAlbumListSort sort, CancellationToken cancellationToken = default)
    { AlbumPages.Add((offset, display, sort)); return AlbumsAsync(offset, limit, cancellationToken); }
    public Task<IReadOnlyList<SynologyPhotoSharedEntry>> SharedEntriesAsync(SynologyPhotoShareScope scope, int offset, int limit, CancellationToken cancellationToken = default)
    { SharePages.Add((scope, offset, null)); return Task.FromResult<IReadOnlyList<SynologyPhotoSharedEntry>>(Shares.Skip(offset).Take(limit).ToArray()); }
    public Task<IReadOnlyList<SynologyPhotoSharedEntry>> SharedEntriesAsync(SynologyPhotoShareScope scope, int offset, int limit, SynologyPhotoAlbumListSort sort, CancellationToken cancellationToken = default)
    { SharePages.Add((scope, offset, sort)); return Task.FromResult<IReadOnlyList<SynologyPhotoSharedEntry>>(Shares.Skip(offset).Take(limit).ToArray()); }
    public IReadOnlyList<SynologyPhotoDay> Days { get; set; } = [new(new(2026, 9, 1), 1), new(new(2026, 8, 1), 1)];
    public List<(SynologyPhotoQuery Query, int Offset)> Calls { get; } = [];
    public Func<SynologyPhotoQuery, int, CancellationToken, Task<SynologyPhotoPage>>? Read { get; set; }
    public Func<SynologyPhoto, CancellationToken, Task<byte[]>>? Thumbnail { get; set; }
    public Func<SynologyPhoto, CancellationToken, Task<SynologyPhoto>>? Detail { get; set; }
    public Func<SynologyPhoto, CancellationToken, Task<IReadOnlyMediaSource>>? Video { get; set; }
    public Func<SynologyPhoto, string, CancellationToken, Task>? Download { get; set; }
    public Func<Task>? Prepare { get; set; }
    public SynologyPhotoDeletionResult DeleteResult { get; set; } = SynologyPhotoDeletionResult.PendingReview;
    public SynologyPhotoDeletionResult ReviewResult { get; set; } = SynologyPhotoDeletionResult.PendingReview;
    public int DeleteCalls { get; private set; }
    public int ReviewCalls { get; private set; }
    public SynologyPhoto Photo(long id = 1, string type = "photo", SynologyPhotoSpace space = SynologyPhotoSpace.Personal) => new(
        new(ProfileId, space, id), $"synthetic-{id}.jpg", 8,
        DateTimeOffset.FromUnixTimeSeconds(1788220800), DateTimeOffset.FromUnixTimeSeconds(1788220900), 3, type)
        { Thumbnail = new(id + 100, "synthetic-revision") };
    internal bool CanManageSharedSpace;
    public Task<SynologyPhotoAccess> AccessAsync(CancellationToken cancellationToken = default) => Task.FromResult(new SynologyPhotoAccess(Spaces, "synthetic") { CanManageSharedSpace = CanManageSharedSpace });
    public Task<IReadOnlyList<SynologyPhotoDay>> TimelineAsync(SynologyPhotoQuery? query = null, CancellationToken cancellationToken = default) => Task.FromResult(Days);
    public Task<IReadOnlyList<SynologyPhotoCollection>> AlbumsAsync(int offset, int limit, CancellationToken cancellationToken = default)
    { AlbumCalls++; return Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>(Albums.Skip(offset).Take(limit).ToArray()); }
    public Task<IReadOnlySet<SynologyPhotoCategory>> CategoriesAsync(CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) =>
        Task.FromResult<IReadOnlySet<SynologyPhotoCategory>>(new[] { ReadSimilar is not null ? SynologyPhotoCategory.Similar : (SynologyPhotoCategory?)null, People.Count > 0 ? SynologyPhotoCategory.People : (SynologyPhotoCategory?)null, Concepts.Count > 0 ? SynologyPhotoCategory.Subjects : (SynologyPhotoCategory?)null }.OfType<SynologyPhotoCategory>().ToHashSet());
    public Task<SynologyPhotoFilterOptions> FilterOptionsAsync(CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) => Task.FromResult(new SynologyPhotoFilterOptions());
    public Task<SynologyPhotoPage> PhotosAsync(SynologyPhotoQuery query, int offset, int limit, CancellationToken cancellationToken = default)
    {
        Calls.Add((query, offset));
        var photo = Photo(space: query.Space);
        if (query is SynologyPhotoQuery.Album album) photo = photo with { AlbumContext = new(album.Id, query.Space == SynologyPhotoSpace.Shared ? 0 : 1, 1) };
        return Read?.Invoke(query, offset, cancellationToken) ?? Task.FromResult(new SynologyPhotoPage([photo], offset, offset + 1, false));
    }
    public Task<SynologyPhoto> DetailsAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Detail?.Invoke(photo, cancellationToken) ?? Task.FromResult(photo);
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
    public bool RouteSettingWrites { get; set; }
    public bool HomeEnabled { get; set; } = true;
    public bool TeamEnabled { get; set; }
    public string TeamPermission { get; set; } = "none";
    public bool TeamPersonEnabled { get; set; }
    public bool TeamConceptEnabled { get; set; }
    public long UserId { get; set; } = 19;
    public Func<string, JsonObject?>? AccessResponse { get; set; }
    public Func<Request, CancellationToken, Task<HttpResponseMessage>>? Respond { get; set; }
    public Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>>? RespondMultipart { get; set; }
    public Dictionary<string, ApiCapability> Capabilities { get; } = new[]
    {
        "UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Search.Search",
        "Browse.Item", "Browse.Folder", "Browse.Album", "Browse.Category", "Browse.Person", "Browse.Concept",
        "Browse.Geocoding", "Browse.GeneralTag", "Browse.RecentlyAdded", "Browse.Unit", "Search.Filter", "Sharing.Misc",
        "PhotoRequest", "Streaming", "Download", "BackgroundTask.File", "BackgroundTask.Info"
    }.ToDictionary(suffix => "SYNO.Foto." + suffix, suffix => new ApiCapability("SYNO.Foto." + suffix, "entry.cgi", 1, 9, "JSON"));

    public SynologyPhotosHttpFixture()
    {
        foreach (var suffix in new[] { "Browse.Timeline", "Search.Search", "Browse.Item", "Browse.Folder", "Browse.Person", "Browse.Concept", "Browse.Geocoding", "Browse.GeneralTag", "Browse.RecentlyAdded", "Browse.Unit", "Search.Filter", "Streaming", "Download", "BackgroundTask.File" })
        { var name = "SYNO.FotoTeam." + suffix; Capabilities.Add(name, new(name, "entry.cgi", 1, 9, "JSON")); }
        _http = new(new Handler(this)); Api = new(_http);
    }
    private readonly SynologyPhotosUploadTests.MemoryStore _managementStore = new();
    public SynologyPhotosRepository Repository(bool delete = false) => new(Profile, Session, Api, Capabilities, delete, managementStore: _managementStore);
    public SynologyPhoto Photo => new(new(ProfileId, SynologyPhotoSpace.Personal, 7), "synthetic.jpg", 8,
        DateTimeOffset.FromUnixTimeSeconds(1788220800), DateTimeOffset.FromUnixTimeSeconds(1788220900), 3, "photo")
        { Thumbnail = new(8, "synthetic-revision") };
    public JsonObject PhotoJson(string type = "photo") => new()
    {
        ["id"] = 7, ["filename"] = "synthetic.jpg", ["filesize"] = 8,
        ["time"] = 1788220800, ["indexed_time"] = 1788220900000L, ["folder_id"] = 3, ["type"] = type,
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
            if (message.Content?.Headers.ContentType?.MediaType == "multipart/form-data" && owner.RespondMultipart is { } multipart)
                return await multipart(message, cancellationToken);
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
            var access = owner.AccessResponse?.Invoke(request.Api) ?? (request.Api switch
            {
                "SYNO.Foto.UserInfo" => new JsonObject { ["enabled"] = owner.Enabled, ["id"] = owner.UserId, ["is_admin"] = true },
                "SYNO.Foto.Setting.User" => new JsonObject { ["enable_home_service"] = owner.HomeEnabled, ["team_space_permission"] = owner.TeamPermission },
                "SYNO.Foto.Setting.Admin" => new JsonObject { ["package_version"] = "synthetic" },
                "SYNO.Foto.Setting.TeamSpace" => new JsonObject { ["enabled"] = owner.TeamEnabled, ["enable_person"] = owner.TeamPersonEnabled, ["enable_concept"] = owner.TeamConceptEnabled },
                _ => null,
            });
            if (access is not null && (!owner.RouteSettingWrites || request.Method is "get" or "me")) return Json(access);
            return owner.Respond is { } respond ? await respond(request, cancellationToken) : Json(List(owner.PhotoJson()));
        }
    }
    public void Dispose() => _http.Dispose();
}
