using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class ContainerManagerRepositoryContractTests
{
    private static readonly Guid ProfileId =
        Guid.Parse("33333333-3333-3333-3333-333333333333");

    [Fact]
    public async Task MissingOrV2OnlyCapabilityIsUnavailableAndMakesNoRequest()
    {
        foreach (var capabilities in new[]
        {
            Array.Empty<ApiCapability>(),
            new[] { Capability(2, 4) },
        })
        {
            var api = new RecordingApiClient(_ => throw new InvalidOperationException());
            IContainerManagerRepository repository = CreateRepository(api, capabilities);

            Assert.Equal(
                ContainerManagerAvailabilityStatus.Unavailable,
                repository.Availability.Status);
            Assert.DoesNotContain(AppModule.Containers, ((DsmRepository)repository).AvailableModules);
            var snapshot = await repository.LoadSnapshotAsync();
            Assert.Equal(ProfileId, snapshot.ProfileId);
            Assert.Empty(snapshot.Containers);
            Assert.Empty(api.Requests);
        }
    }

    [Fact]
    public async Task ObservedContractUsesOnlyFixedV1ListWireAndParsesStableFields()
    {
        var api = new RecordingApiClient(_ => Containers(
            Container("container-1", "Web", "running", "example/web:1"),
            Container("container-2", "Worker", "stopped", "example/worker:2"),
            Container("container-3", "Review", "future", "example/review:3"),
            Container("container-4", "Broken", "error", "example/broken:4")));
        IContainerManagerRepository repository = CreateRepository(api, Capability(1, 7));

        Assert.Equal(
            ContainerManagerAvailabilityStatus.InternalObserved,
            repository.Availability.Status);
        Assert.Contains(AppModule.Containers, ((DsmRepository)repository).AvailableModules);
        var snapshot = await repository.LoadSnapshotAsync();

        var request = Assert.Single(api.Requests);
        Assert.Equal("SYNO.Docker.Container", request.ApiName);
        Assert.Equal("list", request.Method);
        Assert.Equal(1, request.Version);
        Assert.Equal(3, request.Parameters.Count);
        Assert.Equal("0", request.Parameters["offset"]);
        Assert.Equal("-1", request.Parameters["limit"]);
        Assert.Equal("all", request.Parameters["type"]);
        Assert.Equal(ProfileId, snapshot.ProfileId);
        Assert.Collection(
            snapshot.Containers,
            item => Assert.Equal(
                ("container-1", "Web", ContainerOperationalState.Running, "example/web:1"),
                (item.Id, item.Name, item.State, item.Image)),
            item => Assert.Equal(ContainerOperationalState.Stopped, item.State),
            item => Assert.Equal(ContainerOperationalState.Unknown, item.State),
            item => Assert.Equal(ContainerOperationalState.Attention, item.State));
    }

    [Fact]
    public async Task RootAndItemTypesAreStrict()
    {
        JsonObject[] invalidResponses =
        [
            new(),
            new() { ["containers"] = new JsonObject() },
            new() { ["containers"] = new JsonArray("not-an-object") },
            Containers(new JsonObject
            {
                ["id"] = 1,
                ["name"] = "name",
                ["status"] = "running",
            }),
            Containers(new JsonObject
            {
                ["id"] = "id",
                ["name"] = " ",
                ["status"] = "running",
            }),
            Containers(new JsonObject
            {
                ["id"] = "id",
                ["name"] = "name",
                ["status"] = "running",
                ["image"] = 42,
            }),
        ];

        foreach (var response in invalidResponses)
        {
            var repository = CreateRepository(
                new RecordingApiClient(_ => response),
                Capability(1, 1));
            await Assert.ThrowsAsync<DsmException>(() => repository.LoadSnapshotAsync());
        }
    }

    [Fact]
    public async Task StableCoreFieldsAreRequiredImageIsOptionalAndDuplicateIdsFail()
    {
        foreach (var key in new[] { "id", "name", "status" })
        {
            var item = Container("id", "name", "running", "image");
            item.Remove(key);
            var repository = CreateRepository(
                new RecordingApiClient(_ => Containers(item)),
                Capability(1, 1));
            await Assert.ThrowsAsync<DsmException>(() => repository.LoadSnapshotAsync());
        }

        var withoutImage = Container("without-image", "name", "running", "unused");
        withoutImage.Remove("image");
        var optionalImageRepository = CreateRepository(
            new RecordingApiClient(_ => Containers(withoutImage)),
            Capability(1, 1));
        var optionalImageSnapshot = await optionalImageRepository.LoadSnapshotAsync();
        Assert.Null(Assert.Single(optionalImageSnapshot.Containers).Image);

        var duplicateRepository = CreateRepository(
            new RecordingApiClient(_ => Containers(
                Container("same", "first", "running", "image-a"),
                Container("same", "second", "stopped", "image-b"))),
            Capability(1, 1));
        await Assert.ThrowsAsync<DsmException>(() => duplicateRepository.LoadSnapshotAsync());
    }

    [Fact]
    public async Task ProfileMismatchFailsBeforeInternalRequest()
    {
        var api = new RecordingApiClient(_ => Containers());
        IContainerManagerRepository repository = new DsmRepository(
            Profile(),
            new DsmSession(Guid.NewGuid(), "sid", null, null),
            api,
            new Dictionary<string, ApiCapability>
            {
                ["SYNO.Docker.Container"] = Capability(1, 1),
            });

        await Assert.ThrowsAsync<InvalidOperationException>(() => repository.LoadSnapshotAsync());
        Assert.Empty(api.Requests);
    }

    [Fact]
    public void ContractSurfaceContainsNoOtherContainerAreasOrWriteMethods()
    {
        var combined =
            Read("windows/src/LanStash.Domain/Containers/ContainerManagerModels.cs") +
            Read("windows/src/LanStash.Domain/Containers/IContainerManagerRepository.cs") +
            Read("windows/src/LanStash.Infrastructure/Features/Containers/PrivateApi/DsmRepository.ContainerManager.Private.cs") +
            Read("windows/src/LanStash.App/Features/Containers/ContainerManagerState.cs") +
            Read("windows/src/LanStash.App/Features/Containers/ContainerManagerViewModel.cs");

        foreach (var forbidden in new[]
        {
            "SYNO.Docker.Image", "SYNO.Docker.Network", "SYNO.Docker.Project",
            "Registry", "Process", "LoadImages", "LoadNetworks", "LoadProjects",
            "LoadLogs", "CreateContainer", "DeleteContainer", "StartContainer",
            "StopContainer", "RestartContainer", "ControlContainer"
        })
        {
            Assert.DoesNotContain(forbidden, combined, StringComparison.OrdinalIgnoreCase);
        }
        Assert.Contains("\"list\"", combined, StringComparison.Ordinal);
        Assert.DoesNotContain("\"create\"", combined, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\"delete\"", combined, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\"start\"", combined, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\"stop\"", combined, StringComparison.OrdinalIgnoreCase);
    }

    private static IContainerManagerRepository CreateRepository(
        RecordingApiClient api,
        params ApiCapability[] capabilities) => new DsmRepository(
            Profile(),
            new DsmSession(ProfileId, "sid", null, null),
            api,
            capabilities.ToDictionary(item => item.Name, StringComparer.Ordinal));

    private static NasProfile Profile() => new(
        ProfileId,
        "Synthetic NAS",
        "https://nas.invalid",
        null,
        "user");

    private static ApiCapability Capability(int minimum, int maximum) => new(
        "SYNO.Docker.Container",
        "entry.cgi",
        minimum,
        maximum,
        "FORM");

    private static JsonObject Containers(params JsonObject[] items) => new()
    {
        ["containers"] = new JsonArray(items.Select(item => (JsonNode)item).ToArray()),
    };

    private static JsonObject Container(
        string id,
        string name,
        string status,
        string image) => new()
        {
            ["id"] = id,
            ["name"] = name,
            ["status"] = status,
            ["image"] = image,
        };

    private static string Read(string relativePath)
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, relativePath);
            if (File.Exists(candidate))
            {
                return File.ReadAllText(candidate);
            }
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException(relativePath);
    }

    private sealed record ContainerApiRequest(
        string ApiName,
        string Method,
        int Version,
        IReadOnlyDictionary<string, string> Parameters);

    private sealed class RecordingApiClient(Func<ContainerApiRequest, JsonObject> response)
        : IDsmApiClient
    {
        public List<ContainerApiRequest> Requests { get; } = [];

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var request = new ContainerApiRequest(
                capability.Name,
                method,
                capability.MaxVersion,
                new Dictionary<string, string>(
                    parameters ?? new Dictionary<string, string>(StringComparer.Ordinal),
                    StringComparer.Ordinal));
            Requests.Add(request);
            return Task.FromResult(response(request));
        }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid");
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(
            NasProfile profile,
            string password,
            string? otp,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(
            NasProfile profile,
            DsmSession session,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string remotePath,
            long offset,
            long length,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
