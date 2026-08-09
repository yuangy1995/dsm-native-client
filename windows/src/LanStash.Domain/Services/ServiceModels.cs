namespace LanStash.Domain;

public enum ResourceState
{
    Running,
    Stopped,
    Paused,
    Waiting,
    Healthy,
    Warning,
    Error,
    Unknown,
}

public sealed record ResourceItem(
    string Id,
    string Name,
    string Detail,
    ResourceState State,
    IReadOnlyDictionary<string, string>? Metadata = null);

public sealed record LogEntry(
    string Id,
    string Level,
    DateTimeOffset? Time,
    string User,
    string Event);
