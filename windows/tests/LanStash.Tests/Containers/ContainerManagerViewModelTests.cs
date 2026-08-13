using LanStash.App.Features.Containers;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class ContainerManagerViewModelTests
{
    [Fact]
    public async Task UnavailableRepositoryMakesNoRequestAndRefreshIsDisabled()
    {
        var repository = new FakeRepository(Guid.NewGuid(), available: false);
        using var model = new ContainerManagerViewModel();

        await model.ActivateAsync(repository);
        await model.RefreshAsync();

        Assert.Equal(ContainerManagerContentState.Unavailable, model.ContentState);
        Assert.Equal(ContainerManagerContentState.Unavailable, model.ImagesState);
        Assert.Equal(ContainerManagerContentState.Unavailable, model.NetworksState);
        Assert.Equal(ContainerManagerContentState.Unavailable, model.ProjectsState);
        Assert.Equal(ContainerManagerContentState.Unavailable, model.EventsState);
        Assert.False(model.CanRefresh);
        Assert.Empty(repository.Requests);
    }

    [Fact]
    public async Task FiltersAndSelectionUseTypedStableState()
    {
        var repository = Available(Guid.NewGuid());
        repository.Results.Enqueue(Snapshot(
            repository.ProfileId,
            Container("running", ContainerOperationalState.Running),
            Container("stopped", ContainerOperationalState.Stopped),
            Container("error", ContainerOperationalState.Attention),
            Container("unknown", ContainerOperationalState.Unknown)));
        using var model = new ContainerManagerViewModel();
        await model.ActivateAsync(repository);

        model.SetFilter(ContainerManagerFilter.Running);
        Assert.Equal("running", Assert.Single(model.Containers).Id);
        model.SelectContainer(model.Containers.Single());
        Assert.Equal("running", model.SelectedContainer?.Id);
        model.SetFilter(ContainerManagerFilter.Attention);
        Assert.Equal(
            new[] { "error", "unknown" },
            model.Containers.Select(item => item.Id).ToArray());
        Assert.Null(model.SelectedContainer);
        model.SetFilter(ContainerManagerFilter.Stopped);
        Assert.Equal("stopped", Assert.Single(model.Containers).Id);
    }

    [Fact]
    public async Task EmptyFilteredEmptyErrorAndContentAreDistinct()
    {
        var emptyRepository = Available(Guid.NewGuid());
        emptyRepository.Results.Enqueue(Snapshot(emptyRepository.ProfileId));
        using var empty = new ContainerManagerViewModel();
        await empty.ActivateAsync(emptyRepository);
        Assert.Equal(ContainerManagerContentState.Empty, empty.ContentState);

        var filteredRepository = Available(Guid.NewGuid());
        filteredRepository.Results.Enqueue(Snapshot(
            filteredRepository.ProfileId,
            Container("running", ContainerOperationalState.Running)));
        using var filtered = new ContainerManagerViewModel();
        await filtered.ActivateAsync(filteredRepository);
        Assert.Equal(ContainerManagerContentState.Content, filtered.ContentState);
        filtered.SetFilter(ContainerManagerFilter.Stopped);
        Assert.Equal(ContainerManagerContentState.FilteredEmpty, filtered.ContentState);

        var failedRepository = Available(Guid.NewGuid());
        failedRepository.Results.Enqueue(new IOException("synthetic"));
        using var failed = new ContainerManagerViewModel();
        await failed.ActivateAsync(failedRepository);
        Assert.Equal(ContainerManagerContentState.Error, failed.ContentState);
    }

    [Fact]
    public async Task RefreshFailureRetainsContentFilterAndSelection()
    {
        var repository = Available(Guid.NewGuid());
        repository.Results.Enqueue(Snapshot(
            repository.ProfileId,
            Container("kept", ContainerOperationalState.Running)));
        repository.Results.Enqueue(new IOException("synthetic refresh"));
        using var model = new ContainerManagerViewModel();
        await model.ActivateAsync(repository);
        model.SetFilter(ContainerManagerFilter.Running);
        model.SelectContainer(model.Containers.Single());

        await model.RefreshAsync();

        Assert.Equal("kept", Assert.Single(model.Containers).Id);
        Assert.Equal("kept", model.SelectedContainer?.Id);
        Assert.Equal(ContainerManagerFilter.Running, model.Filter);
        Assert.True(model.HasRefreshError);
        Assert.False(model.IsLoading);
    }

    [Theory]
    [InlineData(500, true)]
    [InlineData(106, false)]
    [InlineData(107, false)]
    [InlineData(119, false)]
    public async Task AuthenticationFailureRequiresReconnectAndIsNeverAutomaticallyReplayed(
        int code,
        bool authenticationFailure)
    {
        var repository = Available(Guid.NewGuid());
        repository.Results.Enqueue(Snapshot(
            repository.ProfileId,
            Container("kept", ContainerOperationalState.Running)));
        repository.Results.Enqueue(new DsmException(
            "login",
            "login",
            code,
            authenticationFailure));
        using var model = new ContainerManagerViewModel();
        await model.ActivateAsync(repository);

        await model.RefreshAsync();
        await model.ActivateAsync(repository);
        await model.RefreshAsync();

        Assert.True(model.RequiresReconnect);
        Assert.False(model.HasRefreshError);
        Assert.False(model.CanRefresh);
        Assert.False(model.IsLoading);
        Assert.Equal("kept", Assert.Single(model.Containers).Id);
        Assert.Equal(2, repository.Requests.Count);
    }

    [Fact]
    public async Task SectionFailureRetainsItsContentWhileOtherSectionsRefresh()
    {
        var repository = Available(Guid.NewGuid());
        repository.Results.Enqueue(SectionSnapshot(
            repository.ProfileId,
            containers: [Container("old", ContainerOperationalState.Running)],
            images: [Resource("old-image", ContainerResourceKind.Image)]));
        repository.Results.Enqueue(new ContainerManagerSnapshot(
            repository.ProfileId,
            ContainerManagerSection<ContainerSummary>.Available([Container("new", ContainerOperationalState.Stopped)]),
            ContainerManagerSection<ContainerResourceSummary>.Failed,
            ContainerManagerSection<ContainerResourceSummary>.Available([Resource("network", ContainerResourceKind.Network)]),
            ContainerManagerSection<ContainerResourceSummary>.Available([]),
            ContainerManagerSection<ServiceEventSummary>.Available([new("event", DateTimeOffset.UnixEpoch, ServiceEventLevel.Information)])));
        using var model = new ContainerManagerViewModel();
        await model.ActivateAsync(repository);

        await model.RefreshAsync();

        Assert.Equal("new", Assert.Single(model.Containers).Id);
        Assert.Equal("old-image", Assert.Single(model.Images).Name);
        Assert.Equal(ContainerManagerContentState.Content, model.ImagesState);
        Assert.Equal("network", Assert.Single(model.Networks).Name);
        Assert.Equal(ContainerManagerContentState.Empty, model.ProjectsState);
        Assert.Single(model.Events);
        Assert.True(model.HasRefreshError);
    }

    [Fact]
    public async Task ProfileSwitchCancelsOldGenerationAndRejectsLateSnapshot()
    {
        var profileA = Guid.NewGuid();
        var delayed = new TaskCompletionSource<ContainerManagerSnapshot>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repositoryA = Available(profileA);
        repositoryA.Results.Enqueue(delayed.Task);
        var profileB = Guid.NewGuid();
        var repositoryB = Available(profileB);
        repositoryB.Results.Enqueue(Snapshot(
            profileB,
            Container("b", ContainerOperationalState.Stopped)));
        using var model = new ContainerManagerViewModel();

        var activationA = model.ActivateAsync(repositoryA);
        await WaitUntilAsync(() => repositoryA.Requests.Count == 1);
        var oldToken = repositoryA.Requests.Single();
        await model.ActivateAsync(repositoryB);
        delayed.SetResult(Snapshot(
            profileA,
            Container("late-a", ContainerOperationalState.Running)));
        await activationA;

        Assert.True(oldToken.IsCancellationRequested);
        Assert.Equal(profileB, model.ActiveProfileId);
        Assert.Equal("b", Assert.Single(model.Containers).Id);
        Assert.False(model.RequiresReconnect);
        Assert.False(model.HasRefreshError);
    }

    [Fact]
    public async Task RepositoryReplacementRestoresCacheAndRefreshUsesNewBinding()
    {
        var profile = Guid.NewGuid();
        var first = Available(profile);
        first.Results.Enqueue(Snapshot(profile, Container("cached", ContainerOperationalState.Running)));
        var replacement = Available(profile);
        replacement.Results.Enqueue(Snapshot(profile, Container("fresh", ContainerOperationalState.Stopped)));
        using var model = new ContainerManagerViewModel();

        await model.ActivateAsync(first);
        model.SetFilter(ContainerManagerFilter.Running);
        model.SelectContainer(model.Containers.Single());
        await model.ActivateAsync(replacement);

        Assert.Empty(replacement.Requests);
        Assert.Equal(ContainerManagerFilter.Running, model.Filter);
        Assert.Equal("cached", model.SelectedContainer?.Id);
        await model.RefreshAsync();
        Assert.Single(replacement.Requests);
        Assert.Equal(ContainerManagerContentState.FilteredEmpty, model.ContentState);
    }

    [Fact]
    public async Task FifthProfileEvictsLeastRecentlyUsedCache()
    {
        var repositories = Enumerable.Range(0, 5)
            .Select(index => Available(Guid.NewGuid()))
            .ToArray();
        for (var index = 0; index < repositories.Length; index++)
        {
            repositories[index].Results.Enqueue(Snapshot(
                repositories[index].ProfileId,
                Container($"item-{index}", ContainerOperationalState.Running)));
        }
        repositories[0].Results.Enqueue(Snapshot(
            repositories[0].ProfileId,
            Container("reloaded", ContainerOperationalState.Stopped)));
        using var model = new ContainerManagerViewModel();

        foreach (var repository in repositories)
        {
            await model.ActivateAsync(repository);
        }
        await model.ActivateAsync(repositories[0]);

        Assert.Equal(2, repositories[0].Requests.Count);
        Assert.Equal("reloaded", Assert.Single(model.Containers).Id);
    }

    [Fact]
    public async Task DisposeCancelsRequestAndLateResultCannotWriteBack()
    {
        var repository = Available(Guid.NewGuid());
        var delayed = new TaskCompletionSource<ContainerManagerSnapshot>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Results.Enqueue(delayed.Task);
        var model = new ContainerManagerViewModel();

        var activation = model.ActivateAsync(repository);
        await WaitUntilAsync(() => repository.Requests.Count == 1);
        var token = repository.Requests.Single();
        model.Dispose();
        delayed.SetResult(Snapshot(
            repository.ProfileId,
            Container("late", ContainerOperationalState.Running)));
        await activation;

        Assert.True(token.IsCancellationRequested);
        Assert.Empty(model.Containers);
    }

    [Fact]
    public void DisplayItemLocalizesMissingImageAndNeverUsesInternalIdAsFallback()
    {
        var item = new ContainerItem(new(
            "internal-id",
            "Visible name",
            ContainerOperationalState.Unknown,
            null));

        Assert.False(string.IsNullOrWhiteSpace(item.ImageText));
        Assert.DoesNotContain("internal-id", item.ImageText, StringComparison.Ordinal);
        Assert.DoesNotContain("internal-id", item.AutomationName, StringComparison.Ordinal);
    }

    private static FakeRepository Available(Guid profileId) => new(profileId, available: true);

    private static ContainerManagerSnapshot SectionSnapshot(
        Guid profileId,
        IReadOnlyList<ContainerSummary>? containers = null,
        IReadOnlyList<ContainerResourceSummary>? images = null,
        IReadOnlyList<ContainerResourceSummary>? networks = null,
        IReadOnlyList<ContainerResourceSummary>? projects = null,
        IReadOnlyList<ServiceEventSummary>? events = null) => new(
            profileId,
            ContainerManagerSection<ContainerSummary>.Available(containers ?? []),
            ContainerManagerSection<ContainerResourceSummary>.Available(images ?? []),
            ContainerManagerSection<ContainerResourceSummary>.Available(networks ?? []),
            ContainerManagerSection<ContainerResourceSummary>.Available(projects ?? []),
            ContainerManagerSection<ServiceEventSummary>.Available(events ?? []));

    private static ContainerManagerSnapshot Snapshot(
        Guid profileId,
        params ContainerSummary[] containers) => SectionSnapshot(profileId, containers: containers);

    private static ContainerSummary Container(
        string id,
        ContainerOperationalState state) => new(id, id, state, $"image-{id}");

    private static ContainerResourceSummary Resource(string id, ContainerResourceKind kind) =>
        new(id, id, kind, ContainerOperationalState.Unknown);

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        for (var attempt = 0; attempt < 100 && !condition(); attempt++)
        {
            await Task.Delay(10);
        }
        Assert.True(condition());
    }

    private sealed class FakeRepository(Guid profileId, bool available)
        : IContainerManagerRepository
    {
        public Guid ProfileId { get; } = profileId;
        public ContainerManagerAvailability Availability { get; } = new(
            available
                ? ContainerManagerAvailabilityStatus.InternalObserved
                : ContainerManagerAvailabilityStatus.Unavailable,
            available
                ? new HashSet<ContainerManagerReadFeature>(Enum.GetValues<ContainerManagerReadFeature>())
                : new HashSet<ContainerManagerReadFeature>());
        public Queue<object> Results { get; } = new();
        public List<CancellationToken> Requests { get; } = [];

        public Task<ContainerManagerSnapshot> LoadSnapshotAsync(
            CancellationToken cancellationToken = default)
        {
            Requests.Add(cancellationToken);
            return Results.Dequeue() switch
            {
                ContainerManagerSnapshot snapshot => Task.FromResult(snapshot),
                Task<ContainerManagerSnapshot> task => task,
                Exception error => Task.FromException<ContainerManagerSnapshot>(error),
                var value => throw new InvalidOperationException(value.GetType().Name),
            };
        }
    }
}
