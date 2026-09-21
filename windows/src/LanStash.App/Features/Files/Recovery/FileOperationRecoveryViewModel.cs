using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Features.Files.Mutations;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files;

public sealed record FileOperationReviewEntry(Guid Id, Guid ProfileId, string Operation, string SourcePath,
    string DestinationPath, string Name, bool IsDirectory, long Size, DateTimeOffset? ModifiedAt = null, bool RequiresTimestamp = false)
{
    public string OperationLabelKey => Operation switch
    {
        "copyFile" => "FileCopyMove_Copy_Button",
        "moveFile" => "FileCopyMove_Move_Button",
        "moveToRecycle" => "FileRecycleMoveAction",
        _ => "FileRecycleRestoreAction",
    };
}

// 两类接口保持各自的身份和结果约束，仅共享只读核对的交互状态。
public sealed class FileOperationRecoveryViewModel : ObservableObject, IDisposable
{
    private sealed record Evidence(MutationResult Result, FileItem? ConfirmedItem, bool EnvelopeMatches);
    private readonly Func<CancellationToken, Task<IReadOnlyList<FileOperationReviewEntry>>> _load;
    private readonly Func<FileOperationReviewEntry, CancellationToken, Task<Evidence?>> _review;
    private readonly Action<Guid> _acknowledge;
    private readonly Action<FileOperationReviewEntry> _clearBlocker;
    private readonly Func<Guid> _currentProfile;
    private readonly Func<bool> _supports;
    private readonly Guid _profileId;
    private CancellationTokenSource? _request;
    private bool _disposed, _busy;
    private string? _messageKey;
    private IReadOnlyList<FileOperationReviewEntry> _items = [];
    private FileOperationReviewEntry? _selected;
    private long _generation;

    public FileOperationRecoveryViewModel(IFileCopyMoveRepository repository, Guid profileId, FileCopyMoveReviewBlocker blocker)
    {
        if (profileId == Guid.Empty || repository.ProfileId != profileId) throw new ArgumentException("file.review.profile-mismatch");
        _profileId = profileId; _currentProfile = () => repository.ProfileId; _supports = () => repository.SupportsCopyMoveReview;
        _load = async token => (await repository.GetCopyMoveReviewsAsync(token)).Select(item => new FileOperationReviewEntry(item.Id,
            item.ProfileId, item.Operation == FileCopyMoveOperation.Copy ? "copyFile" : item.Operation == FileCopyMoveOperation.Move ? "moveFile" : "",
            item.SourcePath, item.DestinationPath, item.Name, item.IsDirectory, item.Size)).ToArray();
        _review = async (entry, token) =>
        {
            var result = await repository.ReviewCopyMoveAsync(entry.Id, token);
            return result is null ? null : new Evidence(result.Result, result.ConfirmedItem, !result.SkippedExisting);
        };
        _acknowledge = repository.AcknowledgeCopyMoveReview;
        _clearBlocker = entry => blocker.Clear(new(profileId,
            entry.Operation == "copyFile" ? FileCopyMoveOperation.Copy : FileCopyMoveOperation.Move, entry.SourcePath, Parent(entry.DestinationPath)));
    }

    public FileOperationRecoveryViewModel(IFileRecycleRepository repository, Guid profileId, FileRecycleReviewBlocker blocker)
    {
        if (profileId == Guid.Empty || repository.ProfileId != profileId) throw new ArgumentException("file.review.profile-mismatch");
        _profileId = profileId; _currentProfile = () => repository.ProfileId; _supports = () => repository.SupportsRecycleReview;
        _load = async token => (await repository.GetRecycleReviewsAsync(token)).Select(item => new FileOperationReviewEntry(item.Id,
            item.ProfileId, item.IsRestore ? "restoreFromRecycle" : "moveToRecycle", item.SourcePath, item.DestinationPath,
            item.Name, item.IsDirectory, item.Size, item.ModifiedAt, true)).ToArray();
        _review = async (entry, token) =>
        {
            var result = await repository.ReviewRecycleAsync(entry.Id, token);
            return result is null ? null : new Evidence(result.Result, result.ConfirmedItem,
                result.SourcePath == entry.SourcePath && result.DestinationPath == entry.DestinationPath);
        };
        _acknowledge = repository.AcknowledgeRecycleReview;
        _clearBlocker = entry => blocker.Clear(new(profileId,
            entry.Operation == "restoreFromRecycle" ? FileRecycleOperation.Restore : FileRecycleOperation.MoveToRecycle, entry.SourcePath, entry.DestinationPath));
    }

    public IReadOnlyList<FileOperationReviewEntry> Items { get => _items; private set => SetProperty(ref _items, value); }
    public FileOperationReviewEntry? Selected
    {
        get => _selected;
        set
        {
            if (IsBusy || value is not null && !Items.Contains(value)) return;
            if (SetProperty(ref _selected, value)) RaisePropertyChanged(nameof(CanReview));
        }
    }
    public bool IsBusy { get => _busy; private set { if (SetProperty(ref _busy, value)) RaisePropertyChanged(nameof(CanReview)); } }
    public bool CanReview => !_disposed && !IsBusy && Selected is not null && _currentProfile() == _profileId && _supports();
    public string? MessageKey { get => _messageKey; private set => SetProperty(ref _messageKey, value); }
    public int ConfirmedCount { get; private set; }

    public async Task RefreshAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (IsBusy) return;
        var selectedId = Selected?.Id;
        var generation = Begin();
        var token = _request!.Token;
        try
        {
            var items = (await _load(token)).ToArray();
            if (!Current(generation, token)) return;
            if (items.Any(item => !Valid(item)) || items.Select(item => item.Id).Distinct().Count() != items.Length)
                throw new InvalidDataException("copy-move.review.invalid-snapshot");
            Items = Array.AsReadOnly(items);
            _selected = items.FirstOrDefault(item => item.Id == selectedId) ?? items.FirstOrDefault();
            RaisePropertyChanged(nameof(Selected));
            MessageKey = items.Length == 0 ? "FileOperationReviewEmpty" : null;
        }
        catch (Exception error) { if (Current(generation, token)) MessageKey = ErrorKey(error); }
        finally { End(generation); }
    }

    public async Task ReviewSelectedAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!CanReview || Selected is not { } selected) return;
        var generation = Begin();
        var token = _request!.Token;
        try
        {
            var outcome = await _review(selected, token);
            if (!Current(generation, token)) return;
            if (outcome?.Result.Status == MutationResultStatus.ConfirmedSuccess && outcome.EnvelopeMatches &&
                outcome.Result.Operation == selected.Operation && outcome.ConfirmedItem is { } item &&
                item.Path == selected.DestinationPath && item.Name == selected.Name && item.IsDirectory == selected.IsDirectory &&
                (selected.IsDirectory || item.Size == selected.Size) && (!selected.RequiresTimestamp || item.ModifiedAt == selected.ModifiedAt))
            {
                _acknowledge(selected.Id);
                _clearBlocker(selected);
                ConfirmedCount++;
                Items = Array.AsReadOnly(Items.Where(item => item.Id != selected.Id).ToArray());
                _selected = Items.FirstOrDefault(); RaisePropertyChanged(nameof(Selected));
                MessageKey = "FileOperationReviewConfirmed";
            }
            else MessageKey = outcome?.Result.ErrorCategory == MutationErrorCategory.Authentication ? "FileOperationReviewSignIn"
                : outcome is null ? "FileOperationReviewMissing" : "FileOperationReviewPending";
        }
        catch (Exception error) { if (Current(generation, token)) MessageKey = ErrorKey(error); }
        finally { End(generation); }
    }

    private bool Valid(FileOperationReviewEntry item) => item.Id != Guid.Empty && item.ProfileId == _profileId && item.Size >= 0 &&
        item.Operation is "copyFile" or "moveFile" or "moveToRecycle" or "restoreFromRecycle" &&
        FileMutationViewModel.IsCanonicalAbsolutePath(item.SourcePath) && FileMutationViewModel.IsCanonicalAbsolutePath(item.DestinationPath) &&
        !string.IsNullOrWhiteSpace(item.Name) && item.SourcePath.EndsWith("/" + item.Name, StringComparison.Ordinal) &&
        item.DestinationPath.EndsWith("/" + item.Name, StringComparison.Ordinal);
    private static string Parent(string path) => path[..path.LastIndexOf('/')];
    private static string ErrorKey(Exception error) => error is DsmException dsm &&
        (dsm.AuthenticationFailure || dsm.Code is 106 or 107 or 119 or 401) ? "FileOperationReviewSignIn" : "FileOperationReviewFailed";
    private long Begin()
    {
        _request?.Dispose(); _request = new(); IsBusy = true; MessageKey = null;
        return ++_generation;
    }
    private bool Current(long generation, CancellationToken token) => !_disposed && generation == _generation &&
        !token.IsCancellationRequested && _currentProfile() == _profileId;
    private void End(long generation)
    {
        if (_disposed || generation != _generation) return;
        _request?.Dispose(); _request = null; IsBusy = false;
    }
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; _generation++; _request?.Cancel(); _request?.Dispose(); _request = null;
    }
}
