using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveRelocationCoordinatorTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-rename-flow-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic", DesktopDriveScope.Folder("/share"),
        DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private DesktopCloudDriveSyncStore Store => new(_root);
    private CloudDriveRelocationCoordinator Coordinator(Repository repository) => new(_mapping, repository, Store);

    [Fact]
    public async Task RenameOnlyUsesRenameAndVerifiesBothPaths()
    {
        var repository = await ReadyAsync();
        var result = await Coordinator(repository).StartAsync("synthetic-id", "/share/a", "/share/b", "b", true);
        Assert.Equal(CloudDriveRelocationPhase.ServerVerified, result.Phase); Assert.Equal(1, result.Step);
        Assert.Equal(["rename:/share/a:/share/b"], repository.Calls);
        Assert.False(repository.Items.ContainsKey("/share/a")); Assert.True(repository.Items.ContainsKey("/share/b"));
        await Coordinator(repository).ContinueAsync(result, true);
        Assert.Single(repository.Calls);
    }

    [Fact]
    public async Task AllSharesCanMoveAndRenameInsideAnotherShare()
    {
        var mapping = _mapping with { Scope = DesktopDriveScope.AllShares }; var repository = new Repository(mapping.ProfileId);
        repository.Items["/other"] = (true, 0);
        await Store.SetWritebackEnabledAsync(mapping, true, true);
        var result = await new CloudDriveRelocationCoordinator(mapping, repository, Store)
            .StartAsync("synthetic-id", "/share/a", "/other/b", "b", true);
        Assert.Equal(CloudDriveRelocationPhase.ServerVerified, result.Phase);
        Assert.Equal(["move:/share/a:/other/a", "rename:/other/a:/other/b"], repository.Calls);
    }

    [Theory]
    [InlineData("/share", "/other/share")]
    [InlineData("/share/a", "/new-share")]
    public async Task AllSharesCannotRenameOrMoveShareRoots(string source, string destination)
    {
        var mapping = _mapping with { Scope = DesktopDriveScope.AllShares }; var repository = new Repository(mapping.ProfileId);
        await Store.SetWritebackEnabledAsync(mapping, true, true);
        await Assert.ThrowsAsync<InvalidDataException>(() => new CloudDriveRelocationCoordinator(mapping, repository, Store)
            .StartAsync("synthetic-id", source, destination, "target", true));
        Assert.Empty(repository.Calls); Assert.Empty(await Store.ReadRelocationOperationsAsync(mapping));
    }

    [Fact]
    public async Task MoveAndRenameUseExactTwoStepPlanWithoutOverwrite()
    {
        var repository = await ReadyAsync();
        var result = await Coordinator(repository).StartAsync("synthetic-id", "/share/a", "/share/dest/b", "b", true);
        Assert.Equal(CloudDriveRelocationPhase.ServerVerified, result.Phase); Assert.Equal(2, result.Step);
        Assert.Equal(["move:/share/a:/share/dest/a", "rename:/share/dest/a:/share/dest/b"], repository.Calls);
    }

    [Fact]
    public async Task UnknownMoveIsReadOnlyOnReviewAndContinuesOnlyAfterNewConfirmation()
    {
        var repository = await ReadyAsync(); repository.UnknownCall = 1;
        var first = await Coordinator(repository).StartAsync("synthetic-id", "/share/a", "/share/dest/b", "b", true);
        Assert.Equal(CloudDriveRelocationPhase.Submitted, first.Phase); Assert.Equal(0, first.Step);
        var unconfirmed = await Coordinator(repository).ReviewAsync(first.Id, false);
        Assert.Equal(CloudDriveRelocationPhase.Submitted, unconfirmed.Phase);
        var reviewed = await Coordinator(repository).ReviewAsync(first.Id, true);
        Assert.Equal(CloudDriveRelocationPhase.ReadyForNextStep, reviewed.Phase); Assert.Equal(1, reviewed.Step);
        Assert.Single(repository.Calls);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).ContinueAsync(reviewed, false));
        var completed = await Coordinator(repository).ContinueAsync(reviewed, true);
        Assert.Equal(CloudDriveRelocationPhase.ServerVerified, completed.Phase);
        Assert.Equal(["move:/share/a:/share/dest/a", "rename:/share/dest/a:/share/dest/b"], repository.Calls);
    }

    [Fact]
    public async Task UnknownRenameAfterMoveDoesNotRepeatTheMove()
    {
        var repository = await ReadyAsync(); repository.UnknownCall = 2;
        var result = await Coordinator(repository).StartAsync("synthetic-id", "/share/a", "/share/dest/b", "b", true);
        Assert.Equal(CloudDriveRelocationPhase.Submitted, result.Phase); Assert.Equal(1, result.Step);
        await Coordinator(repository).ContinueAsync(result, true);
        var verified = await Coordinator(repository).ReviewAsync(result.Id, true);
        Assert.Equal(CloudDriveRelocationPhase.ServerVerified, verified.Phase); Assert.Equal(2, repository.Calls.Count);
    }

    [Fact]
    public async Task RejectedSecondStepKeepsIntermediatePathAndCannotBeAbandoned()
    {
        var repository = await ReadyAsync(); repository.RejectCall = 2;
        var result = await Coordinator(repository).StartAsync("synthetic-id", "/share/a", "/share/dest/b", "b", true);
        Assert.Equal(CloudDriveRelocationPhase.Rejected, result.Phase); Assert.Equal(1, result.Step);
        Assert.True(repository.Items.ContainsKey("/share/dest/a"));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).AbandonAsync(result, true));
        var completed = await Coordinator(repository).ContinueAsync(result, true);
        Assert.Equal(CloudDriveRelocationPhase.ServerVerified, completed.Phase);
        Assert.Equal(1, repository.Calls.Count(call => call.StartsWith("move:", StringComparison.Ordinal)));
        Assert.Equal(2, repository.Calls.Count(call => call.StartsWith("rename:", StringComparison.Ordinal)));
    }

    [Theory]
    [InlineData("/share/b")]
    [InlineData("/share/dest/a")]
    public async Task DestinationOrIntermediateCollisionSendsNothing(string collision)
    {
        var repository = await ReadyAsync(); repository.Items[collision] = (false, 3);
        var destination = collision == "/share/b" ? "/share/b" : "/share/dest/b";
        await Assert.ThrowsAsync<InvalidDataException>(() => Coordinator(repository).StartAsync("synthetic-id", "/share/a", destination, "b", true));
        Assert.Empty(repository.Calls); Assert.Empty(await Store.ReadRelocationOperationsAsync(_mapping));
    }

    [Fact]
    public async Task DifferentItemAtDestinationCannotSatisfyUnknownReadback()
    {
        var repository = await ReadyAsync(); repository.UnknownCall = 1;
        var result = await Coordinator(repository).StartAsync("synthetic-id", "/share/a", "/share/b", "b", true);
        repository.Items["/share/b"] = (false, 99);
        Assert.Equal(CloudDriveRelocationPhase.Submitted, (await Coordinator(repository).ReviewAsync(result.Id, true)).Phase);
        Assert.Single(repository.Calls);
    }

    [Fact]
    public async Task PendingRelocationReservesIntermediateAndPreventsDisablingWrites()
    {
        var repository = await ReadyAsync(); repository.UnknownCall = 1;
        await Coordinator(repository).StartAsync("synthetic-id", "/share/a", "/share/dest/b", "b", true);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.RequireNoRelocationAsync(_mapping, "/share/dest/a"));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.SetWritebackEnabledAsync(_mapping, false, true));
        await Store.RequireNoRelocationAsync(_mapping, "/share/unrelated");
    }

    [Fact]
    public async Task ExplicitRejectionBeforeAnyMoveCanBeAbandonedWithoutNasRequest()
    {
        var repository = await ReadyAsync(); repository.RejectCall = 1;
        var rejected = await Coordinator(repository).StartAsync("synthetic-id", "/share/a", "/share/b", "b", true);
        await Coordinator(repository).AbandonAsync(rejected, true);
        Assert.Equal(CloudDriveRelocationPhase.Abandoned, Assert.Single(await Store.ReadRelocationOperationsAsync(_mapping)).Phase);
        Assert.Single(repository.Calls); await Store.RequireNoRelocationAsync(_mapping, "/share/a");
    }

    private async Task<Repository> ReadyAsync()
    {
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/a", "/share/dest"]);
        return new Repository(_mapping.ProfileId);
    }

    private sealed class Repository(Guid profileId) : IDsmRepository, IFilePreviewRepository, IFileMutationRepository, IFileCopyMoveRepository
    {
        public Guid ProfileId => profileId;
        public IReadOnlyList<AppModule> AvailableModules => [AppModule.Files];
        public FileMutationAvailability FileMutationAvailability => new(true, true, 2, 2);
        public FileCopyMoveAvailability Availability => new(true, true, 3);
        public CrossNasCopyMoveAvailability CrossNasAvailability => throw new NotSupportedException();
        internal readonly Dictionary<string, (bool Directory, long Size)> Items = new(StringComparer.Ordinal)
            { ["/share"] = (true, 0), ["/share/dest"] = (true, 0), ["/share/a"] = (false, 3) };
        internal readonly List<string> Calls = [];
        internal int UnknownCall, RejectCall;
        private FileItem Item(string path) => new(path, path[(path.LastIndexOf('/') + 1)..], Items[path].Directory, Items[path].Size,
            DateTimeOffset.UnixEpoch, null, true, true);
        public Task<FileEntryMetadata?> ReadFileMetadataAsync(string path, CancellationToken token = default) =>
            Task.FromResult<FileEntryMetadata?>(Items.ContainsKey(path) ? new(Item(path), Items[path].Directory ? "dir" : "file", path == "/share" ? "shared_folder" : "normal") : null);
        private MutationResult Mutate(string source, string destination, bool move)
        {
            Calls.Add((move ? "move:" : "rename:") + source + ":" + destination);
            var reject = Calls.Count == RejectCall; var unknown = Calls.Count == UnknownCall;
            if (!reject)
            {
                foreach (var item in Items.Where(item => DesktopDrivePath.IsAncestorOrSame(source, item.Key)).ToArray())
                { Items.Remove(item.Key); Items.Add(destination + item.Key[source.Length..], item.Value); }
            }
            return new(1, reject ? MutationResultStatus.PermissionDenied : unknown ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess,
                move ? "move" : "rename", !reject, unknown, new(reject || unknown ? 0 : 1, reject ? 1 : 0, unknown ? 1 : 0));
        }
        public Task<FileMutationOutcome> RenameAsync(RenameFileItemRequest request, CancellationToken token = default)
        {
            Assert.Equal(ProfileId, request.Target.ProfileId);
            var destination = request.Target.Path[..request.Target.Path.LastIndexOf('/')] + "/" + request.NewName;
            return Task.FromResult(new FileMutationOutcome(Mutate(request.Target.Path, destination, false)));
        }
        public Task<FileCopyMoveOutcome> CopyMoveAsync(FileCopyMoveRequest request, CancellationToken token = default)
        {
            Assert.Equal(ProfileId, request.Target.ProfileId); Assert.Equal(FileCopyMoveOperation.Move, request.Operation);
            Assert.Equal(FileCopyMoveConflictPolicy.Fail, request.ConflictPolicy);
            return Task.FromResult(new FileCopyMoveOutcome(Mutate(request.Target.Path, request.DestinationDirectoryPath + "/" + request.Target.Name, true)));
        }
        public Task<FileMutationOutcome> CreateFolderAsync(CreateFolderRequest request, CancellationToken token = default) => throw new NotSupportedException();
        public Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(CrossNasCopyMoveRequest request, IProgress<long>? progress = null, CancellationToken token = default) => throw new NotSupportedException();
        public Task<FilePage> ListFilesAsync(string path, CancellationToken token = default) => throw new NotSupportedException();
        public Task<FilePage> ListFilesAsync(string path, int offset, int limit, CancellationToken token = default) => throw new NotSupportedException();
        public Task<FilePage> ListFilesAsync(string path, int offset, int limit, FileListOptions options, CancellationToken token = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(string path, long offset, long length, CancellationToken token = default) => throw new NotSupportedException();
        public Task<FileRangeReadResult> ReadFileRangeResultAsync(string path, long offset, long length,
            string? expectedContentVersion = null, long? expectedTotalLength = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<IReadOnlyList<FileItem>> SearchFilesAsync(string path, string query, CancellationToken token = default) => throw new NotSupportedException();
        public Task CreateFolderAsync(string path, string name, CancellationToken token = default) => throw new NotSupportedException();
        public Task RenameAsync(string path, string name, CancellationToken token = default) => throw new NotSupportedException();
        public Task DeleteFilesAsync(IReadOnlyList<string> paths, CancellationToken token = default) => throw new NotSupportedException();
        public Task<NasSettingsSnapshot> LoadNasSettingsAsync(CancellationToken token = default) => throw new NotSupportedException();
        public FileMD5Availability MD5Availability => new(false);
        public FileTextEditAvailability GetTextEditAvailability() => throw new NotSupportedException();
        public Task<string> CalculateMD5Async(string path, CancellationToken token = default) => throw new NotSupportedException();
        public Task<string> FormatTextContentAsync(string text, TextFormatKind kind, CancellationToken token = default) => throw new NotSupportedException();
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
