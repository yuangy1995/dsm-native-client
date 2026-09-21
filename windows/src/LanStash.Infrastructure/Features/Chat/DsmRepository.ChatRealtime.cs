using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public IAsyncEnumerable<ChatRealtimeEvent> ObserveRealtimeAsync(CancellationToken cancellationToken = default)
    {
        EnsureReadableChatContract();
        return _api.ObserveChatRealtimeAsync(_profile, _session, cancellationToken);
    }
}
