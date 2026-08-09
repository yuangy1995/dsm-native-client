using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Authentication;

public sealed class CertificatePinStoreTests
{
    [Fact]
    public async Task PinsAreProfileBoundReplaceableAndRemovable()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "LanStashCertificatePinTests",
            Guid.NewGuid().ToString("N"));
        try
        {
            var store = new FileCertificatePinStore(directory);
            var profileA = Guid.NewGuid();
            var profileB = Guid.NewGuid();
            var first = new CertificateFingerprint(new string('A', 64));
            var replacement = new CertificateFingerprint(new string('B', 64));

            Assert.Null(await store.LoadAsync(profileA));
            await store.SaveAsync(profileA, first);
            Assert.Equal(first, await store.LoadAsync(profileA));
            Assert.Null(await store.LoadAsync(profileB));

            await store.SaveAsync(profileA, replacement);
            Assert.Equal(replacement, await store.LoadAsync(profileA));

            await store.RemoveAsync(profileA);
            Assert.Null(await store.LoadAsync(profileA));
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task CancelledSaveDoesNotPublishPin()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            "LanStashCertificatePinTests",
            Guid.NewGuid().ToString("N"));
        try
        {
            var store = new FileCertificatePinStore(directory);
            var profile = Guid.NewGuid();
            using var cancellation = new CancellationTokenSource();
            cancellation.Cancel();

            await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
                store.SaveAsync(
                    profile,
                    new CertificateFingerprint(new string('C', 64)),
                    cancellation.Token));
            Assert.Null(await store.LoadAsync(profile));
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }
}
