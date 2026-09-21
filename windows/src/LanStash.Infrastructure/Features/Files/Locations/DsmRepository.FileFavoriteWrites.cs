using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    bool IFileLocationsRepository.CanWriteFavorites => _profile.Id != Guid.Empty && _profile.Id == _session.ProfileId && !string.IsNullOrWhiteSpace(_session.Sid) &&
        HasFavoriteCapability() &&
        _api is IFileLocationMutationTransport;

    private bool HasFavoriteCapability() => _capabilities.TryGetValue("SYNO.FileStation.Favorite", out var capability) &&
        capability.Name == "SYNO.FileStation.Favorite" && capability.MinVersion <= 2 && capability.MaxVersion >= 2 &&
        NasServiceFormatAndPathSupported(capability);

    Task<MutationResult> IFileLocationsRepository.AddFavoriteAsync(string path, string? name, CancellationToken cancellationToken) =>
        ChangeFavoriteAsync(path, name, add: true, cancellationToken);

    Task<MutationResult> IFileLocationsRepository.RemoveFavoriteAsync(string path, CancellationToken cancellationToken) =>
        ChangeFavoriteAsync(path, null, add: false, cancellationToken);

    private async Task<MutationResult> ChangeFavoriteAsync(string path, string? name, bool add, CancellationToken token)
    {
        var operation = add ? "addFavorite" : "removeFavorite";
        if (token.IsCancellationRequested) return FavoriteWriteResult(operation, MutationResultStatus.CancelledBeforeSubmission);
        try
        {
            path = CanonicalDirectoryPath(path);
            name = add ? (string.IsNullOrWhiteSpace(name) ? path[(path.LastIndexOf('/') + 1)..] : name).Trim() : null;
            if (add) ValidateLocationName(name!);
        }
        catch (Exception error) when (error is InvalidDataException or ArgumentException)
        { return FavoriteWriteResult(operation, MutationResultStatus.ConfirmedFailure, errorCategory: MutationErrorCategory.Validation); }
        if (!((IFileLocationsRepository)this).CanWriteFavorites) return FavoriteWriteResult(operation, MutationResultStatus.Unsupported, errorCategory: MutationErrorCategory.Unsupported);
        var shared = ServiceMutations; var scope = ServiceScope();
        try { if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false)) return FavoriteWriteResult(operation, MutationResultStatus.ConfirmedFailure, errorCategory: MutationErrorCategory.Conflict); }
        catch (OperationCanceledException) { return FavoriteWriteResult(operation, MutationResultStatus.CancelledBeforeSubmission); }
        try
        {
            if (shared.FavoritePending.TryGetValue((scope, path), out var pending))
                return pending.Add == add && pending.Name == name ? await ReviewFavoriteOperationAsync(pending, token).ConfigureAwait(false) :
                    FavoriteWriteResult(operation, MutationResultStatus.ConfirmedFailure, errorCategory: MutationErrorCategory.Conflict);
            try
            {
                var before = await CompleteFavoritesForWriteAsync(token).ConfigureAwait(false);
                var existing = before.Items.SingleOrDefault(item => item.Path == path);
                if (add && existing is not null)
                    return FavoriteWriteResult(operation, existing.Name == name ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.ConfirmedFailure,
                        errorCategory: existing.Name == name ? null : MutationErrorCategory.Conflict);
                if (!add && existing is null) return FavoriteWriteResult(operation, MutationResultStatus.ConfirmedSuccess);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return FavoriteWriteResult(operation, MutationResultStatus.CancelledBeforeSubmission); }
            catch (DsmException error) { return FavoriteWriteResult(operation, MutationResultStatus.ConfirmedFailure, errorCategory: FavoriteErrorCategory(error)); }
            catch (Exception) { return FavoriteWriteResult(operation, MutationResultStatus.ConfirmedFailure, errorCategory: MutationErrorCategory.Server); }
            var state = new FavoriteMutationOperation(scope, path, name, add);
            shared.FavoritePending.Add((scope, path), state);
            try
            {
                var parameters = new Dictionary<string, string> { ["path"] = path };
                if (add) parameters["name"] = name!;
                var result = await ((IFileLocationMutationTransport)_api).SendFileLocationMutationAsync(_profile, _session,
                    _capabilities["SYNO.FileStation.Favorite"], new(add ? FileLocationMutationKind.AddFavorite : FileLocationMutationKind.RemoveFavorite,
                        add ? "add" : "delete", parameters), token).ConfigureAwait(false);
                if (result.Status is FileLocationMutationTransportStatus.ConfirmedFailure or FileLocationMutationTransportStatus.Unsupported or FileLocationMutationTransportStatus.CancelledBeforeSubmission)
                {
                    shared.FavoritePending.Remove((scope, path));
                    return FavoriteWriteResult(operation, result.Status switch
                    {
                        FileLocationMutationTransportStatus.Unsupported => MutationResultStatus.Unsupported,
                        FileLocationMutationTransportStatus.CancelledBeforeSubmission => MutationResultStatus.CancelledBeforeSubmission,
                        _ => result.ErrorCategory == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure
                    }, submitted: result.Status == FileLocationMutationTransportStatus.ConfirmedFailure, errorCategory: result.ErrorCategory);
                }
            }
            catch (Exception) { /* 发送边界之后不能假定未执行，保留路径锁并只读核查。 */ }
            return await ReviewFavoriteOperationAsync(state, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    async Task<IReadOnlyList<FileFavoriteMutationRecovery>> IFileLocationsRepository.GetFavoriteMutationRecoveriesAsync(CancellationToken cancellationToken)
    {
        if (!((IFileLocationsRepository)this).CanWriteFavorites) return [];
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return shared.FavoritePending.Values.Where(item => item.Scope == scope)
            .Select(item => new FileFavoriteMutationRecovery(_profile.Id, item.Path, item.Name, item.Add)).ToArray(); }
        finally { shared.Gate.Release(); }
    }

    async Task<MutationResult?> IFileLocationsRepository.ReviewFavoriteMutationAsync(string path, CancellationToken cancellationToken)
    {
        if (!((IFileLocationsRepository)this).CanWriteFavorites) return FavoriteWriteResult("favoriteReview", MutationResultStatus.Unsupported, errorCategory: MutationErrorCategory.Unsupported);
        var shared = ServiceMutations; if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return null;
        try { return shared.FavoritePending.TryGetValue((ServiceScope(), path), out var state) ? await ReviewFavoriteOperationAsync(state, cancellationToken).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }

    private async Task<FileFavoriteSnapshot> CompleteFavoritesForWriteAsync(CancellationToken token)
    {
        var snapshot = await LoadFavoriteLocationsAsync(token, requireUnambiguousNames: true).ConfigureAwait(false);
        if (snapshot.Status != FileLocationSectionStatus.Available || snapshot.Completion != FileLocationCompletion.Complete)
            throw new InvalidDataException("favorite.incomplete-list");
        return snapshot;
    }

    private async Task<MutationResult> ReviewFavoriteOperationAsync(FavoriteMutationOperation state, CancellationToken token)
    {
        var operation = state.Add ? "addFavorite" : "removeFavorite";
        var category = MutationErrorCategory.Unknown;
        if (!token.IsCancellationRequested)
        try
        {
            var snapshot = await CompleteFavoritesForWriteAsync(token).ConfigureAwait(false);
            var current = snapshot.Items.SingleOrDefault(item => item.Path == state.Path);
            if (state.Add ? current?.Name == state.Name : current is null)
            {
                ServiceMutations.FavoritePending.Remove((state.Scope, state.Path));
                return FavoriteWriteResult(operation, MutationResultStatus.ConfirmedSuccess, submitted: true);
            }
        }
        catch (DsmException error) { category = FavoriteErrorCategory(error); }
        catch (Exception) { category = MutationErrorCategory.Network; }
        return FavoriteWriteResult(operation, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            submitted: true, errorCategory: category);
    }

    private static MutationErrorCategory FavoriteErrorCategory(DsmException error) =>
        IsMountAuthenticationFailure(error) ? MutationErrorCategory.Authentication : ServiceErrorCategory(error);

    private static MutationResult FavoriteWriteResult(string operation, MutationResultStatus status, bool submitted = false, MutationErrorCategory? errorCategory = null)
    {
        var success = status == MutationResultStatus.ConfirmedSuccess ? 1 : 0;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0;
        var failed = success == 0 && unknown == 0 && status != MutationResultStatus.CancelledBeforeSubmission ? 1 : 0;
        return new(1, status, operation, submitted, status == MutationResultStatus.ConfirmedSuccess || unknown > 0,
            new(success, failed, unknown), errorCategory);
    }
    private sealed record FavoriteMutationOperation(string Scope, string Path, string? Name, bool Add);
}
