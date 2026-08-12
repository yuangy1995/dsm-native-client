using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private readonly SemaphoreSlim _nasPowerGate = new(1, 1);

    public async Task<MutationResult> ExecutePowerActionAsync(
        NasPowerAction action,
        CancellationToken cancellationToken = default)
    {
        var method = action switch
        {
            NasPowerAction.Shutdown => "shutdown",
            NasPowerAction.Reboot => "reboot",
            _ => throw new ArgumentOutOfRangeException(nameof(action)),
        };

        var operation = action switch
        {
            NasPowerAction.Shutdown => "shutdown",
            NasPowerAction.Reboot => "reboot",
            _ => throw new ArgumentOutOfRangeException(nameof(action)),
        };

        if (!NasSettingsWritesEnabled || !((INasSettingsRepository)this).WriteAvailability.CanPowerAction)
        {
            return UnsupportedResult(operation);
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return CancelledBeforeSubmissionResult(operation);
        }
        if (!await _nasPowerGate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        {
            return new MutationResult(
                1, MutationResultStatus.ConfirmedFailure, operation,
                submitted: false, requiresRefresh: false,
                new MutationResultCounts(0, 1, 0), MutationErrorCategory.Conflict,
                diagnosticTag: $"{operation}.already-in-progress");
        }

        try
        {
            try
            {
                var capability = _capabilities["SYNO.Core.System"];
                await _api.CallReadJsonObjectAsync(
                    _profile, _session, capability, capability.MaxVersion, "info",
                    parameters: null, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return CancelledBeforeSubmissionResult(operation);
            }
            catch (DsmException error) when (error.AuthenticationFailure == true)
            {
                return ConfirmedFailureResult(operation, MutationErrorCategory.Authentication,
                    $"{operation}.preflight-authentication");
            }
            catch (DsmException error) when (error.Code == 105)
            {
                return ConfirmedFailureResult(operation, MutationErrorCategory.Permission,
                    $"{operation}.preflight-permission");
            }
            catch
            {
                return ConfirmedFailureResult(operation, MutationErrorCategory.Network,
                    $"{operation}.preflight-failed");
            }

            if (cancellationToken.IsCancellationRequested)
            {
                return CancelledBeforeSubmissionResult(operation);
            }

            try
            {
                var capability = _capabilities["SYNO.Core.System"];
                await _api.CallAsync(
                    _profile, _session, capability, method,
                    parameters: null, cancellationToken).ConfigureAwait(false);
                return SubmittedButUnverifiedResult(operation);
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
            catch
            {
                return SubmittedButUnverifiedResult(operation);
            }
        }
        finally
        {
            _nasPowerGate.Release();
        }
    }
}
