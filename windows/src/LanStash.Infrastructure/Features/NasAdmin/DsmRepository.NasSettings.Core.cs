using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // NAS 控制面写入仍未完成目标版本的行为验收，统一保持生产门关闭。
    private const bool NasSettingsWritesEnabled = false;
    private readonly SemaphoreSlim _nasWriteGate = new(1, 1);

    NasSettingsWriteAvailability INasSettingsRepository.WriteAvailability => NasSettingsWriteAvailability;

    private NasSettingsWriteAvailability NasSettingsWriteAvailability => new(
        CanSaveDDNS: false,
        CanSaveFileService: false,
        CanSaveTerminal: false,
        CanSaveProxy: false,
        CanSaveNetwork: false,
        CanSaveRegion: false,
        CanSaveSecurity: false,
        CanSaveHardware: false,
        CanSaveFTP: false,
        CanSaveSFTP: false,
        CanSaveSSDP: false,
        CanSaveBonjour: false,
        CanSaveTimeMachine: false,
        CanSaveUPS: false,
        CanPowerAction: false,
        CanPackageControl: false,
        CanAccountDelete: false,
        CanGroupDelete: false,
        CanConnectionDisconnect: false,
        CanDiskTest: false);

    private async Task<MutationResult> SaveSettingsAsync(
        string apiName,
        string method,
        IReadOnlyDictionary<string, string> parameters,
        string operation,
        Func<CancellationToken, Task>? readback = null,
        CancellationToken cancellationToken = default)
    {
        if (!NasSettingsWritesEnabled || !Supports(apiName))
        {
            return UnsupportedResult(operation);
        }

        if (cancellationToken.IsCancellationRequested)
        {
            return CancelledBeforeSubmissionResult(operation);
        }

        if (!await _nasWriteGate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        {
            return new MutationResult(
                1, MutationResultStatus.ConfirmedFailure, operation,
                submitted: false, requiresRefresh: false,
                new MutationResultCounts(0, 1, 0), MutationErrorCategory.Conflict,
                diagnosticTag: $"{operation.ToLowerInvariant()}.already-in-progress");
        }

        try
        {
            try
            {
                await CallVoidAsync(apiName, method, parameters, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return CancellationRequestedAfterSubmissionResult(operation);
            }
            catch (DsmException error) when (error.AuthenticationFailure == true)
            {
                return ConfirmedFailureResult(operation, MutationErrorCategory.Authentication,
                    $"{operation}.authentication");
            }
            catch (DsmException error) when (error.Code == 105)
            {
                return ConfirmedFailureResult(operation, MutationErrorCategory.Permission,
                    $"{operation}.permission");
            }
            catch (DsmException)
            {
                return SubmittedButUnverifiedResult(operation);
            }
            catch (Exception) when (cancellationToken.IsCancellationRequested)
            {
                return CancellationRequestedAfterSubmissionResult(operation);
            }
            catch (OperationCanceledException)
            {
                return CancellationRequestedAfterSubmissionResult(operation);
            }
            catch (Exception)
            {
                return SubmittedButUnverifiedResult(operation);
            }

            try
            {
                if (readback is null)
                {
                    return SubmittedButUnverifiedResult(operation);
                }

                await readback(cancellationToken).ConfigureAwait(false);
                return ConfirmedSuccessResult(operation);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return CancellationRequestedAfterSubmissionResult(operation);
            }
            catch
            {
                return SubmittedButUnverifiedResult(operation);
            }
        }
        finally
        {
            _nasWriteGate.Release();
        }
    }

    private static MutationResult UnsupportedResult(string operation) =>
        new(1, MutationResultStatus.Unsupported, operation, submitted: false,
            requiresRefresh: false, new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unsupported, diagnosticTag: $"{operation.ToLowerInvariant()}.unsupported");

    private static MutationResult CancelledBeforeSubmissionResult(string operation) =>
        new(1, MutationResultStatus.CancelledBeforeSubmission, operation, submitted: false,
            requiresRefresh: false, new MutationResultCounts(0, 0, 0),
            diagnosticTag: $"{operation.ToLowerInvariant()}.cancelled");

    private static MutationResult CancellationRequestedAfterSubmissionResult(string operation) =>
        new(1, MutationResultStatus.CancellationRequestedAfterSubmission, operation,
            submitted: true, requiresRefresh: true,
            new MutationResultCounts(0, 0, 1),
            MutationErrorCategory.Network, diagnosticTag: $"{operation.ToLowerInvariant()}.cancelled-after-submit");

    private static MutationResult ConfirmedSuccessResult(string operation) =>
        new(1, MutationResultStatus.ConfirmedSuccess, operation, submitted: true,
            requiresRefresh: false, new MutationResultCounts(1, 0, 0));

    private static MutationResult ConfirmedFailureResult(
        string operation, MutationErrorCategory category, string diagnosticTag) =>
        new(1, MutationResultStatus.ConfirmedFailure, operation, submitted: true,
            requiresRefresh: false, new MutationResultCounts(0, 1, 0),
            category, diagnosticTag: diagnosticTag);

    private static MutationResult SubmittedButUnverifiedResult(string operation) =>
        new(1, MutationResultStatus.SubmittedButUnverified, operation, submitted: true,
            requiresRefresh: true, new MutationResultCounts(0, 0, 1),
            MutationErrorCategory.Server, diagnosticTag: $"{operation.ToLowerInvariant()}.unverified");
}
