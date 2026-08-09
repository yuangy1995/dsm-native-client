namespace LanStash.Domain;

public interface ICertificatePinStore
{
    Task<CertificateFingerprint?> LoadAsync(
        Guid profileId,
        CancellationToken cancellationToken = default);

    Task SaveAsync(
        Guid profileId,
        CertificateFingerprint fingerprint,
        CancellationToken cancellationToken = default);

    Task RemoveAsync(
        Guid profileId,
        CancellationToken cancellationToken = default);
}
