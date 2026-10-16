using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotoAutomaticModelTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1800000000);
    [Theory]
    [InlineData(2, 0, false, true, "2,2")] [InlineData(3, 0, false, true, "2,3")]
    [InlineData(4, 0, false, true, "2,3,4")] [InlineData(5, 0, false, true, "2,3,4,5")]
    [InlineData(6, 0, false, true, "2,3,4,5,6")]
    [InlineData(6, 0, true, true, "2,3")] [InlineData(6, 5, true, true, "1,2,3,4,5")]
    [InlineData(6, 5, true, false, "5")] [InlineData(6, 0, false, false, "2,3")]
    public void NeighborsUseWholeSetTrimmingAndTimelineBoundaries(int count, int index, bool timeline, bool complete, string expected)
    {
        var f = new Repository(); var photos = Enumerable.Range(1, count).Select(id => f.Photo(id)).ToArray();
        var context = f.Context(photos) with { Preview = photos[index], IsTimeline = timeline, IsComplete = complete };
        Assert.Equal(expected, string.Join(',', SynologyPhotoAutomaticModel.Neighbors(context).Select(photo => photo.Id.ItemId)));
    }
    [Fact]
    public void VideoExclusionDoesNotExpandTheNeighborWindow()
    {
        var f = new Repository(); var photos = Enumerable.Range(1, 9).Select(id => f.Photo(id, id is 2 or 3 or 4 ? "video" : "photo")).ToArray();
        var context = f.Context(photos) with { Preview = photos[0], IsTimeline = true, IsComplete = false };
        Assert.Empty(SynologyPhotoAutomaticModel.Neighbors(context));
    }
    [Fact]
    public async Task VisibleItemsDebounceTwoSecondsAndSameSetDoesNotResetDeadline()
    {
        var f = new Repository(); var photo = f.Photo(1); f.VisibleCandidates[1] = [f.Candidate(photo)]; using var model = f.Model(); var context = f.Context([photo]);
        model.SetVisible([photo.Id], Now); await model.TickAsync(context, Now); Assert.Empty(f.Generated);
        model.SetVisible([photo.Id], Now.AddSeconds(1)); await model.TickAsync(context, Now.AddSeconds(1)); Assert.Empty(f.ReadPhotos);
        await model.TickAsync(context, Now.AddSeconds(2)); Assert.Single(f.Generated); Assert.False(model.ShowsStatus);
    }
    [Fact]
    public async Task OrdinaryNeighborPrecedesExpensiveCurrentAndBackground()
    {
        var f = new Repository(); var photos = Enumerable.Range(1, 6).Select(id => f.Photo(id)).ToArray();
        f.VisibleCandidates[1] = [f.Candidate(photos[0], SynologyPhotoAutomaticPriority.Vc1)]; f.VisibleCandidates[2] = [f.Candidate(photos[1])];
        f.Background[SynologyPhotoSpace.Personal] = [f.Candidate(f.Photo(20))]; using var model = f.Model();
        await model.TickAsync(f.Context(photos) with { Preview = photos[0] }, Now);
        Assert.Equal(2, Assert.Single(f.Generated).UnitId); Assert.Empty(f.ReadSpaces);
    }
    [Fact]
    public async Task CurrentPhotoThenNextBeforePreviousWithinSameTier()
    {
        var f = new Repository(); var photos = Enumerable.Range(1, 8).Select(id => f.Photo(id)).ToArray();
        foreach (var photo in photos) f.VisibleCandidates[photo.Id.ItemId] = [f.Candidate(photo)]; using var model = f.Model();
        var context = f.Context(photos) with { Preview = photos[3] };
        await model.TickAsync(context, Now); await model.TickAsync(context, Now.AddSeconds(1));
        Assert.Equal(new long[] { 4, 5 }, f.Generated.Select(value => value.UnitId));
    }
    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task LiveVideoIsEligibleOnlyForCurrentPreview(bool current)
    {
        var f = new Repository(); var photos = new[] { f.Photo(1), f.Photo(2, "live") };
        f.VisibleCandidates[2] = [f.Candidate(photos[1]) with { UnitId = 22, TypeCode = 1, NeedsVideo = true, Priority = SynologyPhotoAutomaticPriority.HevcOrLiveVideo }];
        using var model = f.Model(); await model.TickAsync(f.Context(photos) with { Preview = photos[current ? 1 : 0] }, Now);
        Assert.Equal(current ? 1 : 0, f.Generated.Count);
    }
    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task SharedBackgroundRequiresManagement(bool management)
    {
        var f = new Repository(); f.Background[SynologyPhotoSpace.Shared] = [f.Candidate(f.Photo(1) with { Id = new(f.ProfileId, SynologyPhotoSpace.Shared, 1) })];
        using var model = f.Model(); await model.TickAsync(f.Context([]) with { Spaces = [SynologyPhotoSpace.Shared], SelectedSpace = SynologyPhotoSpace.Shared, CanManageSharedSpace = management }, Now);
        Assert.Equal(management ? 1 : 0, f.Generated.Count); Assert.Equal(management ? 1 : 0, f.ReadSpaces.Count);
    }
    [Theory]
    [InlineData(SynologyPhotoChangeState.Completed)] [InlineData(SynologyPhotoChangeState.Failed)]
    public async Task SemanticUnitDedupSurvivesVisibleToBackgroundChanges(SynologyPhotoChangeState result)
    {
        var f = new Repository { Result = result }; var photo = f.Photo(1); f.VisibleCandidates[1] = [f.Candidate(photo) with { TypeCode = 1 }];
        f.Background[SynologyPhotoSpace.Personal] = [f.Candidate(photo) with { TypeCode = 8, SourcePhoto = null, Priority = SynologyPhotoAutomaticPriority.Background }];
        using var model = f.Model(); await model.TickAsync(f.Context([photo]) with { Preview = photo }, Now);
        await model.TickAsync(f.Context([]), Now.AddSeconds(1)); Assert.Single(f.Generated);
        model.Resume(); await model.TickAsync(f.Context([]), Now.AddSeconds(2)); Assert.Equal(result == SynologyPhotoChangeState.Completed ? 1 : 2, f.Generated.Count);
    }
    [Fact]
    public async Task PendingReviewsContinueWhilePausedAndSettingsOpenWithBackoff()
    {
        var f = new Repository(); var pending = new SynologyPhotoAutomaticPreview(Guid.NewGuid(), f.Candidate(f.Photo(1)), SynologyPhotoChangeState.PendingReview, false); f.History.Add(pending);
        using var model = f.Model(); model.Pause(); model.SettingsVisible = true;
        foreach (var second in new[] { 0, 1, 4, 5, 14, 15, 34, 35, 74, 75, 134, 135 }) await model.TickAsync(f.Context([]), Now.AddSeconds(second));
        Assert.Equal(6, f.Reviews); Assert.Empty(f.Generated); Assert.True(model.HasPending);
        f.ReviewCompletes = true; await model.TickAsync(f.Context([]), Now.AddSeconds(195)); Assert.False(model.HasPending); Assert.Equal(1, f.Applied);
    }
    [Fact]
    public async Task ChangedNasSwitchStopsNextLease()
    {
        var f = new Repository(); var photo = f.Photo(1); f.Background[SynologyPhotoSpace.Personal] = [f.Candidate(photo)];
        using var model = f.Model(); await model.RefreshSettingsAsync(); f.Enabled = false; await model.TickAsync(f.Context([]), Now);
        Assert.Empty(f.Generated); Assert.False(model.Enabled); Assert.Empty(f.ReadSpaces);
    }
    [Theory]
    [InlineData("hide")] [InlineData("manual")] [InlineData("pause")]
    public async Task UserInteractionCancelsWorkAndPreservesPendingResult(string action)
    {
        var f = new Repository(); var photo = f.Photo(1); f.Background[SynologyPhotoSpace.Personal] = [f.Candidate(photo)];
        var entered = new TaskCompletionSource(); f.Execute = async (id, candidate, token) =>
        { entered.SetResult(); try { await Task.Delay(Timeout.InfiniteTimeSpan, token); } catch (OperationCanceledException) { }
            return new(id, candidate, SynologyPhotoChangeState.PendingReview, false); };
        using var model = f.Model(); var task = model.TickAsync(f.Context([]), Now); await entered.Task;
        if (action == "hide") model.SetActive(false); if (action == "manual") model.SetInteractionBusy(true); if (action == "pause") model.Pause();
        await task; Assert.True(model.HasPending); Assert.False(model.IsRunning); Assert.Single(f.Generated);
    }
    [Fact]
    public async Task SettingsUnknownDisablesNewLeasesButReviewsWhilePaused()
    {
        var f = new Repository { SettingsUnknown = true }; using var model = f.Model(); await model.RefreshSettingsAsync();
        await model.SetEnabledAsync(false); Assert.NotNull(model.PendingSetting); Assert.False(model.CanChangeSetting);
        model.Pause(); model.SettingsVisible = true; await model.TickAsync(f.Context([]), Now); Assert.Equal(1, f.SettingsReviews); Assert.Empty(f.Generated);
        f.SettingsUnknown = false; f.Enabled = false; await model.TickAsync(f.Context([]), Now.AddSeconds(5)); Assert.Null(model.PendingSetting); Assert.False(model.Enabled);
    }
    [Fact]
    public async Task EmptyQueueAndDisabledCodecsDoNotReportCompletionOrErrors()
    {
        var f = new Repository { Support = new(false, false, false) }; using var model = f.Model(); await model.TickAsync(f.Context([]), Now);
        Assert.Empty(f.ReadSpaces); Assert.Empty(f.Generated); Assert.False(model.ShowsStatus); Assert.Null(model.ErrorKey);
    }
    [Fact]
    public async Task MissingSwitchDoesNotBlockColdReadonlyReview()
    {
        var f = new Repository { SettingReadFails = true }; f.History.Add(new(Guid.NewGuid(), f.Candidate(f.Photo(1)), SynologyPhotoChangeState.PendingReview, false));
        using var model = f.Model(); model.Pause(); await model.TickAsync(f.Context([]), Now); await model.TickAsync(f.Context([]), Now.AddSeconds(1));
        Assert.Equal(1, f.Reviews); Assert.True(model.HasPending); Assert.Empty(f.Generated); Assert.False(model.CanChangeSetting);
    }
    [Fact]
    public async Task YieldWaitsForConversionToFinishCancellationBeforeManualWork()
    {
        var f = new Repository(); f.Background[SynologyPhotoSpace.Personal] = [f.Candidate(f.Photo(1))];
        var entered = new TaskCompletionSource(); var cancelled = new TaskCompletionSource(); var cleanup = new TaskCompletionSource();
        f.Execute = async (id, candidate, token) =>
        {
            entered.SetResult(); try { await Task.Delay(Timeout.InfiniteTimeSpan, token); } catch (OperationCanceledException) { cancelled.SetResult(); }
            await cleanup.Task; return new(id, candidate, SynologyPhotoChangeState.Cancelled, false);
        };
        using var model = f.Model(); var cycle = model.TickAsync(f.Context([]), Now); await entered.Task;
        model.SetInteractionBusy(true); var yielding = model.YieldAsync(); await cancelled.Task; Assert.False(yielding.IsCompleted);
        cleanup.SetResult(); await yielding; await cycle; Assert.False(model.HasPending); Assert.False(model.IsRunning);
        await model.TickAsync(f.Context([]), Now.AddSeconds(1)); Assert.Single(f.Generated);
    }
    [Fact]
    public async Task ReopeningSettingsRechecksInstalledCodecSupport()
    {
        var f = new Repository { Support = new(false, false, false) }; using var model = f.Model(); await model.RefreshSettingsAsync();
        Assert.False(model.Support.Available); f.Support = new(true, false, true); await model.RefreshSettingsAsync(); Assert.True(model.Support.Available);
    }
    private sealed class Repository : ISynologyPhotosRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid(); public bool SupportsManagement => true;
        internal bool Enabled = true, ReviewCompletes, SettingsUnknown, SettingReadFails; internal int Reviews, Applied, SettingsReviews;
        internal SynologyPhotoConversionSupport Support = new(true, true, true);
        internal SynologyPhotoChangeState Result = SynologyPhotoChangeState.Completed;
        internal readonly Dictionary<long, SynologyPhotoAutomaticCandidate[]> VisibleCandidates = [];
        internal readonly Dictionary<SynologyPhotoSpace, SynologyPhotoAutomaticCandidate[]> Background = [];
        internal readonly List<long> ReadPhotos = []; internal readonly List<SynologyPhotoSpace> ReadSpaces = [];
        internal readonly List<SynologyPhotoAutomaticCandidate> Generated = []; internal readonly List<SynologyPhotoAutomaticPreview> History = [];
        internal SynologyPhotoSettingsChange? Setting;
        internal Func<Guid, SynologyPhotoAutomaticCandidate, CancellationToken, Task<SynologyPhotoAutomaticPreview>>? Execute;
        internal SynologyPhoto Photo(long id, string type = "photo") => new(new(ProfileId, SynologyPhotoSpace.Personal, id), $"synthetic-{id}.jpg", 8, Now, Now, 3, type) { Thumbnail = new(id, "synthetic") };
        internal SynologyPhotoAutomaticCandidate Candidate(SynologyPhoto photo, SynologyPhotoAutomaticPriority priority = SynologyPhotoAutomaticPriority.Standard) => new(ProfileId, photo.Id.Space, photo.Thumbnail!.UnitId, photo.Filename, 0, true, false, photo, priority);
        internal SynologyPhotoAutomaticContext Context(IReadOnlyList<SynologyPhoto> photos) => new(SynologyPhotoSpace.Personal, [SynologyPhotoSpace.Personal], false, photos, null, photos, false, true);
        internal SynologyPhotoAutomaticModel Model() { var model = new SynologyPhotoAutomaticModel(this, _ => { Applied++; return Task.CompletedTask; }); model.SetActive(true); return model; }
        public bool SupportsAutomaticPreview(SynologyPhotoSpace space) => true;
        public Task<SynologyPhotoConversionSupport> PreviewConversionSupportAsync(CancellationToken cancellationToken = default) => Task.FromResult(Support);
        public Task<bool> AutomaticPreviewEnabledAsync(CancellationToken cancellationToken = default) => SettingReadFails ? Task.FromException<bool>(new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse)) : Task.FromResult(Enabled);
        public Task<IReadOnlyList<SynologyPhotoAutomaticPreview>> AutomaticPreviewsAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<SynologyPhotoAutomaticPreview>>(History.ToArray());
        public Task<IReadOnlyList<SynologyPhotoAutomaticCandidate>> AutomaticPreviewCandidatesAsync(SynologyPhoto photo, SynologyPhotoConversionSupport support, CancellationToken cancellationToken = default)
        { ReadPhotos.Add(photo.Id.ItemId); return Task.FromResult<IReadOnlyList<SynologyPhotoAutomaticCandidate>>(VisibleCandidates.GetValueOrDefault(photo.Id.ItemId) ?? []); }
        public Task<IReadOnlyList<SynologyPhotoAutomaticCandidate>> AutomaticPreviewCandidatesAsync(SynologyPhotoSpace space, SynologyPhotoConversionSupport support, CancellationToken cancellationToken = default)
        { ReadSpaces.Add(space); return Task.FromResult<IReadOnlyList<SynologyPhotoAutomaticCandidate>>(Background.GetValueOrDefault(space) ?? []); }
        public async Task<SynologyPhotoAutomaticPreview> GenerateAutomaticPreviewAsync(Guid operationId, SynologyPhotoAutomaticCandidate candidate, SynologyPhotoConversionSupport support, CancellationToken cancellationToken = default)
        { Generated.Add(candidate); var result = Execute is not null ? await Execute(operationId, candidate, cancellationToken) : new(operationId, candidate, Result, false); History.Add(result); return result; }
        public Task<SynologyPhotoAutomaticPreview> ReviewAutomaticPreviewAsync(Guid operationId, CancellationToken cancellationToken = default)
        { Reviews++; return Task.FromResult(History.Single(value => value.Id == operationId) with { State = ReviewCompletes ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.PendingReview }); }
        public Task<SynologyPhotoSettingsChange> SetAutomaticPreviewAsync(Guid operationId, bool original, bool enabled, CancellationToken cancellationToken = default)
        { if (!SettingsUnknown) Enabled = enabled; Setting = new(operationId, new(original, enabled), SettingsUnknown ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Completed, false); return Task.FromResult(Setting); }
        public Task<IReadOnlyList<SynologyPhotoSettingsChange>> SettingsChangesAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<SynologyPhotoSettingsChange>>(Setting is not null ? [Setting] : []);
        public Task<SynologyPhotoSettingsChange> ReviewSettingsChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
        { SettingsReviews++; return Task.FromResult(Setting! with { State = SettingsUnknown ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Completed }); }
        public Task<SynologyPhotoAccess> AccessAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<IReadOnlyList<SynologyPhotoDay>> TimelineAsync(SynologyPhotoQuery? query = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<SynologyPhotoPage> PhotosAsync(SynologyPhotoQuery query, int offset, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
