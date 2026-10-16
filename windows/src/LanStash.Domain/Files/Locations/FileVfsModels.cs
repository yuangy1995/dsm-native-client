namespace LanStash.Domain;

public enum FileVfsState { Unknown, Disconnected, Connected }
public enum FileVfsAction { Create, Update, Connect, Disconnect, RemoveSavedProfile, CreateCloud, Reauthorize }
public enum FileVfsNotice { None, IdentityWarning, Partial, SecureConnectionRequired, AuthorizationMismatch }

public sealed record FileVfsProtocol(string Id, string Name, int? DefaultPort, bool HasConnections)
{
    public bool SupportsServerSetup => Id is "ftp" or "sftp" or "dav" or "davs";
    public bool SupportsCloudAuthorization => Id is "google" or "dropbox" or "baidu" or "onedrive" or "box";
}

public sealed record FileVfsProfile(Guid ProfileId, string Id, string Protocol, string ProtocolName, string Uri,
    string? Hostname, int? Port, string Alias, string? Account, string? Codepage, FileVfsState State)
{
    public override string ToString() => nameof(FileVfsProfile);
}

// 密码和云授权令牌不属于配置、操作身份或恢复记录。
public sealed record FileVfsConfiguration(string Protocol, string Hostname, int Port, string Alias, string Account,
    string Codepage = "UTF-8", string Folder = "", bool UsesOneConnection = false)
{
    public bool UsesCleartext => Protocol is "ftp" or "dav";
    public FileVfsConfiguration Normalize() => this with
    { Hostname = Hostname.Trim(), Folder = Protocol is "dav" or "davs" ? Folder.TrimStart('/') : Folder };
    public bool IsValid => Protocol is "ftp" or "sftp" or "dav" or "davs" && Port is > 0 and <= 65535 &&
        Hostname.Length > 0 && !Hostname.Any(c => char.IsWhiteSpace(c) || char.IsControl(c) || "/@?#\\".Contains(c)) &&
        !string.IsNullOrWhiteSpace(Alias) && Alias.Length <= 255 && !string.IsNullOrWhiteSpace(Codepage) &&
        !new[] { Alias, Account, Codepage, Folder }.Any(s => s.Any(char.IsControl));
    public override string ToString() => nameof(FileVfsConfiguration);
}

public sealed record FileVfsDetail(FileVfsProfile Profile, FileVfsConfiguration Configuration)
{
    public override string ToString() => nameof(FileVfsDetail);
}

public sealed record FileVfsChange(Guid ProfileId, Guid RequestId, FileVfsAction Action,
    FileVfsProfile? Existing = null, FileVfsDetail? Baseline = null, FileVfsConfiguration? Configuration = null,
    bool Confirmed = false, bool ConfirmedCleartext = false, FileVfsCloudIdentity? CloudIdentity = null)
{
    public override string ToString() => nameof(FileVfsChange);
}

public sealed record FileVfsProgress(FileVfsChange Change, MutationResult Outcome, FileVfsNotice Notice = FileVfsNotice.None)
{
    public override string ToString() => nameof(FileVfsProgress);
}

public interface IFileVfsRepository
{
    Guid ProfileId { get; }
    bool CanManageVfs { get; }
    Task<IReadOnlyList<FileVfsProtocol>> ListVfsProtocolsAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<FileVfsProfile>> ListVfsProfilesAsync(CancellationToken cancellationToken = default);
    Task<FileVfsDetail> LoadVfsDetailAsync(FileVfsProfile profile, CancellationToken cancellationToken = default);
    Task<FileVfsProgress> ChangeVfsAsync(FileVfsChange change, string? replacementPassword, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<FileVfsProgress>> GetVfsOperationsAsync(CancellationToken cancellationToken = default);
    Task<FileVfsProgress?> ReviewVfsAsync(Guid requestId, CancellationToken cancellationToken = default);
}
