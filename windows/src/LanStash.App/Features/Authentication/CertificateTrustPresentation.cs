using LanStash.Domain;

namespace LanStash.App.Features.Authentication;

internal enum CertificateTrustRetryKind
{
    Connect,
    Restore,
}

internal sealed record CertificateTrustPresentation(
    Guid Id,
    Guid AttemptId,
    Guid ProfileId,
    string ProfileDisplayName,
    string SubmittedHost,
    CertificateTrustChallenge Challenge,
    CertificateTrustRetryKind RetryKind);
