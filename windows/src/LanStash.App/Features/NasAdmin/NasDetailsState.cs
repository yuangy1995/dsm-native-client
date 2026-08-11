using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public enum NasDetailsSectionKind
{
    SystemOverview,
    StorageHealth,
    Packages,
    ScheduledTasks,
    Logs,
    Connections,
}

public enum NasDetailsContentState
{
    Loading,
    Content,
    Empty,
    Error,
    Unavailable,
}

public sealed record NasDetailsSectionOption(
    NasDetailsSectionKind Kind,
    string Title,
    string Status,
    string AutomationName);

public sealed record NasDetailsRow(
    string Id,
    string Title,
    string Detail,
    string Status,
    string Glyph,
    string AutomationName);

internal sealed class NasDetailsProfileState
{
    public NasDetailsSnapshot? Snapshot { get; set; }
    public NasDetailsSectionKind SelectedSection { get; set; } = NasDetailsSectionKind.SystemOverview;
    public bool Loaded { get; set; }
}
