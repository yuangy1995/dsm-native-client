using LanStash.App.Features.Files.CopyMove;
using LanStash.Domain;

namespace LanStash.Tests.Files.CopyMove;

public sealed class CrossNasCopyMoveViewModelTests
{
    private static readonly Guid SourceProfileId = Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
    private static readonly Guid TargetProfileId = Guid.Parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
    private static readonly FileItem Source = new(
        "/share/source.txt",
        "source.txt",
        IsDirectory: false,
        Size: 42,
        ModifiedAt: DateTimeOffset.UnixEpoch,
        Owner: null,
        CanWrite: true,
        CanDelete: true);
    private static readonly NasProfile TargetProfile = new(
        TargetProfileId,
        "Backup NAS",
        "backup.example.invalid",
        null,
        "tester");

    [Fact]
    public async Task TargetRestoreFailureStopsBeforeSubmit()
    {
        var repository = new StubRepository(SourceProfileId);
        using var model = new CrossNasCopyMoveViewModel(
            repository,
            SourceProfileId,
            Source,
            FileCopyMoveOperation.Copy,
            [TargetProfile],
            (_, _) => Task.FromResult<IFileCopyMoveFolderSource?>(null));

        await model.SelectTargetAndLoadAsync(TargetProfile);
        await model.SubmitAsync();

        Assert.Equal(CrossNasCopyMoveState.TargetUnavailable, model.State);
        Assert.Empty(repository.Requests);
    }

    [Fact]
    public async Task CopyUsesSelectedTargetProfileAndExactDestination()
    {
        var repository = new StubRepository(SourceProfileId);
        using var model = new CrossNasCopyMoveViewModel(
            repository,
            SourceProfileId,
            Source,
            FileCopyMoveOperation.Copy,
            [TargetProfile],
            (_, _) => Task.FromResult<IFileCopyMoveFolderSource?>(
                new StubFolders(TargetProfileId, [new("/backup", "backup", true)])));

        await model.SelectTargetAndLoadAsync(TargetProfile);
        await model.LoadFoldersAsync("/backup", destinationCanWrite: true);
        await model.SubmitAsync();

        var request = Assert.Single(repository.Requests);
        Assert.Equal(CrossNasCopyMoveState.Completed, model.State);
        Assert.Equal(SourceProfileId, request.SourceProfileId);
        Assert.Equal(TargetProfileId, request.TargetProfileId);
        Assert.Equal("/share/source.txt", request.SourcePath);
        Assert.Equal("/backup", request.DestinationFolderPath);
        Assert.False(request.Overwrite);
        Assert.Equal(CrossNasCopyMoveOperation.Copy, request.Operation);
    }

    [Fact]
    public async Task TargetCapabilityLossIsReportedAsTargetUnavailable()
    {
        var repository = new StubRepository(
            SourceProfileId,
            MutationResultStatus.Unsupported,
            diagnosticTag: "file.cross-nas.target-no-capability");
        using var model = new CrossNasCopyMoveViewModel(
            repository,
            SourceProfileId,
            Source,
            FileCopyMoveOperation.Copy,
            [TargetProfile],
            (_, _) => Task.FromResult<IFileCopyMoveFolderSource?>(
                new StubFolders(TargetProfileId, [new("/backup", "backup", true)])));

        await model.SelectTargetAndLoadAsync(TargetProfile);
        await model.LoadFoldersAsync("/backup", destinationCanWrite: true);
        await model.SubmitAsync();

        Assert.Equal(CrossNasCopyMoveState.TargetUnavailable, model.State);
        Assert.Equal("file.cross-nas.target-no-capability", model.ResultMessage);
    }

    [Fact]
    public async Task UnsupportedSourceRepositoryIsReportedWithoutTechnicalMessage()
    {
        var repository = new StubRepository(
            SourceProfileId,
            MutationResultStatus.Unsupported,
            diagnosticTag: "file.cross-nas.source-no-capability");
        using var model = new CrossNasCopyMoveViewModel(
            repository,
            SourceProfileId,
            Source,
            FileCopyMoveOperation.Copy,
            [TargetProfile],
            (_, _) => Task.FromResult<IFileCopyMoveFolderSource?>(
                new StubFolders(TargetProfileId, [new("/backup", "backup", true)])));

        await model.SelectTargetAndLoadAsync(TargetProfile);
        await model.LoadFoldersAsync("/backup", destinationCanWrite: true);
        await model.SubmitAsync();

        Assert.Equal(CrossNasCopyMoveState.Unsupported, model.State);
        Assert.Null(model.ResultMessage);
    }

    private sealed class StubFolders(
        Guid profileId,
        IReadOnlyList<FileCopyMoveFolder> folders) : IFileCopyMoveFolderSource
    {
        public Guid ProfileId { get; } = profileId;

        public Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(
            string path,
            CancellationToken cancellationToken) =>
            Task.FromResult(folders);

        public bool IsReadOnlyPath(string path) => false;
    }

    private sealed class StubRepository(
        Guid profileId,
        MutationResultStatus status = MutationResultStatus.ConfirmedSuccess,
        string? diagnosticTag = null) : IFileCopyMoveRepository
    {
        public Guid ProfileId { get; } = profileId;
        public FileCopyMoveAvailability Availability { get; } = new(true, true, 3);
        public CrossNasCopyMoveAvailability CrossNasAvailability { get; } = new(true, false);
        public List<CrossNasCopyMoveRequest> Requests { get; } = [];

        public Task<FileCopyMoveOutcome> CopyMoveAsync(
            FileCopyMoveRequest request,
            CancellationToken cancellationToken = default) =>
            Task.FromException<FileCopyMoveOutcome>(new NotSupportedException());

        public Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(
            CrossNasCopyMoveRequest request,
            IProgress<long>? progress = null,
            CancellationToken cancellationToken = default)
        {
            Requests.Add(request);
            return Task.FromResult(new CrossNasCopyMoveOutcome(
                new MutationResult(
                    1,
                    status,
                    "crossNasCopy",
                    submitted: status != MutationResultStatus.Unsupported,
                    requiresRefresh: false,
                    new MutationResultCounts(
                        status == MutationResultStatus.ConfirmedSuccess ? 1 : 0,
                        status == MutationResultStatus.ConfirmedSuccess ? 0 : 1,
                        0),
                    status == MutationResultStatus.ConfirmedSuccess
                        ? null
                        : MutationErrorCategory.Unsupported,
                    diagnosticTag: diagnosticTag),
                request.SourcePath,
                $"{request.DestinationFolderPath}/{request.SourceName}",
                status == MutationResultStatus.ConfirmedSuccess
                    ? new FileItem(
                        $"{request.DestinationFolderPath}/{request.SourceName}",
                        request.SourceName,
                        request.IsDirectory,
                        request.FileSize,
                        DateTimeOffset.UnixEpoch,
                        null,
                        true,
                        true)
                    : null));
        }
    }
}
