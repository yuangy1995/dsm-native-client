using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed class FileCertificatePinStore(string directory) : ICertificatePinStore
{
    private readonly string _directory = string.IsNullOrWhiteSpace(directory)
        ? throw new ArgumentException("certificate.invalid_store", nameof(directory))
        : Path.GetFullPath(directory);

    public async Task<CertificateFingerprint?> LoadAsync(
        Guid profileId,
        CancellationToken cancellationToken = default)
    {
        var path = PinPath(profileId);
        if (!File.Exists(path))
        {
            return null;
        }
        var value = await File.ReadAllTextAsync(path, cancellationToken)
            .ConfigureAwait(false);
        return new CertificateFingerprint(value.Trim());
    }

    public async Task SaveAsync(
        Guid profileId,
        CertificateFingerprint fingerprint,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(fingerprint);
        Directory.CreateDirectory(_directory);
        var path = PinPath(profileId);
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            await File.WriteAllTextAsync(
                temporaryPath,
                fingerprint.Sha256,
                cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            try
            {
                File.Delete(temporaryPath);
            }
            catch (IOException)
            {
                // 后续保存使用唯一临时名；清理失败不覆盖已经完成的原子提交。
            }
            catch (UnauthorizedAccessException)
            {
                // 后续保存使用唯一临时名；清理失败不覆盖已经完成的原子提交。
            }
        }
    }

    public Task RemoveAsync(
        Guid profileId,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        File.Delete(PinPath(profileId));
        return Task.CompletedTask;
    }

    private string PinPath(Guid profileId) =>
        Path.Combine(_directory, $"{profileId:N}.sha256");
}
