namespace LanStash.Domain;

public enum NasDirectoryKind { User, Group }

public sealed record NasDirectoryEntry(NasDirectoryKind Kind, string Name, long? NumericId,
    string? Description, string? Email, bool? IsExpired, IReadOnlyList<string>? Groups,
    bool? EditAllowed, bool? DeleteAllowed)
{
    public bool IsCurrentAccount { get; init; }
    public bool CanEdit => EditAllowed == true;
    public bool CanDelete => DeleteAllowed == true && !IsCurrentAccount && !IsReserved(Kind, Name);
    public static bool IsReserved(NasDirectoryKind kind, string name) => kind == NasDirectoryKind.User
        ? name.Trim().ToLowerInvariant() is "admin" or "guest"
        : name.Trim().ToLowerInvariant() is "administrators" or "users" or "http";
}

// 无密码/会话字段，基线是用户确认时看到的完整目录项。
public sealed record NasDirectoryDeleteRequest(Guid ProfileId, NasDirectoryEntry Baseline, Guid RequestId, bool RiskConfirmed);
public enum NasDirectoryOperationKind { Delete, Create, Update }
public sealed record NasDirectoryRecoveryInfo(NasDirectoryKind Kind, string Name, NasDirectoryOperationKind Operation = NasDirectoryOperationKind.Delete);
public sealed record NasDirectoryValues(string Name, string Description, string? Email = null, bool? IsExpired = null, IReadOnlyList<string>? Groups = null)
{
    public override string ToString() => nameof(NasDirectoryValues);
}
public sealed record NasDirectorySaveRequest(Guid ProfileId, NasDirectoryKind Kind, NasDirectoryEntry? Baseline,
    NasDirectoryValues Desired, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(NasDirectorySaveRequest);
}
public sealed record NasDirectorySaveAvailability(bool CanSaveUsers, bool CanSaveGroups);
