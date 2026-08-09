namespace LanStash.App.Features.Files.Sharing;

internal sealed class FileShareLinkReviewBlocker
{
    private readonly object _sync = new();
    private readonly HashSet<(Guid ProfileId, string Path)> _blocked = [];

    public static FileShareLinkReviewBlocker Current { get; } = new();

    public bool Contains(Guid profileId, string path)
    {
        lock (_sync)
        {
            return _blocked.Contains((profileId, path));
        }
    }

    public void Block(Guid profileId, string path)
    {
        lock (_sync)
        {
            _blocked.Add((profileId, path));
        }
    }
}
