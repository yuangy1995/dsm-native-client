using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Net.Security;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Authentication;

public sealed class CertificateTrustPolicyTests
{
    private static readonly CertificateFingerprint Presented = Fingerprint('A');
    private static readonly CertificateFingerprint Pinned = Fingerprint('B');

    [Fact]
    public void SystemTrustIsUsedWhenThereIsNoChangedPin()
    {
        var decision = CertificateTrustPolicy.Decide(
            systemTrusted: true,
            pinnedFingerprint: null,
            Presented,
            canBePinned: false,
            requiresSystemTrust: false);

        Assert.Equal(CertificateTrustDecision.UseSystemTrust, decision);
    }

    [Fact]
    public void MatchingValidPinAcceptsNonSystemTrustedLeaf()
    {
        var decision = CertificateTrustPolicy.Decide(
            systemTrusted: false,
            Presented,
            Presented,
            canBePinned: true,
            requiresSystemTrust: false);

        Assert.Equal(CertificateTrustDecision.UsePinnedCertificate, decision);
    }

    [Fact]
    public void ChangedPinBlocksEvenWhenNewCertificateHasSystemTrust()
    {
        var decision = CertificateTrustPolicy.Decide(
            systemTrusted: true,
            Pinned,
            Presented,
            canBePinned: true,
            requiresSystemTrust: false);

        Assert.Equal(CertificateTrustDecision.ReviewChangedCertificate, decision);
    }

    [Fact]
    public void FirstValidSelfSignedLeafRequiresReview()
    {
        var decision = CertificateTrustPolicy.Decide(
            systemTrusted: false,
            pinnedFingerprint: null,
            Presented,
            canBePinned: true,
            requiresSystemTrust: false);

        Assert.Equal(CertificateTrustDecision.ReviewFirstCertificate, decision);
    }

    [Fact]
    public void InvalidLeafCannotBePinned()
    {
        var decision = CertificateTrustPolicy.Decide(
            systemTrusted: false,
            Presented,
            Presented,
            canBePinned: false,
            requiresSystemTrust: false);

        Assert.Equal(CertificateTrustDecision.RejectInvalidCertificate, decision);
    }

    [Theory]
    [InlineData(false, CertificateTrustDecision.RejectInvalidCertificate)]
    [InlineData(true, CertificateTrustDecision.UseSystemTrust)]
    public void RelayOnlyUsesSystemTrust(
        bool systemTrusted,
        CertificateTrustDecision expected)
    {
        var decision = CertificateTrustPolicy.Decide(
            systemTrusted,
            Pinned,
            Presented,
            canBePinned: true,
            requiresSystemTrust: true);

        Assert.Equal(expected, decision);
    }

    [Fact]
    public void FingerprintsAndChallengesHaveSafeDiagnosticStrings()
    {
        var challenge = new CertificateTrustChallenge(
            Guid.Parse("4fcb8ec9-cd91-45c6-a234-9f47b67fc560"),
            CertificateTrustChallengeKind.CertificateChanged,
            DsmConnectionSource.QuickConnectLan,
            "private-subject",
            Presented,
            Pinned,
            CanApprove: true);
        var error = new CertificateTrustChallengeException(challenge);

        Assert.Equal(nameof(CertificateFingerprint), Presented.ToString());
        Assert.Equal(nameof(CertificateTrustChallenge), challenge.ToString());
        Assert.DoesNotContain(Presented.Sha256, error.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain("private-subject", error.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void OnlyCurrentlyValidSelfSignedServerLeafCanBePinned()
    {
        var now = DateTimeOffset.UtcNow;
        using var valid = SelfSignedServerCertificate(
            now.AddHours(-1),
            now.AddHours(1));
        using var expired = SelfSignedServerCertificate(
            now.AddDays(-2),
            now.AddDays(-1));

        Assert.True(WindowsCertificateTrustHandler.CanPinSelfSignedLeaf(valid, now));
        Assert.False(WindowsCertificateTrustHandler.CanPinSelfSignedLeaf(expired, now));
    }

    [Fact]
    public void HandlerProducesTypedFirstUseAndChangedChallenges()
    {
        var profileId = Guid.NewGuid();
        var now = DateTimeOffset.UtcNow;
        using var certificate = SelfSignedServerCertificate(
            now.AddHours(-1),
            now.AddHours(1));
        var presented = new CertificateFingerprint(
            Convert.ToHexString(SHA256.HashData(certificate.RawData)));
        using var firstHandler = new WindowsCertificateTrustHandler(profileId);

        var firstAccepted = firstHandler.EvaluateCertificate(
            certificate,
            SslPolicyErrors.RemoteCertificateChainErrors,
            DsmConnectionSource.DirectAddress,
            out var firstChallenge);

        Assert.False(firstAccepted);
        Assert.NotNull(firstChallenge);
        Assert.Equal(
            CertificateTrustChallengeKind.FirstUntrustedCertificate,
            firstChallenge.Kind);
        Assert.True(firstChallenge.CanApprove);

        using var changedHandler = new WindowsCertificateTrustHandler(profileId, Pinned);
        var changedAccepted = changedHandler.EvaluateCertificate(
            certificate,
            SslPolicyErrors.RemoteCertificateChainErrors,
            DsmConnectionSource.QuickConnectLan,
            out var changedChallenge);

        Assert.False(changedAccepted);
        Assert.NotNull(changedChallenge);
        Assert.Equal(CertificateTrustChallengeKind.CertificateChanged, changedChallenge.Kind);
        Assert.Equal(Pinned, changedChallenge.PreviouslyPinnedFingerprint);
        Assert.Equal(presented, changedChallenge.PresentedFingerprint);
    }

    [Fact]
    public void RelayHandlerRejectsPinAndOnlyAcceptsSystemTrust()
    {
        var now = DateTimeOffset.UtcNow;
        using var certificate = SelfSignedServerCertificate(
            now.AddHours(-1),
            now.AddHours(1));
        var presented = new CertificateFingerprint(
            Convert.ToHexString(SHA256.HashData(certificate.RawData)));
        using var handler = new WindowsCertificateTrustHandler(Guid.NewGuid(), presented);

        var pinnedAccepted = handler.EvaluateCertificate(
            certificate,
            SslPolicyErrors.RemoteCertificateChainErrors,
            DsmConnectionSource.QuickConnectRelay,
            out var invalidChallenge);
        var systemAccepted = handler.EvaluateCertificate(
            certificate,
            SslPolicyErrors.None,
            DsmConnectionSource.QuickConnectRelay,
            out var systemChallenge);

        Assert.False(pinnedAccepted);
        Assert.NotNull(invalidChallenge);
        Assert.Equal(CertificateTrustChallengeKind.InvalidCertificate, invalidChallenge.Kind);
        Assert.False(invalidChallenge.CanApprove);
        Assert.True(systemAccepted);
        Assert.Null(systemChallenge);
    }

    [Fact]
    public void HandlerKeepsResolvedSourceForLaterRepositoryRequests()
    {
        using var external = new WindowsCertificateTrustHandler(Guid.NewGuid());
        Assert.Equal(
            DsmConnectionSource.QuickConnectExternal,
            external.ResolveConnectionSource(DsmConnectionSource.QuickConnectExternal));
        Assert.Equal(
            DsmConnectionSource.QuickConnectExternal,
            external.ResolveConnectionSource(DsmConnectionSource.DirectAddress));

        using var relay = new WindowsCertificateTrustHandler(Guid.NewGuid());
        Assert.Equal(
            DsmConnectionSource.QuickConnectRelay,
            relay.ResolveConnectionSource(DsmConnectionSource.QuickConnectRelay));
        Assert.Equal(
            DsmConnectionSource.QuickConnectRelay,
            relay.ResolveConnectionSource(DsmConnectionSource.DirectAddress));
    }

    private static CertificateFingerprint Fingerprint(char character) =>
        new(new string(character, 64));

    private static X509Certificate2 SelfSignedServerCertificate(
        DateTimeOffset notBefore,
        DateTimeOffset notAfter)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest(
            "CN=synthetic.invalid",
            key,
            HashAlgorithmName.SHA256,
            RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(
            certificateAuthority: false,
            hasPathLengthConstraint: false,
            pathLengthConstraint: 0,
            critical: true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(
            X509KeyUsageFlags.DigitalSignature,
            critical: true));
        var usages = new OidCollection
        {
            new("1.3.6.1.5.5.7.3.1"),
        };
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
            usages,
            critical: true));
        return request.CreateSelfSigned(notBefore, notAfter);
    }
}
