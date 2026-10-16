namespace LanStash.Domain;

/// <summary>仅用于显示；任务内文件名不能拼接成可写 NAS 路径。</summary>
public sealed record DownloadTaskFile(string Name, long? Size, long? Downloaded, string? Priority);
/// <summary>地址只包含源站，不包含 Tracker passkey、用户信息或路径。</summary>
public sealed record DownloadTaskTracker(string Origin, string? Status, int? Seeds, int? Peers, int? NextUpdateSeconds);
public sealed record DownloadTaskPeer(string Address, string? Client, double? Progress, long? DownloadSpeed, long? UploadSpeed);
public sealed record DownloadTaskDetails(DownloadTask Task, string? Kind, string? Owner, long? CreatedAt,
    IReadOnlyList<DownloadTaskFile>? Files, IReadOnlyList<DownloadTaskTracker>? Trackers, IReadOnlyList<DownloadTaskPeer>? Peers);
public sealed record DownloadRssSite(int Id, string IdentityDigest, string Title, bool IsUpdating, long LastUpdate);
public sealed record DownloadRssFeed(string Id, string Title, long Size, long Time, string DownloadUri);
