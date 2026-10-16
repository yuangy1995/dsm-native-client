using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Permissions;

public sealed class FilePermissionViewModel(IFilePermissionRepository repository, string path) : ObservableObject, IDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private CancellationTokenSource? _membersCancellation;
    private long _membersGeneration;
    private bool _disposed;
    public FilePermissionSnapshot? Snapshot { get; private set; }
    public List<FileAclRule> Rules { get; } = [];
    public string PosixMode { get; set; } = "000";
    public FileSharePrincipal? Owner { get; set; }
    public FileSharePrincipal? Group { get; set; }
    public bool Recursive { get; set; }
    public bool ConfirmedScope { get; set; }
    public bool ConfirmedOwner { get; set; }
    public bool ConfirmedAccessRemoval { get; set; }
    public bool IsBusy { get; private set; }
    public bool IsPending { get; private set; }
    public bool HasAttemptedSave { get; private set; }
    public bool LoadFailed { get; private set; }
    public bool MembersFailed { get; private set; }
    public bool IsLoadingMembers { get; private set; }
    public IReadOnlyList<FileSharePrincipal> Members { get; private set; } = [];
    public FilePermissionProgress? Progress { get; private set; }
    public bool IsEditable => !_disposed && !IsBusy && !IsPending && Snapshot is { } snapshot &&
        (snapshot.CanChangePermissions || snapshot.Owner?.CanChange == true);
    public bool RulesChanged => Snapshot is { IsAcl: true } snapshot && !Rules.SequenceEqual(snapshot.Rules.Where(rule => rule.Level == 0));
    public bool HasChanges => RulesChanged || Snapshot is { IsAcl: false } snapshot && PosixMode != snapshot.PosixMode || Owner is not null || Group is not null;
    public bool CanSave => IsEditable && HasChanges && ConfirmedAccessRemoval &&
        (!Recursive || Snapshot?.Target.IsDirectory == true && ConfirmedScope) &&
        (Owner is null && Group is null || ConfirmedOwner);
    public string? MessageKey => LoadFailed ? "FilePermissionsLoadFailed" : Progress is { HasPartialFailure: true } ? "FilePermissionsPartial" :
        Progress?.Outcome.Status switch
        {
            MutationResultStatus.ConfirmedSuccess => "FilePermissionsSaved",
            MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "FilePermissionsPending",
            MutationResultStatus.PermissionDenied => "FilePermissionsDenied",
            MutationResultStatus.Unsupported => "FilePermissionsUnsupported",
            MutationResultStatus.ConfirmedFailure => Progress.Outcome.ErrorCategory == MutationErrorCategory.Conflict ? "FilePermissionsChanged" : "FilePermissionsSaveFailed",
            _ => null,
        };

    public async Task LoadAsync()
    {
        if (_disposed || IsBusy) return;
        IsBusy = true; LoadFailed = false; Notify();
        try
        {
            var progress = await repository.ReviewFilePermissionsAsync(path, _lifetime.Token);
            var snapshot = await repository.LoadFilePermissionsAsync(path, _lifetime.Token);
            if (_disposed) return;
            Progress = progress;
            IsPending = progress?.Outcome.RequiresRefresh == true;
            Snapshot = snapshot;
            ResetDraft();
        }
        catch { if (!_disposed) { LoadFailed = true; Snapshot = null; } }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
    }

    public void DraftChanged()
    {
        ConfirmedScope = ConfirmedOwner = ConfirmedAccessRemoval = false;
        Notify();
    }
    public void Notify() => RaisePropertyChanged(string.Empty);

    public async Task LoadMembersAsync(string prefix)
    {
        if (_disposed) return;
        _membersCancellation?.Cancel();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        _membersCancellation = cancellation;
        var generation = ++_membersGeneration;
        IsLoadingMembers = true; MembersFailed = false; Notify();
        try
        {
            var items = await repository.ListFileSharePrincipalsAsync(prefix, cancellation.Token);
            if (!_disposed && generation == _membersGeneration) Members = items;
        }
        catch { if (!_disposed && generation == _membersGeneration) { Members = []; MembersFailed = true; } }
        finally { if (!_disposed && generation == _membersGeneration) { IsLoadingMembers = false; _membersCancellation = null; Notify(); } }
    }

    public async Task SaveAsync()
    {
        if (!CanSave || Snapshot is not { } snapshot) return;
        var request = new FilePermissionChange(snapshot, RulesChanged ? Rules.ToArray() : null,
            !snapshot.IsAcl && PosixMode != snapshot.PosixMode ? PosixMode : null, Owner, Group, Recursive,
            ConfirmedScope, ConfirmedOwner, ConfirmedAccessRemoval);
        HasAttemptedSave = true;
        IsBusy = true; Notify();
        try
        {
            var progress = await repository.ChangeFilePermissionsAsync(request, _lifetime.Token);
            if (_disposed) return;
            Progress = progress; IsPending = progress.Outcome.RequiresRefresh;
            if (progress.Outcome.Status == MutationResultStatus.ConfirmedSuccess)
            {
                // 修改后重新载入；失败时撤掉旧快照，不能继续用旧授权编辑。
                Snapshot = null;
                var refreshed = await repository.LoadFilePermissionsAsync(path, _lifetime.Token);
                if (_disposed) return;
                Snapshot = refreshed;
                ResetDraft();
            }
        }
        catch { if (!_disposed) { LoadFailed = true; Snapshot = null; } }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
    }

    private void ResetDraft()
    {
        Rules.Clear(); Rules.AddRange(Snapshot!.Rules.Where(rule => rule.Level == 0));
        PosixMode = Snapshot.PosixMode ?? "000"; Owner = Group = null; Recursive = false;
        ConfirmedScope = ConfirmedOwner = ConfirmedAccessRemoval = false;
    }
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; _lifetime.Cancel(); _membersCancellation?.Cancel(); _lifetime.Dispose();
    }
}
