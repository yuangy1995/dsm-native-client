using LanStash.App.Features.Downloads;
using LanStash.App.Features.Files.CopyMove;
using LanStash.Domain;

namespace LanStash.Tests.Downloads;

public sealed class DownloadSettingsViewModelTests
{
    private static DownloadStationSettingsSummary Value() => new("downloads", false, false, 500, 100, 200, 200, 300, 0, 0, false, false);
    private static DownloadSettingsSaveOutcome Outcome(DownloadSettingsComponentState basic, DownloadSettingsComponentState schedule)
    {
        var unknown = basic == DownloadSettingsComponentState.Unknown;
        return new(new(1, unknown ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.PartialSuccess, "downloadSettings", true, unknown,
            unknown ? new(0, 1, 1) : new(1, 1, 0)), null, basic, schedule);
    }

    [Fact]
    public async Task UnknownSaveFreezesDraftAndReviewCannotContinueWithoutExplicitAction()
    {
        var repository = new Repository();
        repository.Results.Enqueue(Outcome(DownloadSettingsComponentState.Unknown, DownloadSettingsComponentState.NotStarted));
        repository.Results.Enqueue(Outcome(DownloadSettingsComponentState.Confirmed, DownloadSettingsComponentState.NotStarted));
        using var model = new DownloadSettingsViewModel(repository); await model.LoadAsync();
        model.SetDraft(model.Draft! with { BtDownloadLimitKb = 650, IsScheduleEnabled = true });
        await model.SaveAsync(); Assert.True(model.RequiresReview);
        model.SetDraft(model.Draft! with { BtDownloadLimitKb = 900 }); await model.LoadAsync(); await model.SaveAsync();
        Assert.Single(repository.Requests); Assert.Equal(650, model.Draft!.BtDownloadLimitKb);
        await model.ReviewAsync(); Assert.True(model.CanContinue); Assert.False(model.RequiresReview);
        await model.ReviewAsync(); Assert.Equal(2, repository.Requests.Count);
        await model.ContinueAsync(); Assert.False(model.HasPending);
        Assert.True(repository.Requests[2].ContinueRemaining);
        Assert.Single(repository.Requests.Select(item => item.ClientRequestId).Distinct());
        Assert.All(repository.Requests, item => Assert.Equal(650, item.Desired.BtDownloadLimitKb));
    }

    [Fact]
    public async Task UiUsesOneWebFtpValueAndUnavailableScheduleCannotBeChanged()
    {
        var repository = new Repository { ScheduleStatus = DownloadStationSectionStatus.Unavailable };
        using var model = new DownloadSettingsViewModel(repository); await model.LoadAsync();
        model.SetDraft(model.Draft! with { HttpDownloadLimitKb = 321, FtpDownloadLimitKb = 123, IsScheduleEnabled = true });
        Assert.Equal(321, model.Draft!.FtpDownloadLimitKb); Assert.Null(model.Draft.IsScheduleEnabled);
        Assert.True(model.CanSave);
        model.SetDraft(model.Draft with { BtDownloadLimitKb = -1 }); Assert.False(model.CanSave);
        await model.SaveAsync(); Assert.Empty(repository.Requests);
    }

    [Fact]
    public async Task ForeignSnapshotAndForeignConfirmedResultCannotReplaceCurrentSettings()
    {
        var repository = new Repository();
        using var model = new DownloadSettingsViewModel(repository); await model.LoadAsync();
        model.SetDraft(model.Draft! with { BtDownloadLimitKb = 600 });
        repository.Results.Enqueue(new(new(1, MutationResultStatus.ConfirmedSuccess, "downloadSettings", true, false, new(1, 0, 0)),
            new(Guid.NewGuid(), model.Draft, true, DownloadStationSectionStatus.Available), DownloadSettingsComponentState.Confirmed, DownloadSettingsComponentState.Unchanged));
        await model.SaveAsync(); Assert.True(model.RequiresReview); Assert.Equal(repository.ProfileId, model.Snapshot!.ProfileId);
        var foreign = new Repository { ForeignLoad = true }; using var other = new DownloadSettingsViewModel(foreign);
        await other.LoadAsync(); Assert.Null(other.Snapshot); Assert.Equal("DownloadSettingsLoadFailed", other.ErrorKey);
    }

    [Fact]
    public async Task FailedRefreshDoesNotPermitSavingFromAHiddenStaleEditor()
    {
        var repository = new Repository(); using var model = new DownloadSettingsViewModel(repository);
        await model.LoadAsync(); model.SetDraft(model.Draft! with { BtDownloadLimitKb = 600 }); Assert.True(model.CanSave);
        repository.LoadOverride = () => Task.FromException<DownloadSettingsSnapshot>(new IOException("synthetic"));
        await model.LoadAsync(); Assert.False(model.CanSave);
        await model.SaveAsync(); Assert.Empty(repository.Requests);
    }

    [Fact]
    public async Task LateLoadAfterCancellationCannotOverwriteFreshSettings()
    {
        var repository = new Repository(); var delayed = new TaskCompletionSource<DownloadSettingsSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.LoadOverride = () => delayed.Task;
        using var model = new DownloadSettingsViewModel(repository);
        var first = model.LoadAsync(); model.CancelLoad(); repository.LoadOverride = null;
        await model.LoadAsync(); delayed.SetResult(new(repository.ProfileId, Value() with { BtDownloadLimitKb = 999 }, true, DownloadStationSectionStatus.Available));
        await first; Assert.Equal(500, model.Draft!.BtDownloadLimitKb);
    }

    [Fact]
    public async Task FolderSelectionRequiresCurrentWritableFolderAndDoesNotSaveAnything()
    {
        var repository = new Repository(); var folders = new Folders(repository.ProfileId);
        using var model = new DownloadSettingsViewModel(repository, folders); await model.LoadAsync();
        await model.BrowseFoldersAsync("");
        model.ChooseFolder(model.Folders[0]); Assert.Equal("downloads", model.Draft!.DefaultDestination);
        model.ChooseFolder(new("/foreign", "Foreign", true)); Assert.Equal("downloads", model.Draft.DefaultDestination);
        model.ChooseFolder(model.Folders[1]); Assert.Equal("writable", model.Draft.DefaultDestination);
        Assert.False(model.IsBrowsingFolders); Assert.Empty(repository.Requests);
    }

    private sealed class Folders(Guid profileId) : IFileCopyMoveFolderSource
    {
        public Guid ProfileId => profileId;
        public bool IsReadOnlyPath(string path) => false;
        public Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(string path, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<FileCopyMoveFolder>>([new("/read-only", "Read only", false), new("/writable", "Writable", true)]);
    }
    private sealed class Repository : IDownloadStationRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public DownloadStationAvailability Availability => new(DownloadStationAvailabilityStatus.Available, new HashSet<DownloadStationReadFeature> { DownloadStationReadFeature.ServerSettings });
        public DownloadStationSectionStatus ScheduleStatus { get; init; } = DownloadStationSectionStatus.Available;
        public bool ForeignLoad { get; init; }
        public Func<Task<DownloadSettingsSnapshot>>? LoadOverride { get; set; }
        public Queue<DownloadSettingsSaveOutcome> Results { get; } = [];
        public List<DownloadSettingsSaveRequest> Requests { get; } = [];
        public Task<DownloadSettingsSnapshot> LoadSettingsAsync(CancellationToken cancellationToken = default) => LoadOverride?.Invoke() ??
            Task.FromResult(new DownloadSettingsSnapshot(ForeignLoad ? Guid.NewGuid() : ProfileId, ScheduleStatus == DownloadStationSectionStatus.Available ? Value() : Value() with { IsScheduleEnabled = null, IsEmuleScheduleEnabled = null }, true, ScheduleStatus));
        public Task<DownloadSettingsSaveOutcome> SaveSettingsAsync(DownloadSettingsSaveRequest request, CancellationToken cancellationToken = default)
        {
            Requests.Add(request); return Task.FromResult(Results.TryDequeue(out var result) ? result :
                new DownloadSettingsSaveOutcome(new(1, MutationResultStatus.ConfirmedSuccess, "downloadSettings", true, false, new(1, 0, 0)),
                    request.Expected with { Value = request.Desired }, DownloadSettingsComponentState.Confirmed, DownloadSettingsComponentState.Confirmed));
        }
        public Task<DownloadTaskPage> ListTasksAsync(int offset, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DownloadStationSnapshot> LoadSnapshotAsync(int offset, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DownloadTaskControlOutcome> ControlTaskAsync(DownloadTaskControlRequest request, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
