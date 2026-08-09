using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Locations;

public sealed class FileLocationsRepositoryContractTests
{
    private static readonly NasProfile Profile = new(
        Guid.Parse("11111111-1111-1111-1111-111111111111"),
        "Synthetic",
        "nas.invalid",
        null,
        "tester");

    private static readonly DsmSession Session = new(Profile.Id, "sid", null, null);

    [Fact]
    public async Task FavoritesAcceptMetadataFreePagesAndDeduplicateBeforeTotal()
    {
        var api = new ScriptedApi(request => request.ApiName switch
        {
            "SYNO.FileStation.Favorite" => new JsonObject
            {
                ["favorites"] = new JsonArray
                {
                    Favorite("One", "/share/one"),
                    Favorite("Duplicate", "/share/one"),
                    Favorite(null, "/share/two"),
                },
            },
            _ => throw new InvalidOperationException(),
        });
        var repository = Repository(api, Capability("SYNO.FileStation.Favorite"));

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.True(snapshot.Availability.Favorites);
        Assert.Equal(2, snapshot.Favorites.Total);
        Assert.Equal(3, snapshot.Favorites.SourceItemCount);
        Assert.Equal(FileLocationCompletion.Complete, snapshot.Favorites.Completion);
        Assert.Equal<string>(
            new[] { "/share/one", "/share/two" },
            snapshot.Favorites.Items.Select(item => item.Path));
        var request = Assert.Single(api.Requests);
        Assert.Equal(2, request.Version);
        Assert.Equal("list", request.Method);
        Assert.Equal("0", request.Parameters["offset"]);
        Assert.Equal("500", request.Parameters["limit"]);
    }

    [Fact]
    public async Task FavoritesRequirePairedNativeStablePaginationMetadata()
    {
        var api = new ScriptedApi(_ => new JsonObject
        {
            ["favorites"] = new JsonArray(),
            ["offset"] = "0",
        });
        var repository = Repository(api, Capability("SYNO.FileStation.Favorite"));

        var snapshot = await repository.LoadSnapshotAsync();
        Assert.Equal(FileLocationSectionStatus.Failed, snapshot.Favorites.Status);
    }

    [Fact]
    public async Task FavoritesReportRawServerTotalWhenBoundedAtFiveThousand()
    {
        var api = new ScriptedApi(request =>
        {
            var offset = int.Parse(request.Parameters["offset"], System.Globalization.CultureInfo.InvariantCulture);
            var items = Enumerable.Range(offset, 500)
                .Select(index => Favorite($"Item {index}", $"/share/item-{index}"))
                .ToArray();
            return Page("favorites", offset, 6_000, items);
        });
        var repository = Repository(api, Capability("SYNO.FileStation.Favorite"));

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(5_000, snapshot.Favorites.Total);
        Assert.Equal(6_000, snapshot.Favorites.SourceItemCount);
        Assert.Equal(FileLocationCompletion.Truncated, snapshot.Favorites.Completion);
        Assert.Equal(10, api.Requests.Count);
    }

    [Fact]
    public async Task FavoritesPreserveFirstServerOrderAcrossPageDuplicates()
    {
        var api = new ScriptedApi(request =>
        {
            var offset = int.Parse(request.Parameters["offset"], System.Globalization.CultureInfo.InvariantCulture);
            if (offset == 0)
            {
                return Page(
                    "favorites",
                    0,
                    502,
                    Enumerable.Range(0, 500)
                        .Select(index => Favorite($"Server {index}", $"/share/server-{index}"))
                        .ToArray());
            }
            return Page(
                "favorites",
                500,
                502,
                Favorite("Duplicate renamed", "/share/server-0"),
                Favorite("Last", "/share/last"));
        });
        var repository = Repository(api, Capability("SYNO.FileStation.Favorite"));

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(501, snapshot.Favorites.Total);
        Assert.Equal("/share/server-0", snapshot.Favorites.Items[0].Path);
        Assert.Equal("Server 0", snapshot.Favorites.Items[0].Name);
        Assert.Equal("/share/last", snapshot.Favorites.Items[^1].Path);
    }

    [Fact]
    public async Task RecycleDiscoveryBoundsConcurrencyAndClassifiesChildFailures()
    {
        var inFlight = 0;
        var maximumInFlight = 0;
        var api = new ScriptedApi(async (request, cancellationToken) =>
        {
            if (request.Method == "list_share")
            {
                return Page("shares", 0, 4,
                    Share("alpha", "/alpha"),
                    Share("beta", "/beta"),
                    Share("gamma", "/gamma"),
                    Share("remote", "/remote", "cifs"));
            }
            var current = Interlocked.Increment(ref inFlight);
            UpdateMaximum(ref maximumInFlight, current);
            try
            {
                await Task.Delay(10, cancellationToken);
                return request.Parameters["folder_path"] switch
                {
                    "/alpha/#recycle" => Page("files", 0, 0),
                    "/beta/#recycle" => throw DsmFailure(105),
                    "/gamma/#recycle" => throw DsmFailure(408),
                    _ => throw new InvalidOperationException(),
                };
            }
            finally
            {
                Interlocked.Decrement(ref inFlight);
            }
        });
        var repository = Repository(api, Capability("SYNO.FileStation.List"));

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(3, snapshot.RecycleBins.AttemptedShareCount);
        Assert.Equal(1, snapshot.RecycleBins.NotFoundShareCount);
        Assert.Equal(1, snapshot.RecycleBins.PermissionDeniedShareCount);
        Assert.True(snapshot.RecycleBins.IsPartial);
        Assert.Equal("/alpha/#recycle", Assert.Single(snapshot.RecycleBins.Items).RecyclePath);
        Assert.InRange(maximumInFlight, 1, 4);
        Assert.DoesNotContain(api.Requests, request =>
            request.Parameters.GetValueOrDefault("folder_path") == "/remote/#recycle");
    }

    [Fact]
    public async Task SectionFailuresPreserveOtherSuccessfulSections()
    {
        var api = new ScriptedApi(request => request.ApiName switch
        {
            "SYNO.FileStation.Favorite" => new JsonObject
            {
                ["favorites"] = new JsonArray { Favorite("Kept", "/share/kept") },
            },
            "SYNO.FileStation.List" => Page("shares", 0, 0),
            "SYNO.FileStation.Info" => throw DsmFailure(500),
            _ => throw new InvalidOperationException(),
        });
        var repository = Repository(
            api,
            Capability("SYNO.FileStation.Favorite"),
            Capability("SYNO.FileStation.List"),
            Capability("SYNO.FileStation.Info"),
            Capability("SYNO.FileStation.VirtualFolder"));

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(FileLocationSectionStatus.Available, snapshot.Favorites.Status);
        Assert.Equal("/share/kept", Assert.Single(snapshot.Favorites.Items).Path);
        Assert.Equal(FileLocationSectionStatus.Available, snapshot.RecycleBins.Status);
        Assert.Equal(FileLocationSectionStatus.Failed, snapshot.RemoteLocations.Status);
        Assert.NotNull(snapshot.RemoteLocations.FailureDiagnosticTag);
    }

    [Fact]
    public async Task RecycleNetworkFailureFailsSectionInsteadOfLookingLikeMissingFolder()
    {
        var api = new ScriptedApi(request => request.Method == "list_share"
            ? Page("shares", 0, 1, Share("alpha", "/alpha"))
            : throw new DsmException("network", "retry"));
        var repository = Repository(api, Capability("SYNO.FileStation.List"));

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(FileLocationSectionStatus.Failed, snapshot.RecycleBins.Status);
        Assert.Equal(0, snapshot.RecycleBins.NotFoundShareCount);
        Assert.Equal(0, snapshot.RecycleBins.PermissionDeniedShareCount);
        Assert.NotNull(snapshot.RecycleBins.FailureDiagnosticTag);
    }

    [Fact]
    public async Task RecycleProbesAtMostFiveHundredSharesAfterBoundedListing()
    {
        var shares = Enumerable.Range(0, 501)
            .Select(index => Share($"Share {index:D3}", $"/share-{index:D3}"))
            .ToArray();
        var api = new ScriptedApi(request =>
        {
            if (request.Method != "list_share")
            {
                return Page("files", 0, 0);
            }
            var offset = int.Parse(request.Parameters["offset"], System.Globalization.CultureInfo.InvariantCulture);
            var limit = int.Parse(request.Parameters["limit"], System.Globalization.CultureInfo.InvariantCulture);
            return Page("shares", offset, 501, shares.Skip(offset).Take(limit).ToArray());
        });
        var repository = Repository(api, Capability("SYNO.FileStation.List"));

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(500, snapshot.RecycleBins.AttemptedShareCount);
        Assert.Equal(500, snapshot.RecycleBins.Items.Count);
        Assert.Equal(FileLocationCompletion.Truncated, snapshot.RecycleBins.Completion);
        Assert.Equal(500, api.Requests.Count(request => request.Method == "list"));
    }

    [Fact]
    public async Task LegacyApiStubWithoutFixedReadSeamProducesExplicitFailedSection()
    {
        IFileLocationsRepository repository = new DsmRepository(
            Profile,
            Session,
            new LegacyApi(),
            new Dictionary<string, ApiCapability>
            {
                ["SYNO.FileStation.Favorite"] = Capability("SYNO.FileStation.Favorite"),
            });

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(FileLocationSectionStatus.Failed, snapshot.Favorites.Status);
        Assert.Equal(FileLocationSectionStatus.Unavailable, snapshot.RecycleBins.Status);
    }

    [Fact]
    public async Task FavoriteFailurePreservesRecycleAndRemoteSections()
    {
        var api = new ScriptedApi(request => request.ApiName switch
        {
            "SYNO.FileStation.Favorite" => throw new InvalidDataException("synthetic"),
            "SYNO.FileStation.List" => Page("shares", 0, 0),
            "SYNO.FileStation.Info" => new JsonObject { ["support_virtual_protocol"] = "" },
            _ => throw new InvalidOperationException(),
        });
        var repository = Repository(
            api,
            Capability("SYNO.FileStation.Favorite"),
            Capability("SYNO.FileStation.List"),
            Capability("SYNO.FileStation.Info"),
            Capability("SYNO.FileStation.VirtualFolder"));

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(FileLocationSectionStatus.Failed, snapshot.Favorites.Status);
        Assert.Equal(FileLocationSectionStatus.Available, snapshot.RecycleBins.Status);
        Assert.Equal(FileLocationSectionStatus.Available, snapshot.RemoteLocations.Status);
    }

    [Fact]
    public async Task RemoteLocationsUseOneProtocolPerRequestAndStageFailedProtocol()
    {
        var api = new ScriptedApi(request =>
        {
            if (request.ApiName == "SYNO.FileStation.Info")
            {
                return new JsonObject { ["support_virtual_protocol"] = "cifs,nfs,iso,unknown" };
            }
            return request.Parameters["type"] switch
            {
                "cifs" => Page("folders", 0, 2,
                    Remote("Share", "/remote/share", "cifs"),
                    Remote("Share duplicate", "/remote/share", "cifs")),
                "nfs" => throw DsmFailure(500),
                "iso" => Page("folders", 0, 1, Remote("Disc", "/remote/disc", "iso")),
                _ => throw new InvalidOperationException(),
            };
        });
        var repository = Repository(
            api,
            Capability("SYNO.FileStation.Info"),
            Capability("SYNO.FileStation.VirtualFolder"));

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.True(snapshot.RemoteLocations.IsPartial);
        Assert.Equal<FileRemoteProtocol>(
            new[] { FileRemoteProtocol.Nfs },
            snapshot.RemoteLocations.UnavailableProtocols);
        Assert.Equal(2, snapshot.RemoteLocations.Total);
        Assert.Equal(3, snapshot.RemoteLocations.SourceItemCount);
        Assert.True(snapshot.RemoteLocations.Items.Single(item => item.Protocol == FileRemoteProtocol.Iso).IsReadOnly);
        var virtualRequests = api.Requests.Where(request => request.ApiName == "SYNO.FileStation.VirtualFolder").ToArray();
        Assert.All(virtualRequests, request => Assert.DoesNotContain("all", request.Parameters.Values));
        Assert.All(virtualRequests, request => Assert.Equal("500", request.Parameters["limit"]));
        Assert.All(virtualRequests, request => Assert.Equal("[\"mount_point_type\",\"perm\"]", request.Parameters["additional"]));
    }

    [Fact]
    public async Task Code104IsSectionFailureWhileSession119AndCancellationPropagateGlobally()
    {
        var code104Api = new ScriptedApi(request => request.Method == "list_share"
            ? Page("shares", 0, 1, Share("alpha", "/alpha"))
            : throw new DsmException("auth", "login", 104, authenticationFailure: true));
        var code104Repository = Repository(code104Api, Capability("SYNO.FileStation.List"));
        var code104Snapshot = await code104Repository.LoadSnapshotAsync();
        Assert.Equal(FileLocationSectionStatus.Failed, code104Snapshot.RecycleBins.Status);

        var sessionApi = new ScriptedApi(request => request.Method == "list_share"
            ? Page("shares", 0, 1, Share("alpha", "/alpha"))
            : throw new DsmException("session", "login", 119));
        var sessionRepository = Repository(sessionApi, Capability("SYNO.FileStation.List"));
        var error = await Assert.ThrowsAsync<DsmException>(() => sessionRepository.LoadSnapshotAsync());
        Assert.Equal(119, error.Code);

        var unauthorizedApi = new ScriptedApi(request => request.Method == "list_share"
            ? Page("shares", 0, 1, Share("alpha", "/alpha"))
            : throw new DsmException("unauthorized", "login", 401, authenticationFailure: true));
        var unauthorizedRepository = Repository(unauthorizedApi, Capability("SYNO.FileStation.List"));
        var unauthorized = await Assert.ThrowsAsync<DsmException>(
            () => unauthorizedRepository.LoadSnapshotAsync());
        Assert.Equal(401, unauthorized.Code);

        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var canceledApi = new ScriptedApi(_ => throw new InvalidOperationException());
        var canceledRepository = Repository(canceledApi, Capability("SYNO.FileStation.Favorite"));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => canceledRepository.LoadSnapshotAsync(cancellation.Token));
        Assert.Empty(canceledApi.Requests);
    }

    [Fact]
    public async Task Code104MakesOnlyAdvertisedRemoteProtocolUnavailable()
    {
        var api = new ScriptedApi(request => request.ApiName == "SYNO.FileStation.Info"
            ? new JsonObject { ["support_virtual_protocol"] = "cifs,nfs" }
            : request.Parameters["type"] == "cifs"
                ? Page("folders", 0, 1, Remote("Share", "/remote/share", "cifs"))
                : throw new DsmException("auth", "retry", 104, authenticationFailure: true));
        var repository = Repository(
            api,
            Capability("SYNO.FileStation.Info"),
            Capability("SYNO.FileStation.VirtualFolder"));

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(FileLocationSectionStatus.Available, snapshot.RemoteLocations.Status);
        Assert.True(snapshot.RemoteLocations.IsPartial);
        Assert.Equal(new[] { FileRemoteProtocol.Nfs }, snapshot.RemoteLocations.UnavailableProtocols);
        Assert.Single(snapshot.RemoteLocations.Items);
    }

    [Fact]
    public async Task WrongCapabilityNameIsUnavailableAndSendsNoRequest()
    {
        var api = new ScriptedApi(_ => throw new InvalidOperationException());
        IFileLocationsRepository repository = new DsmRepository(
            Profile,
            Session,
            api,
            new Dictionary<string, ApiCapability>
            {
                ["SYNO.FileStation.Favorite"] = Capability("SYNO.FileStation.List"),
            });

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.False(repository.Availability.Favorites);
        Assert.Equal(FileLocationSectionStatus.Unavailable, snapshot.Favorites.Status);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task UnknownShareMountTypeIsNotProbedAndProbeZeroProgressFailsSection()
    {
        var unknownApi = new ScriptedApi(request => request.Method == "list_share"
            ? Page("shares", 0, 1, Share("unknown", "/unknown", "future_type"))
            : throw new InvalidOperationException());
        var unknownRepository = Repository(unknownApi, Capability("SYNO.FileStation.List"));
        var unknownSnapshot = await unknownRepository.LoadSnapshotAsync();
        Assert.Equal(FileLocationSectionStatus.Available, unknownSnapshot.RecycleBins.Status);
        Assert.Equal(0, unknownSnapshot.RecycleBins.AttemptedShareCount);

        var zeroProgressApi = new ScriptedApi(request => request.Method == "list_share"
            ? Page("shares", 0, 1, Share("alpha", "/alpha", "normal"))
            : Page("files", 0, 1));
        var zeroProgressRepository = Repository(zeroProgressApi, Capability("SYNO.FileStation.List"));
        var zeroProgressSnapshot = await zeroProgressRepository.LoadSnapshotAsync();
        Assert.Equal(FileLocationSectionStatus.Failed, zeroProgressSnapshot.RecycleBins.Status);
    }

    [Fact]
    public void LocationImplementationContainsNoWriteOrMountManagementCalls()
    {
        var source = File.ReadAllText(FindRepositorySource());
        Assert.DoesNotContain("\"add\"", source, StringComparison.Ordinal);
        Assert.DoesNotContain("\"delete\"", source, StringComparison.Ordinal);
        Assert.DoesNotContain("\"create\"", source, StringComparison.Ordinal);
        Assert.DoesNotContain("\"mount\"", source, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\"unmount\"", source, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\"restore\"", source, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("SYNO.FileStation.Mount", source, StringComparison.Ordinal);
        Assert.DoesNotContain("SYNO.FileStation.VFS", source, StringComparison.Ordinal);
        Assert.DoesNotContain("[\"type\"] = \"all\"", source, StringComparison.Ordinal);
    }

    private static IFileLocationsRepository Repository(ScriptedApi api, params ApiCapability[] capabilities) =>
        new DsmRepository(
            Profile,
            Session,
            api,
            capabilities.ToDictionary(item => item.Name, StringComparer.Ordinal));

    private static ApiCapability Capability(string name) =>
        new(name, "entry.cgi", 2, 3, "FORM");

    private static JsonObject Favorite(string? name, string path) => new()
    {
        ["name"] = name,
        ["path"] = path,
    };

    private static JsonObject Share(string name, string path, string? mountType = null) => new()
    {
        ["name"] = name,
        ["path"] = path,
        ["isdir"] = true,
        ["additional"] = mountType is null
            ? new JsonObject()
            : new JsonObject { ["mount_point_type"] = mountType },
    };

    private static JsonObject Remote(string name, string path, string protocol) => new()
    {
        ["name"] = name,
        ["path"] = path,
        ["isdir"] = true,
        ["additional"] = new JsonObject { ["mount_point_type"] = protocol },
    };

    private static JsonObject Page(string root, int offset, int total, params JsonObject[] items) => new()
    {
        [root] = new JsonArray(items.Select(item => (JsonNode)item).ToArray()),
        ["offset"] = offset,
        ["total"] = total,
    };

    private static DsmException DsmFailure(int code) => new("failure", "retry", code);

    private static void UpdateMaximum(ref int maximum, int value)
    {
        while (true)
        {
            var observed = Volatile.Read(ref maximum);
            if (observed >= value || Interlocked.CompareExchange(ref maximum, value, observed) == observed)
            {
                return;
            }
        }
    }

    private static string FindRepositorySource()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var candidate = Path.Combine(
                directory.FullName,
                "src",
                "LanStash.Infrastructure",
                "Features",
                "Files",
                "Locations",
                "DsmRepository.FileLocations.cs");
            if (File.Exists(candidate)) return candidate;
            directory = directory.Parent;
        }
        throw new FileNotFoundException("Could not locate the file-locations source contract.");
    }

    private sealed record ApiRequest(
        string ApiName,
        int Version,
        string Method,
        IReadOnlyDictionary<string, string> Parameters);

    private sealed class ScriptedApi : IDsmApiClient
    {
        private readonly Func<ApiRequest, CancellationToken, Task<JsonObject>> _handler;

        public ScriptedApi(Func<ApiRequest, JsonObject> handler) :
            this((request, _) => Task.FromResult(handler(request))) { }

        public ScriptedApi(Func<ApiRequest, CancellationToken, Task<JsonObject>> handler) =>
            _handler = handler;

        public ConcurrentQueue<ApiRequest> Requests { get; } = new();

        public Task<JsonObject> CallReadJsonObjectAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            int requiredVersion,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var request = new ApiRequest(
                capability.Name,
                requiredVersion,
                method,
                new Dictionary<string, string>(parameters ?? new Dictionary<string, string>()));
            Requests.Enqueue(request);
            return _handler(request, cancellationToken);
        }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid/");
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallAsync(NasProfile profile, DsmSession session, ApiCapability capability, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }

    private sealed class LegacyApi : IDsmApiClient
    {
        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid/");
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallAsync(NasProfile profile, DsmSession session, ApiCapability capability, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
