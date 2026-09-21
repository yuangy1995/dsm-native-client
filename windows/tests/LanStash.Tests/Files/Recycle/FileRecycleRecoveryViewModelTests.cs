using LanStash.App.Features.Files;
using LanStash.App.Features.Files.Recycle;
using LanStash.Domain;

namespace LanStash.Tests.Files.Recycle;

public sealed class FileRecycleRecoveryViewModelTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ExactRecycleResultClearsOnlyItsOwnBlocker(bool restore)
    {
        var repository = new Repository(restore); var blocker = Blocker(repository);
        using var model = new FileOperationRecoveryViewModel(repository, repository.ProfileId, blocker);
        await model.RefreshAsync(); await model.ReviewSelectedAsync();
        Assert.Equal(1, model.ConfirmedCount); Assert.Equal(1, repository.Acknowledgements);
        Assert.Empty(model.Items); Assert.Null(Find(blocker, repository));
        Assert.Equal(0, repository.Writes);
    }

    [Theory]
    [InlineData(false, "source")]
    [InlineData(true, "source")]
    [InlineData(false, "destination")]
    [InlineData(true, "destination")]
    [InlineData(false, "time")]
    [InlineData(true, "time")]
    [InlineData(false, "pending")]
    [InlineData(true, "pending")]
    [InlineData(false, "missing")]
    [InlineData(true, "missing")]
    [InlineData(false, "auth")]
    [InlineData(true, "auth")]
    public async Task UnconfirmedOrMismatchedEvidenceNeverClearsBlocker(bool restore, string state)
    {
        var repository = new Repository(restore) { State = state }; var blocker = Blocker(repository);
        using var model = new FileOperationRecoveryViewModel(repository, repository.ProfileId, blocker);
        await model.RefreshAsync(); await model.ReviewSelectedAsync();
        Assert.Equal(0, model.ConfirmedCount); Assert.Equal(0, repository.Acknowledgements);
        Assert.Single(model.Items); Assert.NotNull(Find(blocker, repository)); Assert.Equal(0, repository.Writes);
        if (state == "auth") Assert.Equal("FileOperationReviewSignIn", model.MessageKey);
    }

    [Fact]
    public async Task ClosedWindowDoesNotAcknowledgeLateSuccess()
    {
        var repository = new Repository(false) { Hold = new(TaskCreationOptions.RunContinuationsAsynchronously) }; var blocker = Blocker(repository);
        using var model = new FileOperationRecoveryViewModel(repository, repository.ProfileId, blocker);
        await model.RefreshAsync(); var review = model.ReviewSelectedAsync(); await model.ReviewSelectedAsync();
        model.Dispose(); repository.Hold.SetResult(repository.Success()); await review;
        Assert.Equal(1, repository.Reviews); Assert.Equal(0, repository.Acknowledgements);
        Assert.True(repository.Token.IsCancellationRequested); Assert.NotNull(Find(blocker, repository));
    }

    private static FileRecycleReviewBlocker Blocker(Repository repository)
    {
        var blocker = new FileRecycleReviewBlocker();
        blocker.Block(new(repository.ProfileId, repository.Operation, repository.Pending.SourcePath, repository.Pending.DestinationPath));
        return blocker;
    }
    private static FileRecycleReview? Find(FileRecycleReviewBlocker blocker, Repository repository) =>
        blocker.Find(repository.ProfileId, repository.Operation, repository.Pending.SourcePath, repository.Pending.DestinationPath);

    private sealed class Repository(bool restore) : IFileRecycleRepository
    {
        public Guid ProfileId => Guid.Parse("77777777-7777-7777-7777-777777777777");
        public FileRecycleAvailability Availability => new(true, true, 2, 3);
        public bool SupportsRecycleReview => true;
        public FileRecycleOperation Operation => restore ? FileRecycleOperation.Restore : FileRecycleOperation.MoveToRecycle;
        public FileRecyclePendingReview Pending => new(Guid.Parse("88888888-8888-8888-8888-888888888888"), ProfileId, restore,
            restore ? "/share/#recycle/item.txt" : "/share/item.txt", restore ? "/share/item.txt" : "/share/#recycle/item.txt",
            "item.txt", false, 7, DateTimeOffset.UnixEpoch);
        public string State = "success";
        public int Reviews, Acknowledgements, Writes;
        public TaskCompletionSource<FileRecycleOutcome?>? Hold;
        public CancellationToken Token;
        public Task<IReadOnlyList<FileRecyclePendingReview>> GetRecycleReviewsAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<FileRecyclePendingReview>>([Pending]);
        public Task<FileRecycleOutcome?> ReviewRecycleAsync(Guid id, CancellationToken token = default)
        {
            Assert.Equal(Pending.Id, id); Reviews++; Token = token;
            if (Hold is not null) return Hold.Task;
            var success = Success();
            return Task.FromResult(State switch
            {
                "source" => success with { SourcePath = "/share/other.txt" },
                "destination" => success with { DestinationPath = "/share/other.txt" },
                "time" => success with { ConfirmedItem = success.ConfirmedItem! with { ModifiedAt = DateTimeOffset.UnixEpoch.AddSeconds(1) } },
                "pending" => success with { Result = new(1, MutationResultStatus.SubmittedButUnverified, restore ? "restoreFromRecycle" : "moveToRecycle", true, true, new(0, 0, 1)), ConfirmedItem = null },
                "missing" => null,
                "auth" => throw new DsmException("synthetic", "synthetic", 119),
                _ => success,
            });
        }
        public void AcknowledgeRecycleReview(Guid id) { Assert.Equal(Pending.Id, id); Acknowledgements++; }
        public FileRecycleOutcome Success() => new(new(1, MutationResultStatus.ConfirmedSuccess, restore ? "restoreFromRecycle" : "moveToRecycle", true, false, new(1, 0, 0)),
            Pending.SourcePath, Pending.DestinationPath, new(Pending.DestinationPath, Pending.Name, false, 7, DateTimeOffset.UnixEpoch, null, true, true));
        public Task<FileRecycleOutcome> MoveToRecycleAsync(MoveToRecycleRequest request, CancellationToken token = default)
        { Writes++; throw new InvalidOperationException("核对不得移入回收站。"); }
        public Task<FileRecycleOutcome> RestoreFromRecycleAsync(RestoreFromRecycleRequest request, CancellationToken token = default)
        { Writes++; throw new InvalidOperationException("核对不得恢复文件。"); }
    }
}
