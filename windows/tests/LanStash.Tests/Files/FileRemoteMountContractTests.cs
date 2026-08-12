using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files;

public sealed class FileRemoteMountContractTests
{
    private static readonly NasProfile Profile = new(
        Guid.Parse("22222222-2222-2222-2222-222222222222"),
        "MountTest",
        "nas.invalid",
        null,
        "tester");

    private static readonly DsmSession Session = new(Profile.Id, "sid-mount", null, null);

    [Fact]
    public async Task ValidRemoteMountWritesStayDisabledWithoutTypedSubmissionBoundary()
    {
        var api = new ScriptedApi(_ => throw new InvalidOperationException("must not send"));
        var repository = MountRepository(api);

        var draft = ValidDraft();
        var create = await repository.CreateRemoteMountAsync(draft);
        var update = await repository.UpdateRemoteMountAsync(new RemoteMountDraft(
            draft.Server,
            draft.RemotePath,
            draft.MountPoint,
            draft.Username,
            draft.Password,
            draft.Domain,
            draft.ReadOnly,
            draft.Protocol,
            existingMountPoint: "/remote-mount"));
        var delete = await repository.DeleteRemoteMountAsync("/remote-mount");

        Assert.False(repository.AllowsRemoteMountManagement);
        Assert.All(new[] { create, update, delete }, result =>
        {
            Assert.Equal(MutationResultStatus.Unsupported, result.Status);
            Assert.False(result.Submitted);
        });
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task CreateRemoteMount_WithoutCapability_ReturnsUnsupported()
    {
        var api = new ScriptedApi(_ => throw new InvalidOperationException());
        IFileLocationsRepository repository = new DsmRepository(
            Profile, Session, api, new Dictionary<string, ApiCapability>());

        Assert.False(repository.AllowsRemoteMountManagement);

        var draft = ValidDraft();

        var result = await repository.CreateRemoteMountAsync(draft);
        Assert.Equal(MutationResultStatus.Unsupported, result.Status);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task CreateRemoteMount_InvalidDraft_ReturnsValidationFailure()
    {
        var api = new ScriptedApi(_ => throw new InvalidOperationException());
        var repository = MountRepository(api);

        var draft = new RemoteMountDraft(
            "", "", "",
            username: null, password: null, domain: null,
            readOnly: false, FileRemoteProtocol.Cifs);

        Assert.False(draft.IsValidForSubmission);
        var result = await repository.CreateRemoteMountAsync(draft);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Status);
        Assert.Equal(MutationErrorCategory.Validation, result.ErrorCategory);
    }

    [Fact]
    public async Task UpdateRemoteMount_ValidDraftDoesNotSendWhenWritesAreDisabled()
    {
        var api = new ScriptedApi(_ => throw new InvalidOperationException("must not send"));
        var repository = MountRepository(api);

        var draft = new RemoteMountDraft(
            "server.local", "/volume1/share", "/remote-mount",
            username: "user", password: "pass", domain: "DOMAIN",
            readOnly: true, FileRemoteProtocol.Cifs,
            existingMountPoint: "/remote-mount");

        var result = await repository.UpdateRemoteMountAsync(draft);

        Assert.Equal(MutationResultStatus.Unsupported, result.Status);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task DeleteRemoteMount_ValidMountPointDoesNotSendWhenWritesAreDisabled()
    {
        var api = new ScriptedApi(_ => throw new InvalidOperationException("must not send"));
        var repository = MountRepository(api);

        var result = await repository.DeleteRemoteMountAsync("/remote-mount");

        Assert.Equal(MutationResultStatus.Unsupported, result.Status);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task DeleteRemoteMount_InvalidMountPoint_ReturnsValidationFailure()
    {
        var api = new ScriptedApi(_ => throw new InvalidOperationException());
        var repository = MountRepository(api);

        var result = await repository.DeleteRemoteMountAsync("");

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Status);
        Assert.Equal(MutationErrorCategory.Validation, result.ErrorCategory);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task CreateRemoteMount_GenericTransportIsNeverUsedForServerErrorCase()
    {
        var api = new ScriptedApi(_ => throw new DsmException("server", "error", 500));
        var repository = MountRepository(api);

        var draft = ValidDraft();

        var result = await repository.CreateRemoteMountAsync(draft);

        Assert.Equal(MutationResultStatus.Unsupported, result.Status);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task CreateRemoteMount_GenericTransportIsNeverUsedForPermissionCase()
    {
        var api = new ScriptedApi(_ => throw new DsmException("permission", "denied", 105));
        var repository = MountRepository(api);

        var draft = ValidDraft();

        var result = await repository.CreateRemoteMountAsync(draft);

        Assert.Equal(MutationResultStatus.Unsupported, result.Status);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task CreateRemoteMount_GenericTransportIsNeverUsedForAuthenticationCase()
    {
        var api = new ScriptedApi(_ => throw new DsmException("auth", "login", 119));
        var repository = MountRepository(api);

        var draft = ValidDraft();

        var result = await repository.CreateRemoteMountAsync(draft);
        Assert.Equal(MutationResultStatus.Unsupported, result.Status);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task CreateRemoteMount_GenericTransportIsNeverUsedForNetworkCase()
    {
        var api = new ScriptedApi(_ => throw new IOException("network failure"));
        var repository = MountRepository(api);

        var draft = ValidDraft();

        var result = await repository.CreateRemoteMountAsync(draft);

        Assert.Equal(MutationResultStatus.Unsupported, result.Status);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task CreateRemoteMount_Cancellation_ReturnsCancelledBeforeSubmission()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var api = new ScriptedApi(_ => throw new InvalidOperationException());
        var repository = MountRepository(api);

        var draft = new RemoteMountDraft(
            "server.local", "/volume1/share", "/remote-mount",
            username: null, password: null, domain: null,
            readOnly: false, FileRemoteProtocol.Cifs);

        var result = await repository.CreateRemoteMountAsync(draft, cts.Token);

        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, result.Status);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task FavoriteWritesStayDisabledWithoutTypedSubmissionBoundary()
    {
        var api = new ScriptedApi(_ => throw new InvalidOperationException("must not send"));
        var capability = new ApiCapability(
            "SYNO.FileStation.Favorite", "entry.cgi", 2, 2, "FORM");
        IFileLocationsRepository repository = new DsmRepository(
            Profile,
            Session,
            api,
            new Dictionary<string, ApiCapability>
            {
                [capability.Name] = capability,
            });

        var add = await repository.AddFavoriteAsync("/share/favorite", "favorite");
        var remove = await repository.RemoveFavoriteAsync("/share/favorite");

        Assert.False(repository.CanWriteFavorites);
        Assert.Equal(MutationResultStatus.Unsupported, add.Status);
        Assert.Equal(MutationResultStatus.Unsupported, remove.Status);
        Assert.Empty(api.Requests);
    }

    private static RemoteMountDraft ValidDraft() => new(
        "server.local", "/volume1/share", "/remote-mount",
        username: null, password: null, domain: null,
        readOnly: false, FileRemoteProtocol.Cifs);

    [Fact]
    public void MountManagementIsNotInReadOnlyLocationsFile()
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
            if (File.Exists(candidate))
            {
                var source = File.ReadAllText(candidate);
                Assert.DoesNotContain("\"add\"", source, StringComparison.Ordinal);
                Assert.DoesNotContain("\"delete\"", source, StringComparison.Ordinal);
                Assert.DoesNotContain("\"create\"", source, StringComparison.Ordinal);
                Assert.DoesNotContain("SYNO.FileStation.Mount", source, StringComparison.Ordinal);
                return;
            }
            directory = directory.Parent;
        }
    }

    [Fact]
    public void RemoteMountEditAndDeleteVisibilityUsesActiveManagementGate()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var candidate = Path.Combine(
                directory.FullName,
                "src",
                "LanStash.App",
                "Views",
                "FileLocationsView.xaml");
            if (File.Exists(candidate))
            {
                var source = File.ReadAllText(candidate);
                Assert.Equal(2, source.Split("DataContext.AllowsRemoteMountManagement").Length - 1);
                return;
            }
            directory = directory.Parent;
        }

        Assert.Fail("The File Locations view source was not found.");
    }

    private static IFileLocationsRepository MountRepository(ScriptedApi api)
    {
        var mountCapability = new ApiCapability(
            "SYNO.FileStation.Mount", "entry.cgi", 1, 3, "FORM");
        var capabilities = new Dictionary<string, ApiCapability>
        {
            ["SYNO.FileStation.Mount"] = mountCapability,
        };
        return new DsmRepository(Profile, Session, api, capabilities);
    }

    private sealed record ApiRequest(
        string ApiName,
        string Method,
        IReadOnlyDictionary<string, string> Parameters);

    private sealed class ScriptedApi : IDsmApiClient
    {
        private readonly Func<ApiRequest, CancellationToken, Task<JsonObject>> _handler;

        public ScriptedApi(Func<ApiRequest, JsonObject> handler) :
            this((request, _) => Task.FromResult(handler(request))) { }

        public ScriptedApi(Func<ApiRequest, CancellationToken, Task<JsonObject>> handler) =>
            _handler = handler;

        public ConcurrentBag<ApiRequest> Requests { get; } = new();

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var request = new ApiRequest(
                capability.Name,
                method,
                new Dictionary<string, string>(parameters ?? new Dictionary<string, string>()));
            Requests.Add(request);
            return _handler(request, cancellationToken);
        }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid/");
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallReadJsonObjectAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
