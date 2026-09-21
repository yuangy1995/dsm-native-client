using LanStash.App.Features.Files;
using LanStash.App.Features.Files.CopyMove;
using LanStash.Domain;

namespace LanStash.Tests.Files.CopyMove;

public sealed class FileCopyMoveRecoveryViewModelTests
{
    private static readonly Guid Profile = Guid.Parse("77777777-7777-7777-7777-777777777777");
    private static readonly FileCopyMovePendingReview Pending = new(Guid.Parse("88888888-8888-8888-8888-888888888888"),
        Profile, FileCopyMoveOperation.Move, "/share/source/item.txt", "/share/target/item.txt", "item.txt", false, 7);

    [Fact]
    public async Task ExactConfirmationClearsOnlyMatchingBlockerWithoutAnyWrite()
    {
        var repository = new Repository(); var blocker = Blocker();
        using var model = new FileOperationRecoveryViewModel(repository, Profile, blocker);
        await model.RefreshAsync();
        Assert.True(model.CanReview);
        await model.ReviewSelectedAsync();
        Assert.Equal(1, model.ConfirmedCount);
        Assert.Equal("FileOperationReviewConfirmed", model.MessageKey);
        Assert.Empty(model.Items);
        Assert.Null(blocker.Find(Profile, Pending.Operation, Pending.SourcePath, "/share/target"));
        Assert.NotNull(blocker.Find(Profile, Pending.Operation, "/share/source/other.txt", "/share/target"));
        Assert.Equal(1, repository.Reviews);
        Assert.Equal(0, repository.Writes);
    }

    [Theory]
    [InlineData("pending")]
    [InlineData("missing")]
    [InlineData("wrong-path")]
    [InlineData("wrong-size")]
    [InlineData("authentication")]
    [InlineData("error")]
    public async Task UnconfirmedOrInvalidResultKeepsBlockerAndNeverRestarts(string state)
    {
        var repository = new Repository
        {
            Outcome = () => state switch
            {
                "missing" => null,
                "pending" => new(new(1, MutationResultStatus.SubmittedButUnverified, "moveFile", true, true, new(0, 0, 1))),
                "wrong-path" => Success() with { ConfirmedItem = Success().ConfirmedItem! with { Path = "/share/other/item.txt" } },
                "wrong-size" => Success() with { ConfirmedItem = Success().ConfirmedItem! with { Size = 8 } },
                "authentication" => throw new DsmException("synthetic", "synthetic", 119),
                _ => throw new IOException("synthetic"),
            },
        };
        var blocker = Blocker();
        using var model = new FileOperationRecoveryViewModel(repository, Profile, blocker);
        await model.RefreshAsync(); await model.ReviewSelectedAsync();
        Assert.Single(model.Items);
        Assert.NotNull(blocker.Find(Profile, Pending.Operation, Pending.SourcePath, "/share/target"));
        Assert.Equal(0, model.ConfirmedCount);
        Assert.Equal(0, repository.Writes);
        if (state == "authentication") Assert.Equal("FileOperationReviewSignIn", model.MessageKey);
    }

    [Fact]
    public async Task DisposedOrConcurrentReviewCannotApplyLateSuccess()
    {
        var completion = new TaskCompletionSource<FileCopyMoveOutcome?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new Repository { Wait = completion.Task }; var blocker = Blocker();
        using var model = new FileOperationRecoveryViewModel(repository, Profile, blocker);
        await model.RefreshAsync(); var review = model.ReviewSelectedAsync();
        await model.ReviewSelectedAsync(); await model.RefreshAsync();
        Assert.Equal(1, repository.Reviews);
        model.Dispose(); completion.SetResult(Success()); await review;
        Assert.True(repository.Token.IsCancellationRequested);
        Assert.Equal(0, model.ConfirmedCount);
        Assert.NotNull(blocker.Find(Profile, Pending.Operation, Pending.SourcePath, "/share/target"));
    }

    [Theory]
    [InlineData("profile")]
    [InlineData("duplicate")]
    [InlineData("path")]
    public async Task RejectsUntrustedPendingSnapshots(string state)
    {
        var repository = new Repository { Items = state switch
        {
            "profile" => [Pending with { ProfileId = Guid.NewGuid() }],
            "duplicate" => [Pending, Pending],
            _ => [Pending with { DestinationPath = "relative/item.txt" }],
        } };
        using var model = new FileOperationRecoveryViewModel(repository, Profile, Blocker());
        await model.RefreshAsync(); await model.ReviewSelectedAsync();
        Assert.False(model.CanReview);
        Assert.Equal("FileOperationReviewFailed", model.MessageKey);
        Assert.Equal(0, repository.Reviews);
    }

    [Fact]
    public async Task EmptyListAndForeignSelectionDoNotTriggerRequests()
    {
        var repository = new Repository { Items = [] };
        using var model = new FileOperationRecoveryViewModel(repository, Profile, Blocker());
        await model.RefreshAsync(); model.Selected = new FileOperationReviewEntry(Pending.Id, Profile, "moveFile", Pending.SourcePath, Pending.DestinationPath, Pending.Name, false, 7); await model.ReviewSelectedAsync();
        Assert.Equal("FileOperationReviewEmpty", model.MessageKey);
        Assert.Null(model.Selected);
        Assert.Equal(0, repository.Reviews);
    }

    private static FileCopyMoveReviewBlocker Blocker()
    {
        var blocker = new FileCopyMoveReviewBlocker();
        blocker.Block(new(Profile, Pending.Operation, Pending.SourcePath, "/share/target"));
        blocker.Block(new(Profile, Pending.Operation, "/share/source/other.txt", "/share/target"));
        return blocker;
    }
    private static FileCopyMoveOutcome Success() => new(new(1, MutationResultStatus.ConfirmedSuccess, "moveFile", true, false, new(1, 0, 0)),
        new(Pending.DestinationPath, Pending.Name, false, Pending.Size, DateTimeOffset.UnixEpoch, null, true, true));
    private sealed class Repository : IFileCopyMoveRepository
    {
        public Guid ProfileId => Profile;
        public FileCopyMoveAvailability Availability => new(true, true, 3);
        public CrossNasCopyMoveAvailability CrossNasAvailability => new(false, false);
        public bool SupportsCopyMoveReview => true;
        public IReadOnlyList<FileCopyMovePendingReview> Items = [Pending];
        public Func<FileCopyMoveOutcome?> Outcome = Success;
        public Task<FileCopyMoveOutcome?>? Wait;
        public int Reviews, Writes;
        public CancellationToken Token;
        public Task<IReadOnlyList<FileCopyMovePendingReview>> GetCopyMoveReviewsAsync(CancellationToken cancellationToken = default) => Task.FromResult(Items);
        public Task<FileCopyMoveOutcome?> ReviewCopyMoveAsync(Guid id, CancellationToken cancellationToken = default)
        { Assert.Equal(Pending.Id, id); Reviews++; Token = cancellationToken; return Wait ?? Task.FromResult(Outcome()); }
        public Task<FileCopyMoveOutcome> CopyMoveAsync(FileCopyMoveRequest request, CancellationToken cancellationToken = default)
        { Writes++; throw new InvalidOperationException("核对不得启动写入。"); }
        public Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(CrossNasCopyMoveRequest request, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
        { Writes++; throw new InvalidOperationException("核对不得跨 NAS 写入。"); }
    }
}
