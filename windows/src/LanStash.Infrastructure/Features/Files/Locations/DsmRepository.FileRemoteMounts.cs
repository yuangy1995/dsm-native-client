using System.Globalization;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int RemoteMountApiVersion = 1;

    bool IFileLocationsRepository.AllowsRemoteMountManagement =>
        FileLocationWritesEnabled && HasRemoteMountCapability() &&
        _api is IFileLocationMutationTransport;

    async Task<MutationResult> IFileLocationsRepository.CreateRemoteMountAsync(
        RemoteMountDraft draft,
        CancellationToken cancellationToken) =>
        await ExecuteRemoteMountMutationAsync("createRemoteMount", draft, isUpdate: false, cancellationToken)
            .ConfigureAwait(false);

    async Task<MutationResult> IFileLocationsRepository.UpdateRemoteMountAsync(
        RemoteMountDraft draft,
        CancellationToken cancellationToken) =>
        await ExecuteRemoteMountMutationAsync("updateRemoteMount", draft, isUpdate: true, cancellationToken)
            .ConfigureAwait(false);

    async Task<MutationResult> IFileLocationsRepository.DeleteRemoteMountAsync(
        string mountPoint,
        CancellationToken cancellationToken)
    {
        if (!HasRemoteMountCapability())
        {
            return RemoteMountResult(
                "deleteRemoteMount",
                MutationResultStatus.Unsupported,
                errorCategory: MutationErrorCategory.Unsupported,
                tag: "remote-mount.delete.unsupported");
        }
        if (string.IsNullOrWhiteSpace(mountPoint) || !mountPoint.StartsWith('/') ||
            mountPoint.EndsWith('/') || mountPoint.Contains("//") || mountPoint.Contains('\\') ||
            mountPoint.Length > 4096)
        {
            return RemoteMountResult(
                "deleteRemoteMount",
                MutationResultStatus.ConfirmedFailure,
                errorCategory: MutationErrorCategory.Validation,
                tag: "remote-mount.delete.invalid-mount-point");
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return RemoteMountResult(
                "deleteRemoteMount",
                MutationResultStatus.CancelledBeforeSubmission,
                tag: "remote-mount.delete.cancelled");
        }
        if (!((IFileLocationsRepository)this).AllowsRemoteMountManagement)
        {
            return RemoteMountResult(
                "deleteRemoteMount",
                MutationResultStatus.Unsupported,
                errorCategory: MutationErrorCategory.Unsupported,
                tag: "remote-mount.delete.transport-unsupported");
        }
        try
        {
            var parameters = new Dictionary<string, string>
            {
                ["mount_point"] = mountPoint,
            };
            var transportResult = await SendRemoteMountMutationAsync(
                    FileLocationMutationKind.DeleteRemoteMount,
                    "delete",
                    parameters,
                    cancellationToken)
                .ConfigureAwait(false);
            return RemoteMountResult("deleteRemoteMount", transportResult);
        }
        catch (OperationCanceledException)
        {
            return RemoteMountResult(
                "deleteRemoteMount",
                MutationResultStatus.CancellationRequestedAfterSubmission,
                submitted: true,
                errorCategory: MutationErrorCategory.Network,
                tag: "remote-mount.delete.cancelled");
        }
        catch (DsmException error) when (IsMountAuthenticationFailure(error))
        {
            throw;
        }
        catch (DsmException error)
        {
            return RemoteMountResult(
                "deleteRemoteMount",
                error.Code == 105
                    ? MutationResultStatus.PermissionDenied
                    : MutationResultStatus.ConfirmedFailure,
                submitted: true,
                errorCategory: error.Code == 105
                    ? MutationErrorCategory.Permission
                    : MutationErrorCategory.Server,
                tag: "remote-mount.delete.server-error");
        }
        catch (Exception)
        {
            return RemoteMountResult(
                "deleteRemoteMount",
                MutationResultStatus.SubmittedButUnverified,
                submitted: true,
                errorCategory: MutationErrorCategory.Network,
                tag: "remote-mount.delete.network-error");
        }
    }

    private async Task<MutationResult> ExecuteRemoteMountMutationAsync(
        string operation,
        RemoteMountDraft draft,
        bool isUpdate,
        CancellationToken cancellationToken)
    {
        if (!HasRemoteMountCapability())
        {
            return RemoteMountResult(
                operation,
                MutationResultStatus.Unsupported,
                errorCategory: MutationErrorCategory.Unsupported,
                tag: "remote-mount.unsupported");
        }
        if (!draft.IsValidForSubmission)
        {
            return RemoteMountResult(
                operation,
                MutationResultStatus.ConfirmedFailure,
                errorCategory: MutationErrorCategory.Validation,
                tag: "remote-mount.invalid-draft");
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return RemoteMountResult(
                operation,
                MutationResultStatus.CancelledBeforeSubmission,
                tag: "remote-mount.cancelled");
        }
        if (!((IFileLocationsRepository)this).AllowsRemoteMountManagement)
        {
            return RemoteMountResult(
                operation,
                MutationResultStatus.Unsupported,
                errorCategory: MutationErrorCategory.Unsupported,
                tag: "remote-mount.transport-unsupported");
        }
        try
        {
            var parameters = BuildRemoteMountParameters(draft, isUpdate);
            var method = isUpdate ? "update" : "create";

            // transport 负责一次提交和生产 envelope 的 data 解包；这里不读取 success。
            var transportResult = await SendRemoteMountMutationAsync(
                    isUpdate ? FileLocationMutationKind.UpdateRemoteMount : FileLocationMutationKind.CreateRemoteMount,
                    method,
                    parameters,
                    cancellationToken)
                .ConfigureAwait(false);
            return RemoteMountResult(operation, transportResult);
        }
        catch (OperationCanceledException)
        {
            return RemoteMountResult(
                operation,
                MutationResultStatus.CancellationRequestedAfterSubmission,
                submitted: true,
                errorCategory: MutationErrorCategory.Network,
                tag: "remote-mount.cancelled");
        }
        catch (DsmException error) when (IsMountAuthenticationFailure(error))
        {
            throw;
        }
        catch (DsmException error)
        {
            return RemoteMountResult(
                operation,
                error.Code == 105
                    ? MutationResultStatus.PermissionDenied
                    : MutationResultStatus.ConfirmedFailure,
                submitted: true,
                errorCategory: error.Code == 105
                    ? MutationErrorCategory.Permission
                    : MutationErrorCategory.Server,
                tag: "remote-mount.server-error");
        }
        catch (Exception)
        {
            return RemoteMountResult(
                operation,
                MutationResultStatus.SubmittedButUnverified,
                submitted: true,
                errorCategory: MutationErrorCategory.Network,
                tag: "remote-mount.network-error");
        }
    }

    private Dictionary<string, string> BuildRemoteMountParameters(RemoteMountDraft draft, bool isUpdate)
    {
        var parameters = new Dictionary<string, string>
        {
            ["server"] = draft.Server,
            ["remote_path"] = draft.RemotePath,
            ["mount_point"] = draft.MountPoint,
            ["read_only"] = draft.ReadOnly ? "true" : "false",
            ["protocol"] = ProtocolValue(draft.Protocol),
        };
        if (draft.Username is { Length: > 0 })
        {
            parameters["username"] = draft.Username;
        }
        if (draft.Password is { Length: > 0 })
        {
            parameters["password"] = draft.Password;
        }
        if (draft.Domain is { Length: > 0 })
        {
            parameters["domain"] = draft.Domain;
        }
        if (isUpdate && draft.ExistingMountPoint is { Length: > 0 })
        {
            parameters["existing_mount_point"] = draft.ExistingMountPoint;
        }
        return parameters;
    }

    private bool HasRemoteMountCapability() =>
        _capabilities.TryGetValue("SYNO.FileStation.Mount", out var capability) &&
        string.Equals(capability.Name, "SYNO.FileStation.Mount", StringComparison.Ordinal) &&
        RemoteMountApiVersion >= capability.MinVersion &&
        RemoteMountApiVersion <= capability.MaxVersion &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

    private async Task<FileLocationMutationTransportResult> SendRemoteMountMutationAsync(
        FileLocationMutationKind kind,
        string method,
        IReadOnlyDictionary<string, string> parameters,
        CancellationToken cancellationToken)
    {
        if (_api is not IFileLocationMutationTransport transport ||
            !_capabilities.TryGetValue("SYNO.FileStation.Mount", out var capability) ||
            !string.Equals(capability.Name, "SYNO.FileStation.Mount", StringComparison.Ordinal))
        {
            return new(
                FileLocationMutationTransportStatus.Unsupported,
                ErrorCategory: MutationErrorCategory.Unsupported,
                DiagnosticTag: "remote-mount.transport-unsupported");
        }
        return await transport.SendFileLocationMutationAsync(
            _profile,
            _session,
            capability,
            new FileLocationMutationRequest(kind, method, parameters),
            cancellationToken).ConfigureAwait(false);
    }

    private static MutationResult RemoteMountResult(
        string operation,
        FileLocationMutationTransportResult transportResult) =>
        RemoteMountResult(
            operation,
            transportResult.Status switch
            {
                FileLocationMutationTransportStatus.ResponseReceived => MutationResultStatus.ConfirmedSuccess,
                FileLocationMutationTransportStatus.ConfirmedFailure when
                    transportResult.ErrorCategory == MutationErrorCategory.Permission => MutationResultStatus.PermissionDenied,
                FileLocationMutationTransportStatus.ConfirmedFailure => MutationResultStatus.ConfirmedFailure,
                FileLocationMutationTransportStatus.CancelledBeforeSubmission => MutationResultStatus.CancelledBeforeSubmission,
                FileLocationMutationTransportStatus.CancellationRequestedAfterSubmission => MutationResultStatus.CancellationRequestedAfterSubmission,
                FileLocationMutationTransportStatus.SubmittedButUnverified => MutationResultStatus.SubmittedButUnverified,
                _ => MutationResultStatus.Unsupported,
            },
            submitted: transportResult.Status is not FileLocationMutationTransportStatus.CancelledBeforeSubmission and
                not FileLocationMutationTransportStatus.Unsupported,
            errorCategory: transportResult.ErrorCategory,
            tag: transportResult.DiagnosticTag);

    private static MutationResult RemoteMountResult(
        string operation,
        MutationResultStatus status,
        bool submitted = false,
        bool requiresRefresh = false,
        MutationErrorCategory? errorCategory = null,
        string? tag = null)
    {
        var succeeded = status == MutationResultStatus.ConfirmedSuccess ? 1 : 0;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0;
        var failed = succeeded == 0 && unknown == 0 &&
                     status != MutationResultStatus.CancelledBeforeSubmission &&
                     status != MutationResultStatus.Unsupported ? 1 : 0;
        return new MutationResult(
            1,
            status,
            operation,
            submitted,
            requiresRefresh: requiresRefresh || status is MutationResultStatus.ConfirmedSuccess or
                MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission,
            new MutationResultCounts(succeeded, failed, unknown),
            errorCategory,
            diagnosticTag: tag);
    }

    private static bool IsMountAuthenticationFailure(DsmException error) =>
        error.AuthenticationFailure || error.Code is 106 or 107 or 119 or 401;
}
