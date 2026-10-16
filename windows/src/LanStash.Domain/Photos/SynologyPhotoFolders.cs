namespace LanStash.Domain;

public enum SynologyPhotoSortField { TakenTime, Filename, FileSize, MediaType }
public sealed record SynologyPhotoSort(SynologyPhotoSortField Field = SynologyPhotoSortField.TakenTime, bool Descending = false);
public sealed record SynologyPhotoFolder(SynologyPhotoSpace Space, long Id, long ParentId, string Path)
{
    public bool IsRoot => Path == "/";
    public string Name => Path.TrimEnd('/').Split('/').Last();
    public SynologyPhotoSort? Sort { get; init; }
    public SynologyPhotoCollection Collection => new(Id, Name, ParentId) { Space = Space, Path = Path };
}
public enum SynologyPhotoFolderEditKind { Create, Rename, Sort, Cover }
/// <summary>固定目录身份和用户选择；恢复只核对，写入必须由用户明确发起。</summary>
public sealed record SynologyPhotoFolderEdit(SynologyPhotoFolderEditKind Kind, SynologyPhotoFolder Folder)
{
    public string? Name { get; init; }
    public SynologyPhotoSort? Sort { get; init; }
    public SynologyPhoto? Photo { get; init; }
    public static bool IsValidName(string? name, bool rename = true) => !string.IsNullOrWhiteSpace(name) && name.Length <= 255 && name is not ("." or "..") &&
        name.IndexOfAny(['/', '\\', '\0']) < 0 && (!rename || !name.StartsWith('.') && !name.EndsWith('.') && !name.Contains(':') &&
        !new[] { "@database", "@eaDir", "@tmp", "@sharebin", "#recycle", "#snapshot" }.Contains(name, StringComparer.OrdinalIgnoreCase));
}
public sealed record SynologyPhotoFolderChange(Guid Id, SynologyPhotoFolderEdit Edit, SynologyPhotoChangeState State,
    SynologyPhotoFolder? Result, SynologyPhotoFailure? Failure, bool Running, bool CanContinue);
