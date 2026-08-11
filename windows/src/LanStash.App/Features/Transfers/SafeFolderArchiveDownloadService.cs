using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.ExceptionServices;
using LanStash.Domain;

namespace LanStash.App.Features.Transfers;

internal static class FolderArchiveValidator
{
    internal static void Validate(Stream stream)
    {
        ArgumentNullException.ThrowIfNull(stream);
        using var archive = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen: true);
        foreach (var entry in archive.Entries)
        {
            using var entryStream = entry.Open();
            _ = entryStream.ReadByte();
        }
    }
}

internal sealed class SafeFolderArchiveDownloadService
{
    private readonly Action<string, Type> _cleanupDiagnostic;

    public SafeFolderArchiveDownloadService()
        : this(TraceCleanupFailure)
    {
    }

    internal SafeFolderArchiveDownloadService(Action<string, Type> cleanupDiagnostic)
    {
        ArgumentNullException.ThrowIfNull(cleanupDiagnostic);
        _cleanupDiagnostic = cleanupDiagnostic;
    }

    public async Task DownloadAsync(
        IFileArchiveReader repository,
        string remotePath,
        ITransactionalDownloadDestination destination,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentException.ThrowIfNullOrWhiteSpace(remotePath);
        ArgumentNullException.ThrowIfNull(destination);

        var committed = false;
        Exception? primaryFailure = null;
        try
        {
            await repository.StreamFolderArchiveAsync(
                remotePath,
                destination.WriteAsync,
                cancellationToken).ConfigureAwait(false);
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
                    ReportCleanupFailure("dispose", cleanupFailure);
                }
            }
        }

        if (primaryFailure is not null)
        {
            ExceptionDispatchInfo.Capture(primaryFailure).Throw();
        }
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
            "Folder archive transaction {0} cleanup failed with {1}.",
            stage,
            exceptionType.FullName ?? exceptionType.Name);
}
