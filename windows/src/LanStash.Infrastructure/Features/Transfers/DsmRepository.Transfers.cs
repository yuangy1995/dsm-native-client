using LanStash.Domain;
using System.Text.Json;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<MutationResult> UploadFileAsync(
        FileUploadRequest request,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (!_capabilities.TryGetValue("SYNO.FileStation.Upload", out var capability))
        {
            return UploadResult(
                MutationResultStatus.Unsupported,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                MutationErrorCategory.Unsupported,
                "file.upload.unsupported");
        }

        var submission = await _api.UploadFileAsync(
            _profile,
            _session,
            capability,
            request,
            progress,
            cancellationToken).ConfigureAwait(false);
        switch (submission.Status)
        {
            case FileUploadTransportStatus.CancelledBeforeSubmission:
                return UploadResult(
                    MutationResultStatus.CancelledBeforeSubmission,
                    submitted: false,
                    requiresRefresh: false,
                    succeeded: 0,
                    failed: 0,
                    unknown: 0);
            case FileUploadTransportStatus.CancellationRequestedAfterSubmission:
                return UploadResult(
                    MutationResultStatus.CancellationRequestedAfterSubmission,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: 0,
                    unknown: 1,
                    submission.ErrorCategory,
                    submission.DiagnosticTag);
            case FileUploadTransportStatus.SubmittedButUnverified:
                return UploadResult(
                    MutationResultStatus.SubmittedButUnverified,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: 0,
                    unknown: 1,
                    submission.ErrorCategory,
                    submission.DiagnosticTag);
            case FileUploadTransportStatus.ConfirmedFailure:
                return UploadResult(
                    MutationResultStatus.ConfirmedFailure,
                    submitted: true,
                    requiresRefresh: false,
                    succeeded: 0,
                    failed: 1,
                    unknown: 0,
                    submission.ErrorCategory,
                    submission.DiagnosticTag);
            case FileUploadTransportStatus.Unsupported:
                return UploadResult(
                    MutationResultStatus.Unsupported,
                    submitted: false,
                    requiresRefresh: false,
                    succeeded: 0,
                    failed: 1,
                    unknown: 0,
                    MutationErrorCategory.Unsupported,
                    submission.DiagnosticTag ?? "file.upload.unsupported");
            case FileUploadTransportStatus.Accepted:
                break;
            default:
                throw new InvalidOperationException("upload.unknown_transport_status");
        }

        try
        {
            const int pageSize = 500;
            var offset = 0;
            while (true)
            {
                var page = await ListFilesAsync(
                    request.FolderPath,
                    offset,
                    pageSize,
                    cancellationToken).ConfigureAwait(false);
                if (page.Offset != offset)
                {
                    return UploadUnverified("file.upload.readback-offset");
                }
                if (page.Items.Any(item =>
                        !item.IsDirectory &&
                        string.Equals(item.Name, request.FileName, StringComparison.Ordinal) &&
                        item.Size == request.Length))
                {
                    return UploadResult(
                        MutationResultStatus.ConfirmedSuccess,
                        submitted: true,
                        requiresRefresh: false,
                        succeeded: 1,
                        failed: 0,
                        unknown: 0);
                }

                if (page.Items.Count == 0 || offset + page.Items.Count >= page.Total)
                {
                    return UploadUnverified("file.upload.readback-mismatch");
                }
                offset = checked(offset + page.Items.Count);
            }
        }
        catch (OperationCanceledException)
        {
            return UploadResult(
                MutationResultStatus.CancellationRequestedAfterSubmission,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                MutationErrorCategory.Network,
                "file.upload.cancelled-during-readback");
        }
        catch (DsmException error)
        {
            return UploadResult(
                MutationResultStatus.SubmittedButUnverified,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                error.AuthenticationFailure
                    ? MutationErrorCategory.Authentication
                    : MutationErrorCategory.Network,
                "file.upload.readback-unavailable");
        }
        catch (OverflowException)
        {
            return UploadUnverified("file.upload.readback-invalid");
        }
        catch (InvalidOperationException)
        {
            return UploadUnverified("file.upload.readback-invalid");
        }
        catch (FormatException)
        {
            return UploadUnverified("file.upload.readback-invalid");
        }
        catch (ArgumentOutOfRangeException)
        {
            return UploadUnverified("file.upload.readback-invalid");
        }
        catch (JsonException)
        {
            return UploadUnverified("file.upload.readback-invalid");
        }
    }

    private static MutationResult UploadUnverified(string diagnosticTag) =>
        UploadResult(
            MutationResultStatus.SubmittedButUnverified,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: 1,
            MutationErrorCategory.Unknown,
            diagnosticTag);

    private static MutationResult UploadResult(
        MutationResultStatus status,
        bool submitted,
        bool requiresRefresh,
        int succeeded,
        int failed,
        int unknown,
        MutationErrorCategory? errorCategory = null,
        string? diagnosticTag = null) =>
        new(
            1,
            status,
            "uploadFile",
            submitted,
            requiresRefresh,
            new MutationResultCounts(succeeded, failed, unknown),
            errorCategory,
            diagnosticTag: diagnosticTag);
}
