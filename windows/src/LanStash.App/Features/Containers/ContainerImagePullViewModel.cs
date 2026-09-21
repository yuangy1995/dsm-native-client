using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Containers;

public sealed record ContainerImagePullItem(ContainerImagePullResult Result)
{
    public string Name => $"{Result.Repository}:{Result.Tag}";
    public double Progress => Result.Percentage ?? 0;
    public bool IsIndeterminate => Result.Stage == ContainerImagePullStage.Downloading && Result.Percentage is null;
    public string StatusText => Result.Outcome.ErrorCategory == MutationErrorCategory.Authentication ? L.Get("ContainerPullSignIn") :
        Result.Stage switch
        {
            ContainerImagePullStage.Downloading => Result.Percentage is { } progress ? L.Format("ContainerPullPercent", progress) : L.Get("ContainerPullDownloading"),
            ContainerImagePullStage.Ready => L.Get("ContainerPullReady"),
            ContainerImagePullStage.AwaitingReceipt => L.Get("ContainerPullNoReceipt"),
            ContainerImagePullStage.NeedsReview => L.Get("ContainerPullReviewNeeded"),
            _ => L.Get(Result.Outcome.ErrorCategory switch
            {
                MutationErrorCategory.Permission => "ContainerPullPermission",
                MutationErrorCategory.Conflict => "ContainerPullConflict",
                MutationErrorCategory.Unsupported => "ContainerPullUnavailable",
                _ => Result.Outcome.Status == MutationResultStatus.CancelledBeforeSubmission ? "ContainerPullNotSent" : "ContainerPullFailed"
            })
        };
    private static LocalizationService L => LocalizationService.Current;
}

public sealed class ContainerImagePullViewModel : ObservableObject, IDisposable
{
    private IContainerManagerRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed;
    private ContainerImagePullRequest? _confirmation;
    private string? _selectedRepository, _selectedTag;
    public ObservableCollection<ContainerImagePullItem> Items { get; } = [];
    public bool IsBusy { get; private set; }
    public bool IsSubmitting { get; private set; }
    public bool HasConfirmation => _confirmation is not null;
    public bool RequiresReconnect { get; private set; }
    public bool IsAvailable => !_disposed && _repository?.CanPullImages == true && !RequiresReconnect;
    public bool CanConfirm => IsAvailable && !IsBusy && ContainerImagePullRules.IsValidTarget(_selectedRepository, _selectedTag) &&
        !Items.Any(item => Pending(item.Result) && item.Result.Repository == _selectedRepository && item.Result.Tag == _selectedTag);
    public bool CanSubmit => CanConfirm && _confirmation is not null;
    public bool CanReview => !_disposed && _repository is not null && !IsBusy && !RequiresReconnect;
    public bool HasPollableTasks => CanReview && Items.Any(item => item.Result.Stage == ContainerImagePullStage.Downloading);
    public bool NeedsParentRefresh { get; private set; }
    public string? ErrorMessage { get; private set; }

    public async Task ActivateAsync(IContainerManagerRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Cancel(); _repository = repository; Items.Clear(); IsBusy = RequiresReconnect = NeedsParentRefresh = false;
        _confirmation = null; _selectedRepository = _selectedTag = null; ErrorMessage = null; Notify(); await ReviewAsync();
    }
    public void SetTarget(string? repository, string? tag)
    {
        if (_disposed || (_selectedRepository == repository && _selectedTag == tag)) return;
        _selectedRepository = repository; _selectedTag = tag; _confirmation = null; Notify();
    }
    public void Confirm(bool confirmed)
    {
        _confirmation = confirmed && CanConfirm ? new(_repository!.ProfileId, _selectedRepository!, _selectedTag!, Guid.NewGuid(), true) : null;
        Notify();
    }
    public async Task SubmitAsync()
    {
        if (!CanSubmit || _repository is null) return;
        var repository = _repository; var confirmed = _confirmation!; var request = Begin();
        IsBusy = IsSubmitting = true; _confirmation = null; ErrorMessage = null; NeedsParentRefresh = true; Notify();
        try
        {
            var result = await repository.PullImageAsync(confirmed, request.Token);
            if (Current(request, repository)) Accept(result);
        }
        catch
        {
            if (Current(request, repository)) Accept(new(confirmed.RequestId, confirmed.Repository, confirmed.Tag, ContainerImagePullStage.AwaitingReceipt, null,
                new(1, MutationResultStatus.SubmittedButUnverified, "pullContainerImage", true, true, new(0, 0, 1))));
        }
        finally { if (Current(request, repository)) { IsBusy = IsSubmitting = false; Notify(); } }
    }
    public async Task ReviewAsync(bool automatic = false)
    {
        if (!CanReview || _repository is null || automatic && !HasPollableTasks) return;
        var repository = _repository; var request = Begin(); IsBusy = true; ErrorMessage = null;
        // 用户手动刷新会使确认失效；后台任务轮询不改变尚未提交的目标确认。
        if (!automatic) _confirmation = null;
        Notify();
        try
        {
            var pending = await repository.GetImagePullRecoveriesAsync(request.Token); if (!Current(request, repository)) return;
            foreach (var result in pending) Accept(result, isCached: true);
            var targets = Items.Select(item => item.Result).Where(result => Pending(result) &&
                (!automatic || result.Stage == ContainerImagePullStage.Downloading)).ToArray();
            foreach (var target in targets)
            {
                var result = await repository.ReviewImagePullAsync(target.RequestId, request.Token); if (!Current(request, repository)) return;
                if (result is not null) Accept(result);
            }
        }
        catch (Exception error)
        {
            if (Current(request, repository))
            {
                RequiresReconnect |= error is DsmException { AuthenticationFailure: true };
                ErrorMessage = L.Get(RequiresReconnect ? "ContainerPullSignIn" : "ContainerPullReadFailed");
            }
        }
        finally { if (Current(request, repository)) { IsBusy = false; Notify(); } }
    }
    private void Accept(ContainerImagePullResult result, bool isCached = false)
    {
        var index = Items.ToList().FindIndex(item => item.Result.RequestId == result.RequestId);
        if (index < 0) Items.Add(new(result)); else Items[index] = new(result);
        NeedsParentRefresh |= result.Outcome.Submitted;
        // 恢复记录可能来自失效的旧会话；只有当前查询/提交的认证结果能锁定新连接。
        if (!isCached) RequiresReconnect |= result.Outcome.ErrorCategory == MutationErrorCategory.Authentication;
    }
    private static bool Pending(ContainerImagePullResult result) => result.Stage is not (ContainerImagePullStage.Ready or ContainerImagePullStage.Rejected);
    public void Dispose()
    {
        if (_disposed) return; _disposed = true; Cancel(); _repository = null; _confirmation = null;
        IsBusy = IsSubmitting = false; Items.Clear(); Notify();
    }
    private Request Begin() { Cancel(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void Cancel() { _generation++; var old = _cancellation; _cancellation = null; old?.Cancel(); old?.Dispose(); }
    private bool Current(Request request, IContainerManagerRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record Request(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
