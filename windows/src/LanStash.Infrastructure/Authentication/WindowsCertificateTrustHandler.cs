using System.Collections.Concurrent;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed class WindowsCertificateTrustHandler : DelegatingHandler
{
    private static readonly HttpRequestOptionsKey<DsmConnectionSource> SourceKey =
        new("LanStash.DsmConnectionSource");
    private static readonly HttpRequestOptionsKey<Guid> ProfileIdKey =
        new("LanStash.ProfileId");
    private readonly Guid _profileId;
    private readonly CertificateFingerprint? _pinnedFingerprint;
    private readonly ConcurrentDictionary<HttpRequestMessage, CertificateTrustChallenge>
        _pendingChallenges = new(ReferenceEqualityComparer.Instance);
    private int _requiresSystemTrust;
    private int _activeSource = (int)DsmConnectionSource.DirectAddress;

    public WindowsCertificateTrustHandler(
        Guid profileId,
        CertificateFingerprint? pinnedFingerprint = null,
        bool allowAutoRedirect = false)
    {
        _profileId = profileId;
        _pinnedFingerprint = pinnedFingerprint;
        InnerHandler = new HttpClientHandler
        {
            AllowAutoRedirect = allowAutoRedirect,
            ServerCertificateCustomValidationCallback = ValidateCertificate,
        };
    }

    internal static void SetConnectionContext(
        HttpRequestMessage request,
        Guid profileId,
        DsmConnectionSource source)
    {
        request.Options.Set(ProfileIdKey, profileId);
        request.Options.Set(SourceKey, source);
    }

    internal static bool TryGetConnectionContext(
        HttpRequestMessage request,
        out Guid profileId,
        out DsmConnectionSource source)
    {
        var hasProfile = request.Options.TryGetValue(ProfileIdKey, out profileId);
        var hasSource = request.Options.TryGetValue(SourceKey, out source);
        return hasProfile && hasSource;
    }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        try
        {
            return await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (HttpRequestException)
            when (_pendingChallenges.TryRemove(request, out var challenge))
        {
            throw new CertificateTrustChallengeException(challenge);
        }
        finally
        {
            _pendingChallenges.TryRemove(request, out _);
        }
    }

    private bool ValidateCertificate(
        HttpRequestMessage request,
        X509Certificate2? certificate,
        X509Chain? chain,
        SslPolicyErrors sslPolicyErrors)
    {
        var requestedSource = request.Options.TryGetValue(SourceKey, out DsmConnectionSource value)
            ? value
            : DsmConnectionSource.DirectAddress;
        if (certificate is null)
        {
            return false;
        }
        if (!request.Options.TryGetValue(ProfileIdKey, out Guid requestProfileId))
        {
            // QuickConnect 控制面请求不携带 NAS profile，且只能沿用系统信任。
            return sslPolicyErrors == SslPolicyErrors.None;
        }
        if (requestProfileId != _profileId)
        {
            return false;
        }

        var source = ResolveConnectionSource(requestedSource);
        if (source == DsmConnectionSource.QuickConnectRelay)
        {
            Interlocked.Exchange(ref _requiresSystemTrust, 1);
        }

        var accepted = EvaluateCertificate(
            certificate,
            sslPolicyErrors,
            source,
            out var challenge);
        if (challenge is not null)
        {
            _pendingChallenges[request] = challenge;
        }
        return accepted;
    }

    internal DsmConnectionSource ResolveConnectionSource(
        DsmConnectionSource requestedSource)
    {
        if (Volatile.Read(ref _requiresSystemTrust) != 0)
        {
            return DsmConnectionSource.QuickConnectRelay;
        }
        if (requestedSource != DsmConnectionSource.DirectAddress ||
            Volatile.Read(ref _activeSource) == (int)DsmConnectionSource.DirectAddress)
        {
            Interlocked.Exchange(ref _activeSource, (int)requestedSource);
        }
        return (DsmConnectionSource)Volatile.Read(ref _activeSource);
    }

    internal bool EvaluateCertificate(
        X509Certificate2 certificate,
        SslPolicyErrors sslPolicyErrors,
        DsmConnectionSource source,
        out CertificateTrustChallenge? challenge)
    {
        var presented = new CertificateFingerprint(
            Convert.ToHexString(SHA256.HashData(certificate.RawData)));
        var systemTrusted = sslPolicyErrors == SslPolicyErrors.None;
        var canBePinned = CanPinSelfSignedLeaf(certificate);
        var decision = CertificateTrustPolicy.Decide(
            systemTrusted,
            _pinnedFingerprint,
            presented,
            canBePinned,
            source == DsmConnectionSource.QuickConnectRelay ||
                Volatile.Read(ref _requiresSystemTrust) != 0);
        if (decision is CertificateTrustDecision.UseSystemTrust or
            CertificateTrustDecision.UsePinnedCertificate)
        {
            challenge = null;
            return true;
        }

        var kind = decision switch
        {
            CertificateTrustDecision.ReviewFirstCertificate =>
                CertificateTrustChallengeKind.FirstUntrustedCertificate,
            CertificateTrustDecision.ReviewChangedCertificate =>
                CertificateTrustChallengeKind.CertificateChanged,
            _ => CertificateTrustChallengeKind.InvalidCertificate,
        };
        challenge = new CertificateTrustChallenge(
            _profileId,
            kind,
            source,
            SafeSubjectSummary(certificate),
            presented,
            kind == CertificateTrustChallengeKind.CertificateChanged
                ? _pinnedFingerprint
                : null,
            CanApprove: canBePinned &&
                source != DsmConnectionSource.QuickConnectRelay);
        return false;
    }

    internal static bool CanPinSelfSignedLeaf(
        X509Certificate2 certificate,
        DateTimeOffset? now = null)
    {
        ArgumentNullException.ThrowIfNull(certificate);
        var instant = now ?? DateTimeOffset.UtcNow;
        if (instant.UtcDateTime < certificate.NotBefore.ToUniversalTime() ||
            instant.UtcDateTime > certificate.NotAfter.ToUniversalTime() ||
            !certificate.SubjectName.RawData.AsSpan().SequenceEqual(
                certificate.IssuerName.RawData))
        {
            return false;
        }
        if (certificate.Extensions
            .OfType<X509BasicConstraintsExtension>()
            .Any(extension => extension.CertificateAuthority))
        {
            return false;
        }

        using var chain = new X509Chain();
        chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        chain.ChainPolicy.CustomTrustStore.Add(certificate);
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        chain.ChainPolicy.DisableCertificateDownloads = true;
        chain.ChainPolicy.VerificationTime = instant.UtcDateTime;
        chain.ChainPolicy.ApplicationPolicy.Add(
            new Oid("1.3.6.1.5.5.7.3.1"));
        return chain.Build(certificate);
    }

    private static string SafeSubjectSummary(X509Certificate2 certificate)
    {
        var value = certificate.GetNameInfo(X509NameType.SimpleName, forIssuer: false);
        if (string.IsNullOrWhiteSpace(value))
        {
            return "certificate.subject.unavailable";
        }
        var sanitized = new string(value
            .Where(character => !char.IsControl(character))
            .Take(256)
            .ToArray());
        return string.IsNullOrWhiteSpace(sanitized)
            ? "certificate.subject.unavailable"
            : sanitized;
    }
}
