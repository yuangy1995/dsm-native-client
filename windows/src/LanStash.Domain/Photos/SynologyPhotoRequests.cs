using System.Text.RegularExpressions;

namespace LanStash.Domain;

/// <summary>收集口令、目标路径和正文仅用于当前表单，不进入恢复记录。</summary>
public sealed record SynologyPhotoRequestSettings(string Subject, string Description, SynologyPhotoSpace Space, string FolderPath)
{
    public long? FolderId { get; init; }
    public long? AlbumId { get; init; }
    public string? AlbumPassphrase { get; init; }
    public long Expiration { get; init; }
    public long SizeLimit { get; init; }
    public static string DefaultFolderPath(string subject)
    {
        var name = subject.Trim();
        return name.Length == 0 ? "/PhotoRequest" : "/PhotoRequest/" + Regex.Replace(name,
            @"^\s*$|^\.|\.$|^@(?:database|eaDir|tmp|sharebin)$|^#(?:recycle|snapshot)$|[/\\:]", "_", RegexOptions.CultureInvariant);
    }
    public bool IsValid => !string.IsNullOrWhiteSpace(Subject) && Subject == Subject.Trim() && Subject.Length <= 50 &&
        Description.Length <= 100 && Enum.IsDefined(Space) && !string.IsNullOrEmpty(FolderPath) && FolderPath.StartsWith('/') &&
        !FolderPath.Contains('\0') && FolderId is not <= 0 && AlbumId is not <= 0 &&
        AlbumPassphrase is not "" && (AlbumPassphrase is null || AlbumId is null) && Expiration >= 0 &&
        (SizeLimit == 0 || SizeLimit is >= 1_048_576 and <= 3_145_728_000);
}
public sealed record SynologyPhotoRequest(Guid ProfileId, string Id, SynologyPhotoRequestSettings Settings,
    bool IsFolderValid, string? AlbumName = null, Uri? Url = null);
public sealed record SynologyPhotoRequestAlbum(long Id, long? AlbumId, string? Passphrase, string Name, bool Shared);
public enum SynologyPhotoRequestEditKind { Create, Update, Delete }
public sealed record SynologyPhotoRequestEdit(SynologyPhotoRequestEditKind Kind,
    SynologyPhotoRequestSettings? Settings = null, SynologyPhotoRequest? Original = null);
public sealed record SynologyPhotoRequestChange(Guid Id, SynologyPhotoRequestEditKind Kind, SynologyPhotoChangeState State,
    SynologyPhotoFailure? Failure, bool Running, bool CanContinue, bool NeedsInput, SynologyPhotoRequest? Result)
{
    public bool Pending => State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview;
}
