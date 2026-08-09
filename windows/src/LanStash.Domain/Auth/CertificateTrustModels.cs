namespace LanStash.Domain;

public enum DsmConnectionSource
{
    DirectAddress,
    QuickConnectLan,
    QuickConnectExternal,
    QuickConnectRelay,
}

public enum CertificateTrustChallengeKind
{
    FirstUntrustedCertificate,
    CertificateChanged,
    InvalidCertificate,
}

public enum CertificateTrustDecision
{
    UseSystemTrust,
    UsePinnedCertificate,
    ReviewFirstCertificate,
    ReviewChangedCertificate,
    RejectInvalidCertificate,
}

public sealed class CertificateFingerprint : IEquatable<CertificateFingerprint>
{
    public string Sha256 { get; }

    public CertificateFingerprint(string sha256)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sha256);
        var normalized = sha256.Replace(":", string.Empty, StringComparison.Ordinal)
            .ToUpperInvariant();
        if (normalized.Length != 64 || normalized.Any(character =>
                !((character >= '0' && character <= '9') ||
                    (character >= 'A' && character <= 'F'))))
        {
            throw new ArgumentException(
                "certificate.invalid_fingerprint",
                nameof(sha256));
        }
        Sha256 = normalized;
    }

    public string Formatted => string.Join(
        ":",
        Enumerable.Range(0, Sha256.Length / 2)
            .Select(index => Sha256.Substring(index * 2, 2)));

    public bool Equals(CertificateFingerprint? other) =>
        other is not null &&
        string.Equals(Sha256, other.Sha256, StringComparison.Ordinal);

    public override bool Equals(object? obj) =>
        obj is CertificateFingerprint other && Equals(other);

    public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Sha256);

    public override string ToString() => nameof(CertificateFingerprint);
}

public sealed record CertificateTrustChallenge(
    Guid ProfileId,
    CertificateTrustChallengeKind Kind,
    DsmConnectionSource ConnectionSource,
    string SubjectSummary,
    CertificateFingerprint PresentedFingerprint,
    CertificateFingerprint? PreviouslyPinnedFingerprint,
    bool CanApprove)
{
    public override string ToString() => nameof(CertificateTrustChallenge);
}

public sealed class CertificateTrustChallengeException(
    CertificateTrustChallenge challenge) : Exception(
        "certificate.trust_review_required")
{
    public CertificateTrustChallenge Challenge { get; } = challenge;
}

public static class CertificateTrustPolicy
{
    public static CertificateTrustDecision Decide(
        bool systemTrusted,
        CertificateFingerprint? pinnedFingerprint,
        CertificateFingerprint presentedFingerprint,
        bool canBePinned,
        bool requiresSystemTrust)
    {
        ArgumentNullException.ThrowIfNull(presentedFingerprint);
        if (requiresSystemTrust)
        {
            return systemTrusted
                ? CertificateTrustDecision.UseSystemTrust
                : CertificateTrustDecision.RejectInvalidCertificate;
        }
        if (pinnedFingerprint is not null &&
            !pinnedFingerprint.Equals(presentedFingerprint))
        {
            return CertificateTrustDecision.ReviewChangedCertificate;
        }
        if (systemTrusted)
        {
            return CertificateTrustDecision.UseSystemTrust;
        }
        if (pinnedFingerprint?.Equals(presentedFingerprint) == true && canBePinned)
        {
            return CertificateTrustDecision.UsePinnedCertificate;
        }
        return canBePinned
            ? CertificateTrustDecision.ReviewFirstCertificate
            : CertificateTrustDecision.RejectInvalidCertificate;
    }
}
