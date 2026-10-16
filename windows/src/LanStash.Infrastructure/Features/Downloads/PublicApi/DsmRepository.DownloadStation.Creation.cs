using System.Security.Cryptography;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<DownloadTaskCreateOutcome> CreateTaskAsync(DownloadTaskCreateRequest request, CancellationToken cancellationToken = default)
    {
        if (!TryPrepareDownloadCreateRequest(request, out var uri, out var destination) || request.ProfileId != ProfileId)
            return new(DownloadActionFailure(new ArgumentException(), "downloadCreate"), null, null);
        if (!HasPublicDownloadVersion(PublicDownloadTaskApi, 3))
            return new(DownloadActionFailure(new NotSupportedException(), "downloadCreate"), null, null);
        return await SubmitDownloadCreationAsync(DownloadActionKind.CreateLink, DownloadCreateDigest("uri", uri), destination, async token =>
        {
            var values = new Dictionary<string, string> { ["uri"] = uri };
            if (destination is not null) values["destination"] = destination;
            var response = await CallPublicDownloadAsync(PublicDownloadTaskApi, "create", values, token, 3).ConfigureAwait(false);
            return new(DownloadTaskFileCreateTransportStatus.Accepted, StableDownloadId(response["taskid"] ?? response["task_id"] ?? response["id"]));
        }, cancellationToken).ConfigureAwait(false);
    }
    public async Task<DownloadTaskCreateOutcome> CreateTaskFromFileAsync(DownloadTaskFileCreateRequest request, CancellationToken cancellationToken = default)
    {
        if (request.ProfileId != ProfileId) return new(DownloadActionFailure(new ArgumentException(), "downloadCreate"), null, null);
        if (!HasPublicDownloadVersion(PublicDownloadTaskApi, request.Destination is null ? 1 : 2))
            return new(DownloadActionFailure(new NotSupportedException(), "downloadCreate"), null, null);
        // 哈希与发送共用冻结的实际内容；文件名、目录和密码不参与来源身份，也不进入恢复记录。
        byte[]? bytes = null;
        try
        {
            bytes = new byte[checked((int)request.Length)];
            await request.Content.ReadExactlyAsync(bytes, cancellationToken).ConfigureAwait(false);
            var extra = new byte[1];
            if (await request.Content.ReadAsync(extra, cancellationToken).ConfigureAwait(false) != 0) throw new InvalidDataException("download.file-length-changed");
            using var content = new MemoryStream(bytes, writable: false);
            var frozen = new DownloadTaskFileCreateRequest(ProfileId, content, bytes.Length, request.FileName, request.Destination, request.UnzipPassword);
            return await SubmitDownloadCreationAsync(DownloadActionKind.CreateFile, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), request.Destination,
                token => _api.CreateDownloadTaskFromFileAsync(_profile, _session, _capabilities[PublicDownloadTaskApi], frozen, null, token), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) { return new(DownloadActionFailure(error, "downloadCreate"), null, null); }
        finally { if (bytes is not null) CryptographicOperations.ZeroMemory(bytes); }
    }
    private async Task<DownloadTaskCreateOutcome> SubmitDownloadCreationAsync(DownloadActionKind kind, string source, string? destination,
        Func<CancellationToken, Task<DownloadTaskFileCreateTransportResult>> submit, CancellationToken token)
    {
        var entered = false; var submitted = false;
        try
        {
            if (!HasControllablePublicDownloadStationContract || _session.ProfileId != ProfileId) throw new NotSupportedException();
            await EnterDownloadsAsync(token).ConfigureAwait(false); entered = true;
            if (PendingDownload(kind, [source]) is { } pending)
            {
                await ReviewDownloadAsync(pending, token).ConfigureAwait(false);
                return new(DownloadActionResult(DownloadInfo(pending) with { CancellationRequestedAfterSubmission = false }), null, null);
            }
            var before = (await LoadAllPublicDownloadTasksAsync(token).ConfigureAwait(false)).Select(task => task.Id).ToHashSet(StringComparer.Ordinal);
            token.ThrowIfCancellationRequested();
            var step = new DownloadStep { Target = source, Identity = source, Stage = DownloadActionStage.Unknown };
            var entry = NewDownload(kind, [step]);
            await SaveDownloadAsync(entry).ConfigureAwait(false);
            if (token.IsCancellationRequested)
            {
                step.Stage = DownloadActionStage.Cancelled; await SaveDownloadAsync(entry).ConfigureAwait(false); token.ThrowIfCancellationRequested();
            }
            DownloadTaskFileCreateTransportResult? response = null;
            submitted = step.Submitted = true;
            try { response = await submit(token).ConfigureAwait(false); }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && DownloadStationErrors.IsKnownRejection(error.Code))
            { step.Stage = DownloadActionStage.Rejected; step.Error = DownloadActionError(error); }
            catch (OperationCanceledException) { entry.CancelledAfterSubmission = true; }
            catch { }
            if (response is not null)
            {
                switch (response.Status)
                {
                    case DownloadTaskFileCreateTransportStatus.Accepted: step.Accepted = true; step.Stage = DownloadActionStage.Accepted; break;
                    case DownloadTaskFileCreateTransportStatus.CancelledBeforeSubmission: step.Stage = DownloadActionStage.Cancelled; submitted = step.Submitted = false; break;
                    case DownloadTaskFileCreateTransportStatus.Unsupported: step.Stage = DownloadActionStage.Rejected; step.Error = MutationErrorCategory.Unsupported; submitted = step.Submitted = false; break;
                    case DownloadTaskFileCreateTransportStatus.ConfirmedFailure: step.Stage = DownloadActionStage.Rejected; step.Error = response.ErrorCategory; break;
                    case DownloadTaskFileCreateTransportStatus.CancellationRequestedAfterSubmission: entry.CancelledAfterSubmission = true; break;
                }
            }
            await SaveDownloadAsync(entry).ConfigureAwait(false);
            DownloadTask? task = null;
            var id = response?.TaskId;
            if (step.Accepted && ValidDownloadId(id) && !before.Contains(id!))
            {
                try { task = (await LoadAllPublicDownloadTasksAsync(token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == id &&
                    (destination is null || item.Destination == destination)); }
                catch { /* 接受回执已经持久保存；任务读取失败不撤销接受事实。 */ }
            }
            return new(DownloadActionResult(DownloadInfo(entry)),
                step.Accepted && ValidDownloadId(id) ? id : null, task);
        }
        catch (Exception error)
        {
            return new(submitted ? new(1, MutationResultStatus.SubmittedButUnverified, "downloadCreate", true, true, new(0, 0, 1), MutationErrorCategory.Unknown)
                : DownloadActionFailure(error, "downloadCreate"), null, null);
        }
        finally { if (entered) DownloadRecords.Gate.Release(); }
    }
}
