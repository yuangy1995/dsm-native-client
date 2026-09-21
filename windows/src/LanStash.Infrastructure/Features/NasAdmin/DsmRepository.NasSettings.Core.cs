using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // 旧通用写入口没有确认请求边界，继续隔离；已实现操作使用专用安全流程。
    private const bool NasSettingsWritesEnabled = false;
    private readonly SemaphoreSlim _nasWriteGate = new(1, 1);

    NasSettingsWriteAvailability INasSettingsRepository.WriteAvailability => NasSettingsWriteAvailability;

    private NasSettingsWriteAvailability NasSettingsWriteAvailability => new(
        CanSaveDDNS: _nasServiceSessionVerified && _nasServiceAdministrator && DdnsWriteCapability() is not null,
        CanSaveFileService: _nasServiceSessionVerified && _nasServiceAdministrator &&
            FileServiceReadGroups.Any(group => FileServiceCapability(group) is not null),
        CanSaveTerminal: _nasServiceSessionVerified && _nasServiceAdministrator && NasServiceCapability(NasServiceSettingsKind.Terminal) is not null,
        CanSaveProxy: _nasServiceSessionVerified && _nasServiceAdministrator && NasServiceCapability(NasServiceSettingsKind.Proxy) is not null,
        CanSaveNetwork: _nasServiceSessionVerified && _nasServiceAdministrator && EthernetCapability() is not null,
        CanSaveRegion: _nasServiceSessionVerified && _nasServiceAdministrator && RegionCapability() is not null,
        CanSaveSecurity: _nasServiceSessionVerified && _nasServiceAdministrator &&
            (SecurityCapability("SYNO.Core.Security.AutoBlock", 1) is not null || SecurityCapability("SYNO.Core.Security.DoS", 2) is not null ||
                SecurityCapability("SYNO.Core.Security.Firewall.Conf", 1) is not null || SecurityCapability("SYNO.Core.Security.Firewall", 1) is not null),
        CanSaveHardware: _nasServiceSessionVerified && _nasServiceAdministrator && HardwareReadGroups.Any(group => SecurityCapability(group.Api, 1) is not null),
        CanSaveFTP: false,
        CanSaveSFTP: false,
        CanSaveSSDP: false,
        CanSaveBonjour: false,
        CanSaveTimeMachine: false,
        CanSaveUPS: false,
        CanPowerAction: _nasServiceSessionVerified && _nasServiceAdministrator && PowerCapability() is not null,
        CanPackageControl: _nasServiceSessionVerified && _nasServiceAdministrator && SecurityCapability("SYNO.Core.Package", 2) is not null &&
            (SecurityCapability("SYNO.Core.Package.Control", 1) is not null || SecurityCapability("SYNO.Core.Package.Uninstallation", 1) is not null),
        CanAccountDelete: _nasServiceSessionVerified && _nasServiceAdministrator && DirectoryCapability(NasDirectoryKind.User) is not null,
        CanGroupDelete: _nasServiceSessionVerified && _nasServiceAdministrator && DirectoryCapability(NasDirectoryKind.Group) is not null,
        CanConnectionDisconnect: _nasServiceSessionVerified && _nasServiceAdministrator && ConnectionCapability() is not null,
        CanDiskTest: _nasServiceSessionVerified && _nasServiceAdministrator &&
            SecurityCapability("SYNO.Storage.CGI.Storage", 1) is not null && SecurityCapability("SYNO.Core.Storage.Disk", 1) is not null)
    {
        CanSaveRemoteAccess = _nasServiceSessionVerified && _nasServiceAdministrator &&
            (RemoteAccessCapability(NasRemoteAccessParts.Relay) is not null || RemoteAccessCapability(NasRemoteAccessParts.Router) is not null),
    };

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
