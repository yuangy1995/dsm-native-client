using LanStash.App.Features.Files;
using LanStash.App.Features.Files.Locations;
using LanStash.Domain;

namespace LanStash.Tests.Files.Locations;

public sealed class FileLocationsViewModelTests
{
    [Fact]
    public async Task LateProfileResultCannotReplaceActiveRepositoryStateAndOldRequestIsCancelled()
    {
        var profileA = Guid.NewGuid();
        var profileB = Guid.NewGuid();
        var repositoryA = new ControlledRepository(profileA);
        var repositoryB = new ControlledRepository(profileB);
        using var browserA = new FileBrowserViewModel(new ImmediateSource());
        using var browserB = new FileBrowserViewModel(new ImmediateSource());
        using var model = new FileLocationsViewModel();

        model.Activate(profileA, repositoryA, browserA);
        var refreshA = model.RefreshAsync();
        model.Activate(profileB, repositoryB, browserB);
        var refreshB = model.RefreshAsync();
        repositoryB.Complete(Snapshot(profileB, "B"));
        await refreshB;
        repositoryA.Complete(Snapshot(profileA, "A"));
        await refreshA;

        Assert.True(repositoryA.Cancellation.IsCancellationRequested);
        Assert.Equal(profileB, model.ProfileId);
        Assert.Equal("B", Assert.Single(model.Favorites.Items).Name);
    }

    [Fact]
    public async Task SectionFailureKeepsBaselineWhileOtherSectionsRefreshIndependently()
    {
        var profile = Guid.NewGuid();
        var repository = new QueueRepository(profile,
            Snapshot(profile, "baseline"),
            Snapshot(profile, "ignored", favoriteFailed: true, remoteName: "remote-new"));
        using var browser = new FileBrowserViewModel(new ImmediateSource());
        using var model = new FileLocationsViewModel();
        model.Activate(profile, repository, browser);

        await model.RefreshAsync();
        await model.RefreshAsync();

        Assert.Equal(FileLocationViewState.Error, model.Favorites.State);
        Assert.Equal("baseline", Assert.Single(model.Favorites.Items).Name);
        Assert.Equal(FileLocationViewState.Content, model.Remote.State);
        Assert.Equal("remote-new", Assert.Single(model.Remote.Items).Name);
    }

    [Fact]
    public async Task TransactionFailureDoesNotChangePathOrRecentAndSuccessCommitsOnce()
    {
        var profile = Guid.NewGuid();
        var source = new QueueSource(
            new FilePage([new FileItem("/old/file.txt", "file.txt", false, 1, null, null, false, false)], 1, 0),
            new InvalidDataException("synthetic"),
            new FilePage([], 0, 0));
        using var browser = new FileBrowserViewModel(source);
        await browser.InitializeAsync();
        browser.SelectedItem = browser.Items.Single();
        var baselineSelection = browser.SelectedItem;
        using var model = new FileLocationsViewModel();
        model.Activate(profile, new QueueRepository(profile, Snapshot(profile, "one")), browser);

        Assert.False(await model.OpenLocationAsync("/failed", FileLocationSource.Favorite));
        Assert.Equal(string.Empty, browser.CurrentPath);
        Assert.Same(baselineSelection, browser.SelectedItem);
        Assert.Empty(model.RecentLocations);

        Assert.True(await model.OpenLocationAsync("/success", FileLocationSource.Favorite));
        Assert.Equal("/success", browser.CurrentPath);
        Assert.Null(browser.SelectedItem);
        Assert.Equal("/success", Assert.Single(model.RecentLocations).Path);
    }

    [Fact]
    public async Task LateOpenCannotPolluteNewProfileOrReplacementBrowser()
    {
        var profileA = Guid.NewGuid();
        var profileB = Guid.NewGuid();
        var sourceA = new ControlledOpenSource();
        using var browserA = new FileBrowserViewModel(sourceA);
        using var browserB = new FileBrowserViewModel(new ImmediateSource());
        using var model = new FileLocationsViewModel();
        model.Activate(profileA, new QueueRepository(profileA, Snapshot(profileA, "A")), browserA);
        var lateA = model.OpenLocationAsync("/late-a", FileLocationSource.Favorite);
        await sourceA.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));

        model.Activate(profileB, new QueueRepository(profileB, Snapshot(profileB, "B")), browserB);
        Assert.True(sourceA.Cancellation.IsCancellationRequested);
        sourceA.Complete(new FilePage([], 0, 0));

        Assert.False(await lateA);
        Assert.Equal(profileB, model.ProfileId);
        Assert.Equal(FileLocationSource.Shares, model.SelectedSource);
        Assert.Empty(model.RecentLocations);

        var sourceOld = new ControlledOpenSource();
        using var oldBrowser = new FileBrowserViewModel(sourceOld);
        model.Activate(profileB, new QueueRepository(profileB, Snapshot(profileB, "B2")), oldBrowser);
        var lateSameProfile = model.OpenLocationAsync("/late-old-browser", FileLocationSource.Remote);
        await sourceOld.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));
        model.Activate(profileB, new QueueRepository(profileB, Snapshot(profileB, "B3")), browserB);
        sourceOld.Complete(new FilePage([], 0, 0));

        Assert.False(await lateSameProfile);
        Assert.Equal(FileLocationSource.Shares, model.SelectedSource);
        Assert.Empty(model.RecentLocations);
    }

    [Fact]
    public async Task RecentIsPerProfileDeduplicatedBoundedAndExcludesRemoteRecycle()
    {
        var profile = Guid.NewGuid();
        using var browser = new FileBrowserViewModel(new ImmediateSource());
        using var model = new FileLocationsViewModel();
        model.Activate(profile, new QueueRepository(profile, Snapshot(profile, "one")), browser);

        for (var index = 0; index < 13; index++)
        {
            Assert.True(await model.OpenLocationAsync($"/folder-{index}", FileLocationSource.Browser));
        }
        Assert.Equal(12, model.RecentLocations.Count);
        Assert.DoesNotContain(model.RecentLocations, item => item.Path == "/folder-0");
        Assert.True(await model.OpenLocationAsync("/folder-5", FileLocationSource.Recent));
        Assert.Equal("/folder-5", model.RecentLocations[0].Path);
        Assert.Equal(12, model.RecentLocations.Count);

        Assert.True(await model.OpenLocationAsync("/remote", FileLocationSource.Remote));
        Assert.True(await model.OpenLocationAsync("/share/#recycle/deleted", FileLocationSource.Browser));
        Assert.DoesNotContain(model.RecentLocations, item => item.Path is "/remote" or "/share/#recycle/deleted");

        model.Deactivate();
        model.Activate(profile, new QueueRepository(profile, Snapshot(profile, "two")), browser);
        Assert.Equal(12, model.RecentLocations.Count);
        model.PurgeProfile(profile);
        model.Activate(profile, new QueueRepository(profile, Snapshot(profile, "three")), browser);
        Assert.Empty(model.RecentLocations);
    }

    [Fact]
    public async Task PathSourceMappingRestoresNormalRemoteAndRootSemantics()
    {
        var profile = Guid.NewGuid();
        using var browser = new FileBrowserViewModel(new ImmediateSource());
        await browser.InitializeAsync();
        using var model = new FileLocationsViewModel();
        model.Activate(profile, new QueueRepository(profile, Snapshot(profile, "one")), browser);

        Assert.True(await model.OpenLocationAsync("/normal", FileLocationSource.Browser));
        Assert.True(await model.OpenLocationAsync("/remote", FileLocationSource.Remote));
        await browser.GoBackAsync();
        Assert.Equal(FileLocationSource.Browser, model.SelectedSource);

        Assert.True(await model.OpenLocationAsync("/remote", FileLocationSource.Remote));
        Assert.True(await browser.OpenLocationAsync("/remote/child"));
        Assert.Equal(FileLocationSource.Remote, model.SelectedSource);
        await browser.GoBackAsync();
        Assert.Equal(FileLocationSource.Remote, model.SelectedSource);

        await browser.GoBackAsync();
        await browser.GoBackAsync();
        Assert.Equal(string.Empty, browser.CurrentPath);
        Assert.Equal(FileLocationSource.Shares, model.SelectedSource);
        Assert.DoesNotContain(model.RecentLocations, item => string.IsNullOrWhiteSpace(item.Path));
    }

    [Fact]
    public async Task LeavingExplicitRecycleRootFallsBackToBrowserWhileRemoteDescendantInherits()
    {
        var profile = Guid.NewGuid();
        using var browser = new FileBrowserViewModel(new ImmediateSource());
        using var model = new FileLocationsViewModel();
        model.Activate(profile, new QueueRepository(profile, Snapshot(profile, "one")), browser);

        Assert.True(await model.OpenLocationAsync("/share/#recycle", FileLocationSource.Recycle));
        await browser.GoUpAsync();
        Assert.Equal("/share", browser.CurrentPath);
        Assert.Equal(FileLocationSource.Browser, model.SelectedSource);
        Assert.Equal("/share", Assert.Single(model.RecentLocations).Path);

        Assert.True(await model.OpenLocationAsync("/remote-root", FileLocationSource.Remote));
        Assert.True(await browser.OpenLocationAsync("/remote-root/child"));
        Assert.Equal(FileLocationSource.Remote, model.SelectedSource);
        Assert.DoesNotContain(model.RecentLocations, item => item.Path == "/remote-root/child");
        await browser.GoBackAsync();
        Assert.Equal("/remote-root", browser.CurrentPath);
        Assert.Equal(FileLocationSource.Remote, model.SelectedSource);
    }

    [Fact]
    public async Task ExactEmptyRootTransactionCommitsSharesOnceAndNeverWritesEmptyRecent()
    {
        var profile = Guid.NewGuid();
        using var browser = new FileBrowserViewModel(new ImmediateSource());
        using var model = new FileLocationsViewModel();
        model.Activate(profile, new QueueRepository(profile, Snapshot(profile, "one")), browser);
        Assert.True(await model.OpenLocationAsync("/folder", FileLocationSource.Browser));

        Assert.True(await model.OpenLocationAsync(string.Empty, FileLocationSource.Shares));

        Assert.Equal(string.Empty, browser.CurrentPath);
        Assert.Equal(FileLocationSource.Shares, model.SelectedSource);
        Assert.DoesNotContain(model.RecentLocations, item => string.IsNullOrWhiteSpace(item.Path));
        await browser.GoBackAsync();
        Assert.Equal("/folder", browser.CurrentPath);
        await browser.GoBackAsync();
        Assert.Equal(string.Empty, browser.CurrentPath);
    }

    [Fact]
    public async Task LaterExplicitRootOverridesOlderExactBrowserChildCache()
    {
        var profile = Guid.NewGuid();
        using var browser = new FileBrowserViewModel(new ImmediateSource());
        using var model = new FileLocationsViewModel();
        model.Activate(profile, new QueueRepository(profile, Snapshot(profile, "one")), browser);

        Assert.True(await browser.OpenLocationAsync("/remote-root/child"));
        Assert.Equal(FileLocationSource.Browser, model.SelectedSource);
        Assert.True(await model.OpenLocationAsync("/remote-root", FileLocationSource.Remote));
        Assert.True(await browser.OpenLocationAsync("/remote-root/child"));
        Assert.Equal(FileLocationSource.Remote, model.SelectedSource);
        Assert.DoesNotContain(model.RecentLocations, item => item.Path == "/remote-root/child");

        Assert.True(await browser.OpenLocationAsync("/share/#recycle/child"));
        Assert.True(await model.OpenLocationAsync("/share/#recycle", FileLocationSource.Recycle));
        Assert.True(await browser.OpenLocationAsync("/share/#recycle/child"));
        Assert.Equal(FileLocationSource.Recycle, model.SelectedSource);
        Assert.DoesNotContain(model.RecentLocations, item => item.Path == "/share/#recycle/child");
    }

    [Fact]
    public async Task ReadOnlyRootsAndRecycleSegmentsCannotBeDowngradedByExplicitWritableSources()
    {
        var profile = Guid.NewGuid();
        using var browser = new FileBrowserViewModel(new ImmediateSource());
        using var model = new FileLocationsViewModel();
        model.Activate(profile, new QueueRepository(profile, Snapshot(profile, "one")), browser);

        Assert.True(await model.OpenLocationAsync("/remote-root", FileLocationSource.Remote));
        Assert.True(await model.OpenLocationAsync("/remote-root/child", FileLocationSource.Favorite));
        Assert.Equal(FileLocationSource.Remote, model.SelectedSource);
        Assert.DoesNotContain(model.RecentLocations, item => item.Path == "/remote-root/child");

        Assert.True(await browser.OpenLocationAsync("/share/#ReCyClE/item"));
        Assert.Equal(FileLocationSource.Recycle, model.SelectedSource);
        Assert.DoesNotContain(model.RecentLocations, item => item.Path == "/share/#ReCyClE/item");
        await browser.GoUpAsync();
        await browser.GoUpAsync();
        Assert.Equal("/share", browser.CurrentPath);
        Assert.Equal(FileLocationSource.Browser, model.SelectedSource);
        Assert.Contains(model.RecentLocations, item => item.Path == "/share");
    }

    [Fact]
    public async Task GlobalFailureMarksAllSectionsAndRefreshFailureKeepsBaselines()
    {
        var profile = Guid.NewGuid();
        using var browser = new FileBrowserViewModel(new ImmediateSource());
        using var first = new FileLocationsViewModel();
        first.Activate(profile, new ThrowingRepository(profile, new DsmException("auth", "login", 119)), browser);
        await first.RefreshAsync();
        Assert.All(new[] { first.Favorites.State, first.Recycle.State, first.Remote.State }, state =>
            Assert.Equal(FileLocationViewState.Error, state));

        using var baseline = new FileLocationsViewModel();
        baseline.Activate(
            profile,
            new QueueThenThrowRepository(profile, Snapshot(profile, "kept"), new IOException("synthetic")),
            browser);
        await baseline.RefreshAsync();
        await baseline.RefreshAsync();
        Assert.Equal("kept", Assert.Single(baseline.Favorites.Items).Name);
        Assert.Equal(FileLocationViewState.Error, baseline.Favorites.State);
        Assert.False(baseline.Favorites.IsRefreshing);
        Assert.NotNull(baseline.Favorites.ErrorTag);
    }

    [Fact]
    public async Task CallerCancellationRestoresBaselineAndClearsBusyState()
    {
        var profile = Guid.NewGuid();
        using var browser = new FileBrowserViewModel(new ImmediateSource());
        using var model = new FileLocationsViewModel();
        model.Activate(profile, new CancellingRepository(profile), browser);
        using var cancellation = new CancellationTokenSource();
        var refresh = model.RefreshAsync(cancellation.Token);
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => refresh);
        Assert.Equal(FileLocationViewState.Idle, model.Favorites.State);
        Assert.False(model.Favorites.IsRefreshing);
    }

    [Fact]
    public async Task WrongSnapshotOrItemProfileFailsAllSectionsWithoutCrossProfilePublication()
    {
        var profile = Guid.NewGuid();
        var other = Guid.NewGuid();
        using var browser = new FileBrowserViewModel(new ImmediateSource());
        using var wrongSnapshot = new FileLocationsViewModel();
        wrongSnapshot.Activate(profile, new QueueRepository(profile, Snapshot(other, "wrong")), browser);
        await wrongSnapshot.RefreshAsync();
        Assert.All(
            new[] { wrongSnapshot.Favorites.State, wrongSnapshot.Recycle.State, wrongSnapshot.Remote.State },
            state => Assert.Equal(FileLocationViewState.Error, state));
        Assert.Empty(wrongSnapshot.Favorites.Items);

        var valid = Snapshot(profile, "valid");
        var wrongItem = valid with
        {
            Favorites = valid.Favorites with
            {
                Items = [new FileFavoriteLocation(other, "foreign", "/foreign")],
            },
            RecycleBins = valid.RecycleBins with
            {
                Items = [new FileRecycleLocation(other, "foreign", "/foreign", "/foreign/#recycle")],
            },
            RemoteLocations = valid.RemoteLocations with
            {
                Items = [new FileRemoteLocation(other, "cifs:/foreign", "foreign", "/foreign", FileRemoteProtocol.Cifs, false)],
            },
        };
        using var itemModel = new FileLocationsViewModel();
        itemModel.Activate(profile, new QueueRepository(profile, wrongItem), browser);
        await itemModel.RefreshAsync();
        Assert.Equal(FileLocationViewState.Error, itemModel.Favorites.State);
        Assert.Empty(itemModel.Favorites.Items);
        Assert.Equal(FileLocationViewState.Error, itemModel.Recycle.State);
        Assert.Equal(FileLocationViewState.Error, itemModel.Remote.State);
    }

    [Fact]
    public async Task CancellationAfterBrowserCommitStillCommitsSourceAndRecentAtomically()
    {
        var profile = Guid.NewGuid();
        using var browser = new FileBrowserViewModel(new ImmediateSource());
        using var model = new FileLocationsViewModel();
        model.Activate(profile, new QueueRepository(profile, Snapshot(profile, "one")), browser);
        using var cancellation = new CancellationTokenSource();
        browser.LocationCommitted += _ => cancellation.Cancel();

        var committed = await model.OpenLocationAsync(
            "/committed",
            FileLocationSource.Favorite,
            cancellation.Token);

        Assert.True(committed);
        Assert.True(cancellation.IsCancellationRequested);
        Assert.Equal("/committed", browser.CurrentPath);
        Assert.Equal(FileLocationSource.Favorite, model.SelectedSource);
        Assert.Equal("/committed", Assert.Single(model.RecentLocations).Path);
    }

    [Fact]
    public async Task NonCooperativeRepositoryCannotApplySnapshotAfterCallerCancellation()
    {
        var profile = Guid.NewGuid();
        var repository = new ControlledRepository(profile);
        using var browser = new FileBrowserViewModel(new ImmediateSource());
        using var model = new FileLocationsViewModel();
        model.Activate(profile, repository, browser);
        using var cancellation = new CancellationTokenSource();
        var refresh = model.RefreshAsync(cancellation.Token);
        cancellation.Cancel();
        repository.Complete(Snapshot(profile, "must-not-apply"));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => refresh);
        Assert.Equal(FileLocationViewState.Idle, model.Favorites.State);
        Assert.Empty(model.Favorites.Items);
    }

    private static FileLocationsSnapshot Snapshot(
        Guid profile,
        string favoriteName,
        bool favoriteFailed = false,
        string remoteName = "remote") => new(
        profile,
        new(true, true, true),
        new(
            favoriteFailed ? [] : [new FileFavoriteLocation(profile, favoriteName, $"/{favoriteName}")],
            favoriteFailed ? 0 : 1,
            favoriteFailed ? 0 : 1,
            FileLocationCompletion.Complete,
            favoriteFailed ? FileLocationSectionStatus.Failed : FileLocationSectionStatus.Available,
            favoriteFailed ? "favorite.failed" : null),
        new([], 0, 0, 0, false, FileLocationCompletion.Complete, FileLocationSectionStatus.Available),
        new(
            [new FileRemoteLocation(profile, "cifs:/remote", remoteName, "/remote", FileRemoteProtocol.Cifs, false)],
            1,
            1,
            [],
            false,
            FileLocationCompletion.Complete,
            FileLocationSectionStatus.Available));

    private sealed class ControlledRepository(Guid profileId) : IFileLocationsRepository
    {
        private readonly TaskCompletionSource<FileLocationsSnapshot> _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Guid ProfileId { get; } = profileId;
        public FileLocationsAvailability Availability { get; } = new(true, true, true);
        public CancellationToken Cancellation { get; private set; }
        public Task<FileLocationsSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default)
        {
            Cancellation = cancellationToken;
            return _completion.Task;
        }
        public void Complete(FileLocationsSnapshot snapshot) => _completion.TrySetResult(snapshot);
    }

    private sealed class QueueRepository(Guid profileId, params FileLocationsSnapshot[] snapshots) : IFileLocationsRepository
    {
        private readonly Queue<FileLocationsSnapshot> _snapshots = new(snapshots);
        public Guid ProfileId { get; } = profileId;
        public FileLocationsAvailability Availability { get; } = new(true, true, true);
        public Task<FileLocationsSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(_snapshots.Dequeue());
    }

    private sealed class ThrowingRepository(Guid profileId, Exception error) : IFileLocationsRepository
    {
        public Guid ProfileId { get; } = profileId;
        public FileLocationsAvailability Availability { get; } = new(true, true, true);
        public Task<FileLocationsSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default) =>
            Task.FromException<FileLocationsSnapshot>(error);
    }

    private sealed class QueueThenThrowRepository(Guid profileId, FileLocationsSnapshot snapshot, Exception error) : IFileLocationsRepository
    {
        private int _calls;
        public Guid ProfileId { get; } = profileId;
        public FileLocationsAvailability Availability { get; } = new(true, true, true);
        public Task<FileLocationsSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default) =>
            Interlocked.Increment(ref _calls) == 1
                ? Task.FromResult(snapshot)
                : Task.FromException<FileLocationsSnapshot>(error);
    }

    private sealed class CancellingRepository(Guid profileId) : IFileLocationsRepository
    {
        public Guid ProfileId { get; } = profileId;
        public FileLocationsAvailability Availability { get; } = new(true, true, true);
        public async Task<FileLocationsSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException();
        }
    }

    private sealed class ImmediateSource : IFileBrowserDataSource
    {
        public Task<FilePage> LoadPageAsync(string path, int offset, int limit, FileListOptions options, CancellationToken cancellationToken) =>
            Task.FromResult(new FilePage([], 0, offset));
    }

    private sealed class QueueSource(params object[] results) : IFileBrowserDataSource
    {
        private readonly Queue<object> _results = new(results);
        public Task<FilePage> LoadPageAsync(string path, int offset, int limit, FileListOptions options, CancellationToken cancellationToken)
        {
            var result = _results.Dequeue();
            return result is Exception error ? Task.FromException<FilePage>(error) : Task.FromResult((FilePage)result);
        }
    }

    private sealed class ControlledOpenSource : IFileBrowserDataSource
    {
        private readonly TaskCompletionSource<FilePage> _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public CancellationToken Cancellation { get; private set; }
        public Task<FilePage> LoadPageAsync(string path, int offset, int limit, FileListOptions options, CancellationToken cancellationToken)
        {
            Cancellation = cancellationToken;
            Started.TrySetResult();
            return _completion.Task;
        }
        public void Complete(FilePage page) => _completion.TrySetResult(page);
    }
}
