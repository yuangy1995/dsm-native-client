namespace LanStash.App.Features.Settings;

public readonly record struct RegenerableCacheSummary(int ItemCount, long Bytes);

public readonly record struct RegenerableCacheClearResult(
    RegenerableCacheSummary Summary,
    int ClearedParticipants,
    int FailedParticipants)
{
    public bool IsComplete => FailedParticipants == 0;
}

public interface IRegenerableCacheParticipant
{
    string CacheId { get; }
    RegenerableCacheSummary Snapshot();
    Task ClearAsync(CancellationToken cancellationToken = default);
}

public sealed class RegenerableCacheCoordinator
{
    private readonly object _gate = new();
    private readonly Dictionary<string, IRegenerableCacheParticipant> _participants = [];

    public IDisposable Register(IRegenerableCacheParticipant participant)
    {
        ArgumentNullException.ThrowIfNull(participant);
        ArgumentException.ThrowIfNullOrWhiteSpace(participant.CacheId);
        lock (_gate)
        {
            _participants[participant.CacheId] = participant;
        }
        return new Registration(this, participant.CacheId, participant);
    }

    public RegenerableCacheSummary Snapshot()
    {
        IRegenerableCacheParticipant[] participants;
        lock (_gate)
        {
            participants = _participants.Values.ToArray();
        }
        return participants.Aggregate(
            new RegenerableCacheSummary(),
            (total, participant) =>
            {
                var current = participant.Snapshot();
                return new RegenerableCacheSummary(
                    checked(total.ItemCount + current.ItemCount),
                    checked(total.Bytes + current.Bytes));
            });
    }

    public async Task<RegenerableCacheClearResult> ClearAsync(
        CancellationToken cancellationToken = default)
    {
        IRegenerableCacheParticipant[] participants;
        lock (_gate)
        {
            participants = _participants.Values.ToArray();
        }
        var cleared = 0;
        var failed = 0;
        foreach (var participant in participants)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                await participant.ClearAsync(cancellationToken).ConfigureAwait(false);
                cleared++;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch
            {
                failed++;
            }
        }
        return new RegenerableCacheClearResult(Snapshot(), cleared, failed);
    }

    private void Unregister(string id, IRegenerableCacheParticipant participant)
    {
        lock (_gate)
        {
            if (_participants.TryGetValue(id, out var current) && ReferenceEquals(current, participant))
            {
                _participants.Remove(id);
            }
        }
    }

    private sealed class Registration(
        RegenerableCacheCoordinator owner,
        string id,
        IRegenerableCacheParticipant participant) : IDisposable
    {
        private RegenerableCacheCoordinator? _owner = owner;

        public void Dispose() =>
            Interlocked.Exchange(ref _owner, null)?.Unregister(id, participant);
    }
}
