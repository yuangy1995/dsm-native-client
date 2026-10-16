using System.Text.Json.Serialization;

namespace LanStash.Domain;

public sealed record FileVfsCloudIdentity(string Protocol, string Alias, string Account)
{
    public bool IsValid => new FileVfsProtocol(Protocol, "", null, false).SupportsCloudAuthorization &&
        !string.IsNullOrWhiteSpace(Alias) && Alias.Length <= 255 && !string.IsNullOrEmpty(Account) &&
        !Alias.Any(char.IsControl) && !Account.Any(char.IsControl);
    public override string ToString() => nameof(FileVfsCloudIdentity);
}

public sealed record FileVfsCloudRequest(Guid RequestId, Guid ProfileId, string Protocol, Uri LoginUri,
    DateTimeOffset ExpiresAt, FileVfsProfile? Existing = null)
{
    public override string ToString() => nameof(FileVfsCloudRequest);
}

// 仅用于一次授权及当前提交；秘密不序列化、不进入操作登记，结束后清空引用。
public sealed class FileVfsCloudAuthorization(Guid requestId, Guid profileId, string protocol, string account,
    string accessToken, string? clientId = null, string? refreshToken = null, long? expiresIn = null) : IDisposable
{
    public Guid RequestId { get; } = requestId;
    public Guid ProfileId { get; } = profileId;
    public string Protocol { get; } = protocol;
    [JsonIgnore] public string Account { get; } = account;
    [JsonIgnore] public string AccessToken { get; private set; } = accessToken;
    [JsonIgnore] public string? ClientId { get; private set; } = clientId;
    [JsonIgnore] public string? RefreshToken { get; private set; } = refreshToken;
    [JsonIgnore] public long? ExpiresIn { get; } = expiresIn;
    public override string ToString() => nameof(FileVfsCloudAuthorization);
    public void Dispose() { AccessToken = ""; ClientId = RefreshToken = null; }
}

public interface IFileVfsCloudRepository : IFileVfsRepository
{
    Task<FileVfsCloudRequest> PrepareVfsCloudAsync(string protocol, FileVfsProfile? existing = null, CancellationToken cancellationToken = default);
    void CancelVfsCloud(Guid requestId);
    Task<FileVfsProgress> AuthorizeVfsAsync(FileVfsChange change, FileVfsCloudAuthorization authorization, CancellationToken cancellationToken = default);
}
