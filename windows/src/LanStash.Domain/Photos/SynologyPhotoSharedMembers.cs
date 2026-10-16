namespace LanStash.Domain;

public sealed record SynologyPhotoSharedMember(SynologyPhotoShareRecipient Recipient, string Role, bool AutoBackup)
{
    public SynologyPhotoShareIdentity Id => Recipient.Id;
    public bool Protected => Id.Type == "group" && Recipient.Name == "administrators";
    public bool Editable => !Protected && Role is "entry" or "management";
    public SynologyPhotoSharedMember ChangingRole(string role) => Editable && role is "entry" or "management"
        ? this with { Role = role, AutoBackup = role == "management" || AutoBackup } : this;
}
public sealed record SynologyPhotoSharedMembers(Guid ProfileId, long AdministratorId, bool Enabled, IReadOnlyList<SynologyPhotoSharedMember> Members)
{
    public bool CanSave(IReadOnlyList<SynologyPhotoSharedMember> target, IReadOnlyList<SynologyPhotoShareRecipient> candidates, bool allowUnchanged = false)
    {
        if (!Enabled || Members.DistinctBy(x => x.Id).Count() != Members.Count || target.DistinctBy(x => x.Id).Count() != target.Count ||
            candidates.DistinctBy(x => x.Id).Count() != candidates.Count) return false;
        var before = Members.ToDictionary(x => x.Id); var after = target.ToDictionary(x => x.Id);
        if (!allowUnchanged && before.Count == after.Count && before.All(x => after.GetValueOrDefault(x.Key) == x.Value)) return false;
        if (Members.Any(x => !x.Editable && after.GetValueOrDefault(x.Id) != x)) return false;
        return target.All(x => before.TryGetValue(x.Id, out var original)
            ? x == original || original.Editable && x.Recipient == original.Recipient && ValidRole(x)
            : !x.Protected && candidates.Contains(x.Recipient) && ValidRole(x));
    }
    private static bool ValidRole(SynologyPhotoSharedMember value) => value.Role is "entry" or "management" && (value.Role != "management" || value.AutoBackup);
}
public enum SynologyPhotoFolderMemberRole { View, Download, Upload, Manage }
public sealed record SynologyPhotoMemberFolder(Guid ProfileId, SynologyPhotoShareIdentity Member, long RootId, long Id, long ParentId,
    string Name, int Depth, string Privacy, string? DirectRole, string Revision, string IdentityHash, string OtherPermissionsHash)
{
    public static string? RoleText(SynologyPhotoFolderMemberRole? role) => role?.ToString().ToLowerInvariant();
    public static int Level(string? role) => role switch { "view" => 0, "download" => 1, "upload" => 2, "manage" => 3, _ => -1 };
    public int PublicLevel => Privacy switch { "public-view" => 0, "public-download" => 1, _ => -1 };
    public bool Known => Privacy is "private" or "public-view" or "public-download" && (DirectRole is null || Level(DirectRole) >= 0);
    public int EffectiveLevel => Known ? Math.Max(Level(DirectRole), PublicLevel) : -1;
}
public sealed record SynologyPhotoMemberFolderBatch(bool Grant, SynologyPhotoFolderMemberRole Role)
{
    public string? Applying(string? current)
    {
        var level = SynologyPhotoMemberFolder.Level(current);
        return Grant ? level < (int)Role ? SynologyPhotoMemberFolder.RoleText(Role) : current
            : level >= (int)Role ? (int)Role == 0 ? null : SynologyPhotoMemberFolder.RoleText(Role - 1) : current;
    }
}
public sealed record SynologyPhotoMemberFolderChange(long FolderId, SynologyPhotoFolderMemberRole? Role);
public sealed record SynologyPhotoMemberFolderEdit(SynologyPhotoShareIdentity Member, IReadOnlyList<SynologyPhotoMemberFolder> Original,
    SynologyPhotoMemberFolderBatch? Batch = null, IReadOnlyList<SynologyPhotoMemberFolderChange>? Changes = null)
{
    public string? Expected(SynologyPhotoMemberFolder folder, bool includeChanges = true)
    {
        string? Own(SynologyPhotoMemberFolder value) => includeChanges && Changes?.FirstOrDefault(x => x.FolderId == value.Id) is { } change
            ? SynologyPhotoMemberFolder.RoleText(change.Role) : Batch is { } batch ? batch.Applying(value.DirectRole) : value.DirectRole;
        if (includeChanges && folder.Depth == 1 && Original.FirstOrDefault(x => x.Id == folder.ParentId) is { Privacy: "private", DirectRole: not null } parent && Own(parent) is null) return null;
        return Own(folder);
    }
    public bool CanEdit(SynologyPhotoMemberFolder folder) => folder.Known && (folder.Depth == 0 ||
        Original.FirstOrDefault(x => x.Id == folder.ParentId) is { Known: true } parent && (parent.PublicLevel >= 0 || Expected(parent) is not null));
    public bool CanSave => Original.Count > 0 && Original.DistinctBy(x => x.Id).Count() == Original.Count && Original.All(x => x.Member == Member) &&
        (Batch is null || Enum.IsDefined(Batch.Role) && Original.All(x => x.Known)) &&
        (Changes ?? []).DistinctBy(x => x.FolderId).Count() == (Changes?.Count ?? 0) &&
        (Changes ?? []).All(x => (x.Role is null || Enum.IsDefined(x.Role.Value)) && Original.FirstOrDefault(f => f.Id == x.FolderId) is { } folder && CanEdit(folder)) &&
        Original.Any(x => x.Known && Math.Max(SynologyPhotoMemberFolder.Level(Expected(x)), x.PublicLevel) != x.EffectiveLevel);
    /// <summary>连续批量以当前草稿为输入，折叠成最后一次批量及差异，不在编辑时写入 NAS。</summary>
    public SynologyPhotoMemberFolderEdit Applying(SynologyPhotoMemberFolderBatch batch)
    {
        var target = Original.ToDictionary(x => x.Id, x => batch.Applying(Expected(x)));
        var flattened = this with { Batch = batch, Changes = [] };
        return flattened with { Changes = Original.Where(x => target[x.Id] != flattened.Expected(x, false))
            .Select(x => new SynologyPhotoMemberFolderChange(x.Id, SynologyPhotoMemberFolder.Level(target[x.Id]) is var level && level >= 0 ? (SynologyPhotoFolderMemberRole)level : null)).ToArray() };
    }
}
