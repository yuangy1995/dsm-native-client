using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class VirtualMachineManagerRepositoryContractTests
{
    private static readonly Guid ProfileId =
        Guid.Parse("22222222-2222-2222-2222-222222222222");

    [Fact]
    public async Task UnavailableContractMakesNoRequestAndInternalApiIsNotAReadFallback()
    {
        var api = new VirtualMachineRecordingApiClient(_ => throw new InvalidOperationException());
        IVirtualMachineManagerRepository repository = CreateRepository(
            api,
            Capability("SYNO.Virtualization.Guest", 1, 2));

        Assert.Equal(VirtualMachineManagerAvailabilityStatus.Unavailable, repository.Availability.Status);
        Assert.DoesNotContain(AppModule.VirtualMachines, ((DsmRepository)repository).AvailableModules);

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(ProfileId, snapshot.ProfileId);
        Assert.Equal(VirtualMachineManagerSectionStatus.Unavailable, snapshot.Machines.Status);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task OfficialV1LoadsFiveTypedIndependentSectionsAndNeverCallsInternalApis()
    {
        var api = new VirtualMachineRecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Virtualization.API.Guest" => Guests(
                new JsonObject
                {
                    ["guest_id"] = "vm-1",
                    ["guest_name"] = "Synthetic VM",
                    ["status"] = "shutdown",
                    ["vcpu_num"] = 2,
                    ["vram_size"] = 2048,
                    ["host_id"] = "host-1",
                    ["host_name"] = "Synthetic Host",
                    ["vdisks"] = new JsonArray(new JsonObject { ["vdisk_size"] = 10240 }),
                }),
            "SYNO.Virtualization.API.Host" => Resources(
                "hosts",
                new JsonObject
                {
                    ["host_id"] = "host-1",
                    ["host_name"] = "Synthetic Host",
                    ["status"] = "running",
                }),
            "SYNO.Virtualization.API.Storage" => Resources(
                "storages",
                new JsonObject
                {
                    ["storage_id"] = "storage-1",
                    ["storage_name"] = "Synthetic Storage",
                    ["status"] = "online",
                    ["allocated_size"] = 10L,
                    ["size"] = 100L,
                }),
            "SYNO.Virtualization.API.Network" => Resources(
                "networks",
                new JsonObject
                {
                    ["network_id"] = 7,
                    ["network_name"] = "Synthetic Network",
                }),
            "SYNO.Virtualization.API.Guest.Image" => Resources(
                "images",
                new JsonObject
                {
                    ["image_id"] = "image-1",
                    ["image_name"] = "Synthetic Image",
                    ["type"] = "iso",
                }),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        IVirtualMachineManagerRepository repository = CreateRepository(
            api,
            PublicCapabilities().Concat(
            [
                Capability("SYNO.Virtualization.Guest", 1, 2),
                Capability("SYNO.Virtualization.Host", 1, 2),
            ]).ToArray());

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(ProfileId, repository.ProfileId);
        Assert.Equal(ProfileId, snapshot.ProfileId);
        Assert.All(api.Requests, request =>
        {
            Assert.StartsWith("SYNO.Virtualization.API.", request.ApiName, StringComparison.Ordinal);
            Assert.Equal(1, request.Version);
            Assert.Equal("list", request.Method);
            Assert.Empty(request.Parameters);
        });
        Assert.Equal(5, api.Requests.Count);
        Assert.All(
            new[]
            {
                snapshot.Machines.Status,
                snapshot.Hosts.Status,
                snapshot.Storages.Status,
                snapshot.Networks.Status,
                snapshot.Images.Status,
            },
            status => Assert.Equal(VirtualMachineManagerSectionStatus.Available, status));
        var machine = Assert.Single(snapshot.Machines.Items);
        Assert.Equal("vm-1", machine.Id);
        Assert.Equal(VirtualMachineOperationalState.Stopped, machine.State);
        Assert.Equal(2_147_483_648L, machine.MemoryBytes);
        Assert.Equal(10_737_418_240L, machine.StorageBytes);
        Assert.Equal("7", Assert.Single(snapshot.Networks.Items).Id);
        Assert.Equal("iso", Assert.Single(snapshot.Images.Items).Type);
    }

    [Fact]
    public async Task MissingSupplementaryCapabilityIsUnavailableWithoutARequest()
    {
        var api = new VirtualMachineRecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Virtualization.API.Guest" => Guests(),
            "SYNO.Virtualization.API.Host" => Resources("hosts"),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        IVirtualMachineManagerRepository repository = CreateRepository(
            api,
            Capability("SYNO.Virtualization.API.Guest", 1, 4),
            Capability("SYNO.Virtualization.API.Host", 1, 1));

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(VirtualMachineManagerSectionStatus.Available, snapshot.Machines.Status);
        Assert.Equal(VirtualMachineManagerSectionStatus.Available, snapshot.Hosts.Status);
        Assert.Equal(VirtualMachineManagerSectionStatus.Unavailable, snapshot.Storages.Status);
        Assert.Equal(VirtualMachineManagerSectionStatus.Unavailable, snapshot.Networks.Status);
        Assert.Equal(VirtualMachineManagerSectionStatus.Unavailable, snapshot.Images.Status);
        Assert.Equal(2, api.Requests.Count);
        Assert.All(api.Requests, request => Assert.Equal(1, request.Version));
    }

    [Fact]
    public async Task SupplementaryFailureIsExplicitAndDoesNotHideOtherSections()
    {
        var api = new VirtualMachineRecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Virtualization.API.Guest" => Guests(),
            "SYNO.Virtualization.API.Host" => throw new DsmException("failed", "retry", 402),
            "SYNO.Virtualization.API.Storage" => Resources("storages"),
            "SYNO.Virtualization.API.Network" => Resources("networks"),
            "SYNO.Virtualization.API.Guest.Image" => Resources("images"),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        IVirtualMachineManagerRepository repository = CreateRepository(api, PublicCapabilities());

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(VirtualMachineManagerSectionStatus.Failed, snapshot.Hosts.Status);
        Assert.Equal(VirtualMachineManagerSectionStatus.Available, snapshot.Machines.Status);
        Assert.Equal(VirtualMachineManagerSectionStatus.Available, snapshot.Storages.Status);
        Assert.Equal(VirtualMachineManagerSectionStatus.Available, snapshot.Networks.Status);
        Assert.Equal(VirtualMachineManagerSectionStatus.Available, snapshot.Images.Status);
        Assert.Empty(snapshot.Hosts.Items);
    }

    [Fact]
    public async Task AuthenticationFailureAndCancellationAreNeverConvertedToASectionFailure()
    {
        var authenticationApi = new VirtualMachineRecordingApiClient(_ =>
            throw new DsmException("login", "login", 119, authenticationFailure: true));
        IVirtualMachineManagerRepository authenticationRepository = CreateRepository(
            authenticationApi,
            Capability("SYNO.Virtualization.API.Guest"));

        var authentication = await Assert.ThrowsAsync<DsmException>(
            () => authenticationRepository.LoadSnapshotAsync());
        Assert.True(authentication.AuthenticationFailure);

        var cancellationApi = new VirtualMachineRecordingApiClient(_ => Guests());
        IVirtualMachineManagerRepository cancellationRepository = CreateRepository(
            cancellationApi,
            Capability("SYNO.Virtualization.API.Guest"));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(
            () => cancellationRepository.LoadSnapshotAsync(cancellation.Token));
    }

    [Fact]
    public async Task MismatchedSessionProfileFailsBeforeAnyRequest()
    {
        var api = new VirtualMachineRecordingApiClient(_ => Guests());
        IVirtualMachineManagerRepository repository = new DsmRepository(
            new NasProfile(ProfileId, "Synthetic NAS", "nas.invalid", 5001, "tester"),
            new DsmSession(Guid.NewGuid(), "synthetic-sid", null, null),
            api,
            new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
            {
                ["SYNO.Virtualization.API.Guest"] =
                    Capability("SYNO.Virtualization.API.Guest"),
            });

        var error = await Assert.ThrowsAsync<DsmException>(() => repository.LoadSnapshotAsync());

        Assert.True(error.AuthenticationFailure);
        Assert.Empty(api.Requests);
    }

    [Theory]
    [MemberData(nameof(InvalidGuestResponses))]
    public async Task InvalidOrUnstableGuestIdentityFailsClosedWithoutInventingAnId(JsonObject response)
    {
        var api = new VirtualMachineRecordingApiClient(_ => response);
        IVirtualMachineManagerRepository repository = CreateRepository(
            api,
            Capability("SYNO.Virtualization.API.Guest"));

        var snapshot = await repository.LoadSnapshotAsync();

        Assert.Equal(VirtualMachineManagerSectionStatus.Failed, snapshot.Machines.Status);
        Assert.Empty(snapshot.Machines.Items);
    }

    [Fact]
    public void ProductionSourcesContainNoLegacyContainerOrVirtualMachineWriteChain()
    {
        var combined = string.Join(
            '\n',
            Read("windows/src/LanStash.Domain/Repository/IDsmRepository.cs"),
            Read("windows/src/LanStash.Infrastructure/DsmRepository.cs"),
            Read("windows/src/LanStash.App/ViewModels/WorkspaceViewModel.cs"),
            Read("windows/src/LanStash.App/Views/WorkspacePage.xaml"),
            Read("windows/src/LanStash.App/Views/WorkspacePage.xaml.cs"),
            Read("windows/src/LanStash.Infrastructure/Features/VirtualMachines/PublicApi/DsmRepository.VirtualMachineManager.Public.cs"));

        foreach (var forbidden in new[]
        {
            "ControlContainerAsync", "DeleteContainerAsync", "DeleteContainerImageAsync",
            "CreateContainerNetworkAsync", "DeleteContainerNetworkAsync",
            "ControlVirtualMachineAsync", "DeleteVirtualMachineAsync",
            "RenameVirtualMachineNetworkAsync", "DeleteVirtualMachineNetworkAsync",
            "DeleteVirtualMachineImageAsync", "SYNO.Virtualization.Guest.Action",
        })
        {
            Assert.DoesNotContain(forbidden, combined, StringComparison.Ordinal);
        }
    }

    public static IEnumerable<object[]> InvalidGuestResponses()
    {
        yield return [new JsonObject()];
        yield return [Guests(new JsonObject
        {
            ["guest_name"] = "Missing id",
            ["status"] = "running",
        })];
        yield return [Guests(
            new JsonObject
            {
                ["guest_id"] = "duplicate",
                ["guest_name"] = "One",
                ["status"] = "running",
            },
            new JsonObject
            {
                ["guest_id"] = "duplicate",
                ["guest_name"] = "Two",
                ["status"] = "shutdown",
            })];
    }

    private static DsmRepository CreateRepository(
        VirtualMachineRecordingApiClient api,
        params ApiCapability[] capabilities) =>
        new(
            new NasProfile(ProfileId, "Synthetic NAS", "nas.invalid", 5001, "tester"),
            new DsmSession(ProfileId, "synthetic-sid", null, null),
            api,
            capabilities.ToDictionary(item => item.Name, StringComparer.Ordinal));

    private static ApiCapability Capability(
        string name,
        int minimum = 1,
        int maximum = 1) =>
        new(name, "entry.cgi", minimum, maximum, "FORM");

    private static ApiCapability[] PublicCapabilities() =>
    [
        Capability("SYNO.Virtualization.API.Guest", 1, 4),
        Capability("SYNO.Virtualization.API.Host", 1, 3),
        Capability("SYNO.Virtualization.API.Storage", 1, 2),
        Capability("SYNO.Virtualization.API.Network", 1, 5),
        Capability("SYNO.Virtualization.API.Guest.Image", 1, 2),
    ];

    private static JsonObject Guests(params JsonObject[] items) =>
        Resources("guests", items);

    private static JsonObject Resources(string root, params JsonObject[] items) => new()
    {
        [root] = new JsonArray(items.Select(item => (JsonNode)item).ToArray()),
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

    private sealed record VirtualMachineApiRequest(
        string ApiName,
        string Method,
        int Version,
        IReadOnlyDictionary<string, string> Parameters);

    private sealed class VirtualMachineRecordingApiClient(
        Func<VirtualMachineApiRequest, JsonObject> response) : IDsmApiClient
    {
        public List<VirtualMachineApiRequest> Requests { get; } = [];

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var request = new VirtualMachineApiRequest(
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
