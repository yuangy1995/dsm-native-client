using System.Diagnostics;
using System.Net.Http.Headers;
using System.Runtime.ExceptionServices;
using LanStash.Domain;

namespace LanStash.App.Features.Transfers;

/// <summary>
/// 下载目标的事务边界。实现必须把 WriteAsync 写入临时内容，只有 CommitAsync
/// 可以替换原目标；AbortAsync 和 DisposeAsync 都必须保留原目标。CommitAsync
/// 成功返回表示替换已经完成，抛出异常表示原目标尚未被替换。
/// </summary>
internal interface ITransactionalDownloadDestination : IAsyncDisposable
{
    ValueTask WriteAsync(
        ReadOnlyMemory<byte> bytes,
        CancellationToken cancellationToken = default);

    ValueTask CommitAsync(CancellationToken cancellationToken = default);

    ValueTask AbortAsync(CancellationToken cancellationToken = default);
}

internal sealed class SafeFileDownloadService
{
    internal const int ChunkSize = 4 * 1024 * 1024;
    private readonly Action<string, Type> _cleanupDiagnostic;

    public SafeFileDownloadService()
        : this(TraceCleanupFailure)
    {
    }

    internal SafeFileDownloadService(Action<string, Type> cleanupDiagnostic)
    {
        ArgumentNullException.ThrowIfNull(cleanupDiagnostic);
        _cleanupDiagnostic = cleanupDiagnostic;
    }

    public async Task DownloadAsync(
        IFileRangeReader repository,
        string remotePath,
        long totalLength,
        ITransactionalDownloadDestination destination,
        IProgress<ForegroundTransferProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentException.ThrowIfNullOrWhiteSpace(remotePath);
        ArgumentNullException.ThrowIfNull(destination);
        if (totalLength < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(totalLength));
        }

        var committed = false;
        Exception? primaryFailure = null;
        try
        {
            progress?.Report(new ForegroundTransferProgress(0, totalLength));

            if (totalLength > 0)
            {
                await DownloadContentAsync(
                    repository,
                    remotePath,
                    totalLength,
                    destination,
                    progress,
                    cancellationToken).ConfigureAwait(false);
            }

            cancellationToken.ThrowIfCancellationRequested();
            await destination.CommitAsync(CancellationToken.None).ConfigureAwait(false);
            committed = true;
        }
        catch (Exception exception)
        {
            primaryFailure = exception;
        }
        finally
        {
            try
            {
                if (!committed)
                {
                    await destination.AbortAsync(CancellationToken.None).ConfigureAwait(false);
                }
            }
            catch (Exception cleanupFailure) when (primaryFailure is not null)
            {
                // 下载或提交失败是主故障，清理失败不能覆盖可操作的原始原因。
                ReportCleanupFailure("abort", cleanupFailure);
            }
            finally
            {
                try
                {
                    await destination.DisposeAsync().ConfigureAwait(false);
                }
                catch (Exception cleanupFailure) when (primaryFailure is not null || committed)
                {
                    // 已提交成功不能被临时资源清理失败反向解释为下载失败。
                    ReportCleanupFailure("dispose", cleanupFailure);
                }
            }
        }

        if (primaryFailure is not null)
        {
            ExceptionDispatchInfo.Capture(primaryFailure).Throw();
        }
    }

    private static async Task DownloadContentAsync(
        IFileRangeReader repository,
        string remotePath,
        long totalLength,
        ITransactionalDownloadDestination destination,
        IProgress<ForegroundTransferProgress>? progress,
        CancellationToken cancellationToken)
    {
        var isSegmented = totalLength > ChunkSize;
        var offset = 0L;
        string? contentVersion = null;

        while (offset < totalLength)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var length = Math.Min((long)ChunkSize, totalLength - offset);
            var result = await repository.ReadFileRangeResultAsync(
                remotePath,
                offset,
                length,
                expectedContentVersion: contentVersion,
                expectedTotalLength: totalLength,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            ValidateResult(result, offset, length, totalLength);

            if (offset == 0 && isSegmented)
            {
                contentVersion = RequireStrongContentVersion(result);
                if (!result.CanSafelyReadInSegments)
                {
                    throw new FileRangeContractException(
                        FileRangeContractFailure.UnsafeSegmentedRead,
                        "The first range cannot establish a safe segmented download.",
                        result.StatusCode);
                }
            }

            cancellationToken.ThrowIfCancellationRequested();
            await destination.WriteAsync(result.Bytes, cancellationToken).ConfigureAwait(false);
            offset += length;
            progress?.Report(new ForegroundTransferProgress(offset, totalLength));
        }
    }

    private static void ValidateResult(
        FileRangeReadResult result,
        long offset,
        long length,
        long totalLength)
    {
        if (result.RequestedStart != offset ||
            result.RequestedLength != length ||
            result.ResponseStart != offset ||
            result.ResponseLength != length ||
            result.TotalLength != totalLength ||
            result.ActualByteCount != length ||
            result.Bytes.LongLength != length)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnsafeSegmentedRead,
                "The repository returned a range that does not match the download plan.",
                result.StatusCode);
        }
    }

    private static string RequireStrongContentVersion(FileRangeReadResult result)
    {
        if (result.ServerContentVersion is not { } value ||
            !EntityTagHeaderValue.TryParse(value, out var entityTag) ||
            entityTag is null ||
            entityTag.IsWeak)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnsafeSegmentedRead,
                "A multi-range download requires a strong content version from the first range.",
                result.StatusCode);
        }

        return value;
    }

    private void ReportCleanupFailure(string stage, Exception exception)
    {
        try
        {
            _cleanupDiagnostic(stage, exception.GetType());
        }
        catch
        {
            // 诊断设施本身不能改变已经确定的事务结果。
        }
    }

    private static void TraceCleanupFailure(string stage, Type exceptionType) =>
        Trace.TraceWarning(
            "Download transaction {0} cleanup failed with {1}.",
            stage,
            exceptionType.FullName ?? exceptionType.Name);
}
