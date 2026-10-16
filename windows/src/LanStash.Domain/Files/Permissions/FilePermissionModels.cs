namespace LanStash.Domain;

[Flags]
public enum FileAclRights
{
    None = 0, ReadData = 1, WriteData = 2, Execute = 4, Append = 8, Delete = 16, DeleteChildren = 32,
    ReadAttributes = 64, WriteAttributes = 128, ReadExtendedAttributes = 256, WriteExtendedAttributes = 512,
    ReadPermissions = 1024, ChangePermissions = 2048, TakeOwnership = 4096,
}

[Flags]
public enum FileAclInheritance { None = 0, ChildFiles = 1, ChildFolders = 2, ThisFolder = 4, AllDescendants = 8 }
public enum FileAclEffect { Allow, Deny }

public sealed record FileAclRule(string OwnerType, string OwnerName, long? OwnerId, bool? IsInternal,
    FileAclEffect Effect, FileAclRights Rights, FileAclInheritance Inheritance, int Level = 0)
{
    public override string ToString() => "FileAclRule(redacted)";
}

public sealed record FilePermissionOwner(string Name, string Type, string Value, bool CanChange)
{
    public override string ToString() => "FilePermissionOwner(redacted)";
}

/// <summary>真实路径仅用于当前会话中的映射核对，不写日志或持久化。</summary>
public sealed record FilePermissionSnapshot(string Scope, FileItem Target, string ResolvedPath, string? Group,
    string? MountPointType, bool IsAcl, bool CanChangePermissions, bool IsAdministrator, bool IsInherited,
    IReadOnlyList<FileAclRule> Rules, FilePermissionOwner? Owner, string? PosixMode)
{
    public string ActingAccount { get; init; } = "";
    public override string ToString() => "FilePermissionSnapshot(redacted)";
}

public sealed record FilePermissionChange(FilePermissionSnapshot Baseline,
    IReadOnlyList<FileAclRule>? ExplicitRules = null, string? PosixMode = null,
    FileSharePrincipal? Owner = null, FileSharePrincipal? Group = null, bool Recursive = false,
    bool ConfirmedScope = false, bool ConfirmedOwner = false, bool ConfirmedAccessRemoval = false)
{
    public override string ToString() => "FilePermissionChange(redacted)";
}

public sealed record FilePermissionProgress(MutationResult Outcome, int ErrorCount = 0, bool HasPartialFailure = false);

public interface IFilePermissionRepository
{
    Guid ProfileId { get; }
    Task<FilePermissionSnapshot> LoadFilePermissionsAsync(string path, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<FileSharePrincipal>> ListFileSharePrincipalsAsync(string prefix, CancellationToken cancellationToken = default);
    Task<FilePermissionProgress> ChangeFilePermissionsAsync(FilePermissionChange change, CancellationToken cancellationToken = default);
    Task<FilePermissionProgress?> ReviewFilePermissionsAsync(string path, CancellationToken cancellationToken = default);
}
