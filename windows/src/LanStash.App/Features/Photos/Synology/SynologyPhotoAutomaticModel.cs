using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public sealed record SynologyPhotoAutomaticContext(SynologyPhotoSpace SelectedSpace, IReadOnlyList<SynologyPhotoSpace> Spaces,
    bool CanManageSharedSpace, IReadOnlyList<SynologyPhoto> Items, SynologyPhoto? Preview,
    IReadOnlyList<SynologyPhoto> PreviewItems, bool IsTimeline, bool IsComplete, bool Busy = false);

/// <summary>工作区持有的单项调度器；页面只报告可见范围和时钟，未知提交始终只读恢复。</summary>
public sealed class SynologyPhotoAutomaticModel(ISynologyPhotosRepository repository,
    Func<SynologyPhotoAutomaticPreview, Task>? apply = null) : ObservableObject, IDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly List<SynologyPhotoAutomaticCandidate> _finished = [], _failed = [];
    private readonly Dictionary<Guid, SynologyPhotoAutomaticPreview> _pending = [];
    private readonly Dictionary<Guid, (DateTimeOffset At, int Attempt)> _reviews = [];
    private readonly HashSet<SynologyPhotoIdentity> _visible = [];
    private CancellationTokenSource? _operation;
    private DateTimeOffset _nextVisible, _nextWork;
    private bool _initialized, _active, _disposed, _interactionBusy;
    public SynologyPhotoConversionSupport Support { get; private set; } = new(false, false, false);
    public bool? Enabled { get; private set; }
    public bool Paused { get; private set; }
    public bool IsRunning { get; private set; }
    public bool IsSaving { get; private set; }
    public bool SettingsVisible { get; set; }
    public string? Filename { get; private set; }
    public string? ErrorKey { get; private set; }
    public SynologyPhotoSettingsChange? PendingSetting { get; private set; }
    public bool HasPending => _pending.Count > 0;
    public bool ShowsStatus => Filename is not null || HasPending || PendingSetting is not null || Enabled == true && (Paused || ErrorKey is not null);
    public bool CanChangeSetting => _initialized && Enabled is not null && !IsSaving && PendingSetting is null && !_disposed;
    public void SetActive(bool active)
    {
        _active = active; if (!active) { _operation?.Cancel(); _visible.Clear(); } Changed();
    }
    public void SetInteractionBusy(bool busy)
    { _interactionBusy = busy; if (busy) _operation?.Cancel(); }
    public async Task YieldAsync()
    { _operation?.Cancel(); await _gate.WaitAsync(); _gate.Release(); }
    public void SetVisible(IEnumerable<SynologyPhotoIdentity> visible, DateTimeOffset now)
    {
        var next = visible.Where(id => id.ProfileId == repository.ProfileId).ToHashSet();
        if (_visible.SetEquals(next)) return;
        _visible.Clear(); _visible.UnionWith(next); _nextVisible = now.AddSeconds(2);
        if (_nextWork > _nextVisible) _nextWork = _nextVisible;
    }
    public void Pause() { Paused = true; _operation?.Cancel(); Changed(); }
    public void Resume() { _failed.Clear(); ErrorKey = null; Paused = false; _nextWork = DateTimeOffset.MinValue; Changed(); }

    public static IReadOnlyList<SynologyPhoto> Neighbors(SynologyPhotoAutomaticContext context)
    {
        if (context.Preview is not { } photo) return [];
        var items = context.PreviewItems; var index = items.ToList().FindIndex(item => item.Id == photo.Id); if (index < 0) return [];
        SynologyPhoto? Neighbor(int offset, bool wraps)
        {
            var position = index + offset;
            if (position >= 0 && position < items.Count) return items[position];
            return wraps && context.IsComplete ? items[(position % items.Count + items.Count) % items.Count] : null;
        }
        var previous = new[] { -2, -1 }.Select(offset => Neighbor(offset, !context.IsTimeline)).OfType<SynologyPhoto>().ToList();
        var next = new[] { 1, 2, 3 }.Select(offset => Neighbor(offset, true)).OfType<SynologyPhoto>().ToList();
        var count = previous.Append(photo).Concat(next).DistinctBy(item => item.Id).Count();
        if (count < 4) next = next.Take(1).ToList(); else if (count == 4 && next.Count > 0) next.RemoveAt(next.Count - 1);
        if (count < 6) previous = previous.TakeLast(1).ToList();
        return next.Concat(previous).Where(item => item.Id != photo.Id && item.MediaType is not ("video" or "video360")).ToArray();
    }
    private async Task InitializeAsync(CancellationToken token)
    {
        if (_initialized) return;
        foreach (var value in await repository.AutomaticPreviewsAsync(token))
        {
            if (value.Pending || value.Running) _pending[value.Id] = value;
            else if (value.State == SynologyPhotoChangeState.Failed) _failed.Add(value.Candidate);
        }
        PendingSetting = (await repository.SettingsChangesAsync(token)).SingleOrDefault(value => value.Pending && value.Automatic is not null);
        _initialized = true;
        Support = await repository.PreviewConversionSupportAsync(token);
        Enabled = await repository.AutomaticPreviewEnabledAsync(token); token.ThrowIfCancellationRequested(); Changed();
    }
    public async Task RefreshSettingsAsync()
    {
        if (_disposed || !repository.SupportsManagement) return;
        _operation?.Cancel(); await _gate.WaitAsync();
        try { await InitializeAsync(CancellationToken.None); Support = await repository.PreviewConversionSupportAsync(); Enabled = await repository.AutomaticPreviewEnabledAsync(); ErrorKey = null; }
        catch (Exception error) { ErrorKey = Error(error); }
        finally { _gate.Release(); Changed(); }
    }
    public async Task SetEnabledAsync(bool enabled)
    {
        if (!CanChangeSetting) return;
        IsSaving = true; _operation?.Cancel(); Changed(); await _gate.WaitAsync();
        try
        {
            if (_disposed || Enabled is not { } original || PendingSetting is not null) return;
            var result = await repository.SetAutomaticPreviewAsync(Guid.NewGuid(), original, enabled);
            if (result.Pending) PendingSetting = result;
            else if (result.State == SynologyPhotoChangeState.Completed) { Enabled = enabled; ErrorKey = null; }
            else ErrorKey = "PhotosAutomaticSettingFailed";
        }
        catch (Exception error)
        {
            ErrorKey = Error(error);
            try { PendingSetting = (await repository.SettingsChangesAsync()).SingleOrDefault(value => value.Pending && value.Automatic is not null); } catch { }
        }
        finally { IsSaving = false; _gate.Release(); Changed(); }
    }
    public async Task TickAsync(SynologyPhotoAutomaticContext context, DateTimeOffset now)
    {
        if (_disposed || !_active || _interactionBusy || context.Busy || !repository.SupportsManagement || IsSaving || !await _gate.WaitAsync(0)) return;
        using var operation = new CancellationTokenSource(); _operation = operation; var token = operation.Token;
        try
        {
            await InitializeAsync(token);
            if (PendingSetting is { } setting)
            {
                if (ReviewDue(setting.Id, now))
                {
                    var result = await repository.ReviewSettingsChangeAsync(setting.Id, token);
                    if (!result.Pending) { PendingSetting = null; _reviews.Remove(setting.Id); Enabled = await repository.AutomaticPreviewEnabledAsync(token); }
                }
                return;
            }
            if (_pending.Count > 0)
            {
                foreach (var pending in _pending.Values.ToArray())
                    if (ReviewDue(pending.Id, now)) await ApplyAsync(await repository.ReviewAutomaticPreviewAsync(pending.Id, token), now);
                return;
            }
            if (Enabled is null && now >= _nextWork)
            {
                _nextWork = now.AddSeconds(5); Support = await repository.PreviewConversionSupportAsync(token);
                Enabled = await repository.AutomaticPreviewEnabledAsync(token);
            }
            if (Paused || SettingsVisible || Enabled != true || !Support.Available || now < _nextWork) return;
            _nextWork = now.AddSeconds(5);
            if (_nextVisible > now && _nextVisible < _nextWork) _nextWork = _nextVisible;
            Enabled = await repository.AutomaticPreviewEnabledAsync(token);
            if (Enabled != true || Paused || SettingsVisible) return;
            var candidates = new List<SynologyPhotoAutomaticCandidate>();
            if (now >= _nextVisible)
            {
                var photos = (context.Preview is { } preview ? new[] { preview }.Concat(Neighbors(context)) : [])
                    .Concat(context.Items.Concat(context.PreviewItems).Where(photo => _visible.Contains(photo.Id))).DistinctBy(photo => photo.Id);
                foreach (var photo in photos)
                {
                    if (!repository.SupportsAutomaticPreview(photo.Id.Space)) continue;
                    try
                    {
                        candidates.AddRange((await repository.AutomaticPreviewCandidatesAsync(photo, Support, token)).Where(candidate => Eligible(candidate) &&
                            (photo.MediaType != "live" || photo.Id == context.Preview?.Id || candidate.TypeCode == 0)));
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception error) { ErrorKey = Error(error); }
                    if (candidates.Any(candidate => candidate.Priority == SynologyPhotoAutomaticPriority.Standard)) break;
                }
            }
            foreach (var space in new[] { context.SelectedSpace }.Concat(context.Spaces).Distinct())
            {
                if (candidates.Count > 0) break;
                if (!context.Spaces.Contains(space) || space == SynologyPhotoSpace.Shared && !context.CanManageSharedSpace || !repository.SupportsAutomaticPreview(space)) continue;
                try { candidates.AddRange((await repository.AutomaticPreviewCandidatesAsync(space, Support, token)).Where(Eligible)); }
                catch (OperationCanceledException) { throw; }
                catch (Exception error) { ErrorKey = Error(error); }
            }
            var candidate = Preferred(context, candidates); token.ThrowIfCancellationRequested();
            if (candidate is null || Paused || SettingsVisible || _interactionBusy) return;
            Filename = candidate.Filename; IsRunning = true; Changed();
            try { await ApplyAsync(await repository.GenerateAutomaticPreviewAsync(Guid.NewGuid(), candidate, Support, token), now); }
            catch (Exception error)
            {
                foreach (var value in await repository.AutomaticPreviewsAsync()) if (value.Pending || value.Running) _pending[value.Id] = value;
                if (!token.IsCancellationRequested) { _failed.Add(candidate); ErrorKey = Error(error); }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) { ErrorKey = Error(error); }
        finally { Filename = null; IsRunning = false; _operation = null; _gate.Release(); Changed(); }
    }
    private bool Eligible(SynologyPhotoAutomaticCandidate candidate) => (candidate.NeedsThumbnail || candidate.NeedsVideo) &&
        !_finished.Concat(_failed).Any(candidate.SameUnit);
    private SynologyPhotoAutomaticCandidate? Preferred(SynologyPhotoAutomaticContext context, IReadOnlyList<SynologyPhotoAutomaticCandidate> candidates)
    {
        if (candidates.Count == 0) return null; var tier = candidates.Where(candidate => candidate.Priority == candidates.Min(value => value.Priority)).ToArray();
        var photos = (context.Preview is { } preview ? new[] { preview }.Concat(Neighbors(context)) : []).Concat(context.Items.Where(photo => _visible.Contains(photo.Id)));
        foreach (var photo in photos)
            if (tier.FirstOrDefault(candidate => candidate.Space == photo.Id.Space && candidate.ProfileId == photo.Id.ProfileId &&
                (candidate.SourcePhoto?.Id == photo.Id || candidate.UnitId == photo.Thumbnail?.UnitId)) is { } match) return match;
        return tier[0];
    }
    private bool ReviewDue(Guid id, DateTimeOffset now)
    {
        var previous = _reviews.GetValueOrDefault(id); if (now < previous.At) return false;
        _reviews[id] = (now.AddSeconds(Math.Min(60, 5 * Math.Pow(2, Math.Min(4, previous.Attempt)))), previous.Attempt + 1); return true;
    }
    private async Task ApplyAsync(SynologyPhotoAutomaticPreview result, DateTimeOffset now)
    {
        if (result.Pending || result.Running) { _pending[result.Id] = result; _reviews.TryAdd(result.Id, (now.AddSeconds(5), 0)); return; }
        _pending.Remove(result.Id); _reviews.Remove(result.Id);
        if (result.State == SynologyPhotoChangeState.Completed)
        {
            _finished.Add(result.Candidate); ErrorKey = null;
            if (!_disposed && apply is not null) await apply(result);
        }
        else if (result.State != SynologyPhotoChangeState.Cancelled)
        { _failed.Add(result.Candidate); ErrorKey = result.FailureRecorded ? "PhotosAutomaticFailureRecorded" : "PhotosAutomaticFailed"; }
        _nextWork = now.AddMilliseconds(100);
    }
    private static string Error(Exception error) => error is SynologyPhotoException { Failure: SynologyPhotoFailure.RecoveryUnavailable }
        ? "PhotosEditRecoveryUnavailable" : "PhotosAutomaticFailed";
    private void Changed() { if (!_disposed) RaisePropertyChanged(string.Empty); }
    public void Dispose() { _disposed = true; _active = false; _operation?.Cancel(); }
}
