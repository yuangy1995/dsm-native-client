using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int FavoriteWriteApiVersion = 2;
    // 当前 IDsmApiClient 没有 Locations 专用提交边界，生产写入口必须保持关闭。
    private const bool FileLocationWritesEnabled = false;

    bool IFileLocationsRepository.CanWriteFavorites =>
        FileLocationWritesEnabled &&
        HasFixedVersionCapability("SYNO.FileStation.Favorite") &&
        _api is IFileLocationMutationTransport;

    async Task<MutationResult> IFileLocationsRepository.AddFavoriteAsync(
        string path,
        string? name,
        CancellationToken cancellationToken)
    {
        if (!HasFixedVersionCapability("SYNO.FileStation.Favorite"))
        {
            return FavoriteWriteResult(
                "addFavorite",
                MutationResultStatus.Unsupported,
                errorCategory: MutationErrorCategory.Unsupported,
                tag: "favorite.add.unsupported");
        }
        if (string.IsNullOrWhiteSpace(path) || !path.StartsWith('/') ||
            path.EndsWith('/') || path.Contains("//") || path.Contains('\\') ||
            path.Length > 4096)
        {
            return FavoriteWriteResult(
                "addFavorite",
                MutationResultStatus.ConfirmedFailure,
                errorCategory: MutationErrorCategory.Validation,
                tag: "favorite.add.invalid-path");
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return FavoriteWriteResult(
                "addFavorite",
                MutationResultStatus.CancelledBeforeSubmission,
                tag: "favorite.add.cancelled");
        }
        if (!((IFileLocationsRepository)this).CanWriteFavorites)
        {
            return FavoriteWriteResult(
                "addFavorite",
                MutationResultStatus.Unsupported,
                errorCategory: MutationErrorCategory.Unsupported,
                tag: "favorite.add.transport-unsupported");
        }
        try
        {
            var parameters = new Dictionary<string, string>
            {
                ["path"] = path,
            };
            if (!string.IsNullOrWhiteSpace(name))
            {
                parameters["name"] = name.Trim();
            }
            var transportResult = await SendFileLocationMutationAsync(
                "SYNO.FileStation.Favorite",
                FileLocationMutationKind.AddFavorite,
                "add",
                parameters,
                cancellationToken).ConfigureAwait(false);
            return FavoriteWriteResult("addFavorite", transportResult);
        }
        catch (OperationCanceledException)
        {
            return FavoriteWriteResult(
                "addFavorite",
                MutationResultStatus.CancellationRequestedAfterSubmission,
                submitted: true,
                errorCategory: MutationErrorCategory.Network,
                tag: "favorite.add.cancelled");
        }
        catch (DsmException error) when (IsMountAuthenticationFailure(error))
        {
            throw;
        }
        catch (DsmException error)
        {
            return FavoriteWriteResult(
                "addFavorite",
                error.Code == 105 ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                submitted: true,
                errorCategory: error.Code == 105 ? MutationErrorCategory.Permission : MutationErrorCategory.Server,
                tag: "favorite.add.server-error");
        }
        catch (Exception)
        {
            return FavoriteWriteResult(
                "addFavorite",
                MutationResultStatus.SubmittedButUnverified,
                submitted: true,
                errorCategory: MutationErrorCategory.Network,
                tag: "favorite.add.network-error");
        }
    }

    async Task<MutationResult> IFileLocationsRepository.RemoveFavoriteAsync(
        string path,
        CancellationToken cancellationToken)
    {
        if (!HasFixedVersionCapability("SYNO.FileStation.Favorite"))
        {
            return FavoriteWriteResult(
                "removeFavorite",
                MutationResultStatus.Unsupported,
                errorCategory: MutationErrorCategory.Unsupported,
                tag: "favorite.remove.unsupported");
        }
        if (string.IsNullOrWhiteSpace(path) || !path.StartsWith('/') ||
            path.EndsWith('/') || path.Contains("//") || path.Contains('\\') ||
            path.Length > 4096)
        {
            return FavoriteWriteResult(
                "removeFavorite",
                MutationResultStatus.ConfirmedFailure,
                errorCategory: MutationErrorCategory.Validation,
                tag: "favorite.remove.invalid-path");
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return FavoriteWriteResult(
                "removeFavorite",
                MutationResultStatus.CancelledBeforeSubmission,
                tag: "favorite.remove.cancelled");
        }
        if (!((IFileLocationsRepository)this).CanWriteFavorites)
        {
            return FavoriteWriteResult(
                "removeFavorite",
                MutationResultStatus.Unsupported,
                errorCategory: MutationErrorCategory.Unsupported,
                tag: "favorite.remove.transport-unsupported");
        }
        try
        {
            var parameters = new Dictionary<string, string>
            {
                ["path"] = path,
            };
            var transportResult = await SendFileLocationMutationAsync(
                "SYNO.FileStation.Favorite",
                FileLocationMutationKind.RemoveFavorite,
                "delete",
                parameters,
                cancellationToken).ConfigureAwait(false);
            return FavoriteWriteResult("removeFavorite", transportResult);
        }
        catch (OperationCanceledException)
        {
            return FavoriteWriteResult(
                "removeFavorite",
                MutationResultStatus.CancellationRequestedAfterSubmission,
                submitted: true,
                errorCategory: MutationErrorCategory.Network,
                tag: "favorite.remove.cancelled");
        }
        catch (DsmException error) when (IsMountAuthenticationFailure(error))
        {
            throw;
        }
        catch (DsmException error)
        {
            return FavoriteWriteResult(
                "removeFavorite",
                error.Code == 105 ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                submitted: true,
                errorCategory: error.Code == 105 ? MutationErrorCategory.Permission : MutationErrorCategory.Server,
                tag: "favorite.remove.server-error");
        }
        catch (Exception)
        {
            return FavoriteWriteResult(
                "removeFavorite",
                MutationResultStatus.SubmittedButUnverified,
                submitted: true,
                errorCategory: MutationErrorCategory.Network,
                tag: "favorite.remove.network-error");
        }
    }

    private async Task<FileLocationMutationTransportResult> SendFileLocationMutationAsync(
        string apiName,
        FileLocationMutationKind kind,
        string method,
        IReadOnlyDictionary<string, string> parameters,
        CancellationToken cancellationToken)
    {
        if (_api is not IFileLocationMutationTransport transport ||
            !_capabilities.TryGetValue(apiName, out var capability) ||
            !string.Equals(capability.Name, apiName, StringComparison.Ordinal))
        {
            return new(
                FileLocationMutationTransportStatus.Unsupported,
                ErrorCategory: MutationErrorCategory.Unsupported,
                DiagnosticTag: "file.locations.write.transport-unsupported");
        }
        return await transport.SendFileLocationMutationAsync(
            _profile,
            _session,
            capability,
            new FileLocationMutationRequest(kind, method, parameters),
            cancellationToken).ConfigureAwait(false);
    }

    private static MutationResult FavoriteWriteResult(
        string operation,
        FileLocationMutationTransportResult transportResult) =>
        FavoriteWriteResult(
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

    private static MutationResult FavoriteWriteResult(
        string operation,
        MutationResultStatus status,
        bool submitted = false,
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
            requiresRefresh: status is MutationResultStatus.ConfirmedSuccess or
                MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission,
            new MutationResultCounts(succeeded, failed, unknown),
            errorCategory,
            diagnosticTag: tag);
    }
}
