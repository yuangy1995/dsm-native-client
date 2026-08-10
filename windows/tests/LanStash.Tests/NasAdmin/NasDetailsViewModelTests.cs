using System.IO;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDetailsViewModelTests
{
    [Fact]
    public async Task UnavailableRepositoryMakesNoRequestAndRefreshIsDisabled()
    {
        var repository = new FakeRepository(Guid.NewGuid(), available: false);
        using var model = new NasDetailsViewModel();

        await model.ActivateAsync(repository);
        await model.RefreshAsync();

        Assert.Equal(NasDetailsContentState.Unavailable, model.ContentState);
        Assert.False(model.CanRefresh);
        Assert.Empty(repository.Requests);
    }

    [Fact]
    public async Task SectionsProjectOnlySafeDisplayRows()
    {
        var repository = Available(Guid.NewGuid());
        repository.Results.Enqueue(new NasDetailsSnapshot(
            repository.ProfileId,
            new NasDetailsSection<NasPackageSummary>(
                NasDetailsSectionStatus.Available,
                [new NasPackageSummary("pkg", "Drive", "3.0", "running", ResourceState.Running)]),
            new NasDetailsSection<NasScheduledTaskSummary>(
                NasDetailsSectionStatus.Available,
                [new NasScheduledTaskSummary("task", "Backup", true, "Tonight")]),
            new NasDetailsSection<NasLogSummary>(
                NasDetailsSectionStatus.Available,
                [new NasLogSummary("log", DateTimeOffset.UnixEpoch, "System", "info")]),
            new NasDetailsSection<NasConnectionSummary>(
                NasDetailsSectionStatus.Available,
                [new NasConnectionSummary("conn", "DSM", "web", DateTimeOffset.UnixEpoch, true)])));
        using var model = new NasDetailsViewModel();

        await model.ActivateAsync(repository);

        Assert.Equal(NasDetailsContentState.Content, model.ContentState);
        Assert.Equal("Drive", Assert.Single(model.Rows).Title);
        model.SelectSection(NasDetailsSectionKind.ScheduledTasks);
        Assert.Equal("Backup", Assert.Single(model.Rows).Title);
        model.SelectSection(NasDetailsSectionKind.Logs);
        Assert.Equal("System", Assert.Single(model.Rows).Title);
        model.SelectSection(NasDetailsSectionKind.Connections);
        Assert.Equal("DSM", Assert.Single(model.Rows).Title);
    }

    [Fact]
    public async Task SectionUnavailableFailedEmptyAndTruncatedRemainDistinct()
    {
        var packages = Enumerable.Range(0, 50)
            .Select(index => new NasPackageSummary(
                $"pkg-{index}",
                $"Package {index}",
                "1.0",
                "running",
                ResourceState.Running))
            .ToArray();
        var repository = Available(Guid.NewGuid());
        repository.Results.Enqueue(new NasDetailsSnapshot(
            repository.ProfileId,
            new NasDetailsSection<NasPackageSummary>(
                NasDetailsSectionStatus.Available,
                packages,
                IsTruncated: true),
            new NasDetailsSection<NasScheduledTaskSummary>(
                NasDetailsSectionStatus.Unavailable,
                []),
            new NasDetailsSection<NasLogSummary>(
                NasDetailsSectionStatus.Failed,
                []),
            new NasDetailsSection<NasConnectionSummary>(
                NasDetailsSectionStatus.Available,
                [])));
        using var model = new NasDetailsViewModel();

        await model.ActivateAsync(repository);

        Assert.Equal(NasDetailsContentState.Content, model.ContentState);
        Assert.True(model.SectionNoticeIsOpen);
        Assert.Equal(50, model.Rows.Count);
        model.SelectSection(NasDetailsSectionKind.ScheduledTasks);
        Assert.Equal(NasDetailsContentState.Unavailable, model.ContentState);
        model.SelectSection(NasDetailsSectionKind.Logs);
        Assert.Equal(NasDetailsContentState.Error, model.ContentState);
        model.SelectSection(NasDetailsSectionKind.Connections);
        Assert.Equal(NasDetailsContentState.Empty, model.ContentState);
    }

    [Fact]
    public async Task RefreshFailureRetainsPreviousSectionAndRows()
    {
        var repository = Available(Guid.NewGuid());
        repository.Results.Enqueue(Snapshot(repository.ProfileId, packageName: "Kept"));
        repository.Results.Enqueue(new IOException("synthetic refresh"));
        using var model = new NasDetailsViewModel();
        await model.ActivateAsync(repository);
        model.SelectSection(NasDetailsSectionKind.Packages);

        await model.RefreshAsync();

        Assert.Equal("Kept", Assert.Single(model.Rows).Title);
        Assert.Equal(NasDetailsContentState.Content, model.ContentState);
        Assert.True(model.HasRefreshError);
        Assert.False(model.IsLoading);
    }

    [Fact]
    public async Task ProfileSwitchCancelsOldGenerationAndRejectsLateSnapshot()
    {
        var profileA = Guid.NewGuid();
        var delayed = new TaskCompletionSource<NasDetailsSnapshot>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repositoryA = Available(profileA);
        repositoryA.Results.Enqueue(delayed.Task);
        var profileB = Guid.NewGuid();
        var repositoryB = Available(profileB);
        repositoryB.Results.Enqueue(Snapshot(profileB, packageName: "B"));
        using var model = new NasDetailsViewModel();

        var activationA = model.ActivateAsync(repositoryA);
        await WaitUntilAsync(() => repositoryA.Requests.Count == 1);
        var oldToken = repositoryA.Requests.Single();
        await model.ActivateAsync(repositoryB);
        delayed.SetResult(Snapshot(profileA, packageName: "Late A"));
        await activationA;

        Assert.True(oldToken.IsCancellationRequested);
        Assert.Equal(profileB, model.ActiveProfileId);
        Assert.Equal("B", Assert.Single(model.Rows).Title);
    }

    private static FakeRepository Available(Guid profileId) => new(profileId, available: true);

    private static NasDetailsSnapshot Snapshot(Guid profileId, string packageName) =>
        new(
            profileId,
            new NasDetailsSection<NasPackageSummary>(
                NasDetailsSectionStatus.Available,
                [new NasPackageSummary("pkg", packageName, "1.0", "running", ResourceState.Running)]),
            new NasDetailsSection<NasScheduledTaskSummary>(
                NasDetailsSectionStatus.Available,
                []),
            new NasDetailsSection<NasLogSummary>(
                NasDetailsSectionStatus.Available,
                []),
            new NasDetailsSection<NasConnectionSummary>(
                NasDetailsSectionStatus.Available,
                []));

    private static async Task WaitUntilAsync(Func<bool> predicate)
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            if (predicate())
            {
                return;
            }
            await Task.Delay(10);
        }
        throw new TimeoutException("The expected condition was not reached.");
    }

    private sealed class FakeRepository(Guid profileId, bool available) : INasDetailsRepository
    {
        public Guid ProfileId { get; } = profileId;
        public Queue<object> Results { get; } = [];
        public List<CancellationToken> Requests { get; } = [];
        public NasDetailsAvailability Availability { get; } = new(
            available ? NasDetailsAvailabilityStatus.Available : NasDetailsAvailabilityStatus.Unavailable,
            available
                ? new HashSet<NasDetailsReadFeature>
                {
                    NasDetailsReadFeature.Packages,
                    NasDetailsReadFeature.ScheduledTasks,
                    NasDetailsReadFeature.Logs,
                    NasDetailsReadFeature.Connections,
                }
                : new HashSet<NasDetailsReadFeature>());

        public async Task<NasDetailsSnapshot> LoadDetailsAsync(
            CancellationToken cancellationToken = default)
        {
            Requests.Add(cancellationToken);
            var result = Results.Dequeue();
            return result switch
            {
                NasDetailsSnapshot snapshot => snapshot,
                Task<NasDetailsSnapshot> task => await task,
                Exception error => throw error,
                _ => throw new InvalidOperationException("Unexpected fake result."),
            };
        }
    }
}
