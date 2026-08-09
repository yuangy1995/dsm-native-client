namespace LanStash.Domain;

public sealed record NasProfile(
    Guid Id,
    string DisplayName,
    string Host,
    int? Port,
    string Username,
    bool RememberSession = true,
    bool AutoLogin = false);

public sealed record DsmSession(
    Guid ProfileId,
    string Sid,
    string? SynoToken,
    string? DeviceId);

public interface ISecureSessionStore
{
    Task SaveAsync(DsmSession session, CancellationToken cancellationToken = default);
    Task<DsmSession?> LoadAsync(Guid profileId, CancellationToken cancellationToken = default);
    Task RemoveAsync(Guid profileId, CancellationToken cancellationToken = default);
}

public interface ISecurePasswordStore
{
    Task SaveAsync(Guid profileId, string password, CancellationToken cancellationToken = default);
    Task<string?> LoadAsync(Guid profileId, CancellationToken cancellationToken = default);
    Task RemoveAsync(Guid profileId, CancellationToken cancellationToken = default);
}
