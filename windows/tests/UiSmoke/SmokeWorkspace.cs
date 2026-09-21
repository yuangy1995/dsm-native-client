using LanStash.Domain;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage;
using LanStash.App.Views;
using LanStash.App.Features.Files;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Features.Chat;
using LanStash.App.Features.Containers;
using LanStash.App.Features.Downloads;
using LanStash.App.Features.Transfers;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.VirtualMachines;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Features.Files.Locations;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.ViewModels;

// 仅由 LanStashUiSmoke=true 的测试构建编译，正式包不包含合成仓库。
public sealed partial class AppViewModel
{
    internal void InitializeSmokeLogin()
    {
        Profiles.Clear();
        ActiveProfile = null;
        Repository = null;
        if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") == "login-error")
            ErrorMessage = Localization.LocalizationService.Current.Get("WinShared35964d160c6c4b32") + " " +
                Localization.LocalizationService.Current.Get("WinShared36d42da6d6cea95f");
    }
    internal void InitializeSmokeWorkspace()
    {
        ActiveProfile = new NasProfile(Guid.Parse("11111111-1111-1111-1111-111111111111"),
            "Demo NAS", "example.invalid", null, string.Empty, false);
        Profiles.Add(ActiveProfile);
        Repository = new SmokeRepository();
        foreach (var module in Repository.AvailableModules) AvailableModules.Add(module);
    }
}

public class SmokeRecycleLocations : System.Reflection.DispatchProxy
{
    protected override object? Invoke(System.Reflection.MethodInfo? method, object?[]? args) => method!.Name switch
    {
        "get_ProfileId" => SmokeActivityProbe.Profile,
        "get_Availability" => new FileLocationsAvailability(false, true, false),
        "get_CanWriteFavorites" or "get_AllowsRemoteMountManagement" or "get_CanManageRemoteMountWorkflow" => false,
        "GetFavoriteMutationRecoveriesAsync" => Task.FromResult<IReadOnlyList<FileFavoriteMutationRecovery>>([]),
        "LoadSnapshotAsync" => Task.FromResult(new FileLocationsSnapshot(SmokeActivityProbe.Profile, new(false, true, false),
            new([], 0, 0, FileLocationCompletion.Complete, FileLocationSectionStatus.Unavailable),
            new([new(SmokeActivityProbe.Profile, "share", "/share", "/share/#recycle")], 1, 0, 0, false, FileLocationCompletion.Complete, FileLocationSectionStatus.Available),
            new([], 0, 0, [], false, FileLocationCompletion.Complete, FileLocationSectionStatus.Unavailable))),
        _ => throw new NotSupportedException(method.Name),
    };
}

internal sealed class SmokeLargeRecycleRepository(string state) : IFileRecycleRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public FileRecycleAvailability Availability => new(true, true, 2, 3);
    public List<string> Paths { get; } = [];
    public bool Cancelled { get; private set; }
    public Task<FileRecycleOutcome> MoveToRecycleAsync(MoveToRecycleRequest request, CancellationToken token = default) =>
        RunAsync(request.Target, request.RecycleLocation.RecyclePath + request.Target.Path[request.RecycleLocation.SharePath.Length..], token);
    public Task<FileRecycleOutcome> RestoreFromRecycleAsync(RestoreFromRecycleRequest request, CancellationToken token = default)
    {
        if (!FileRecycleViewModel.TryRestoreDestination(request.Target.Path, out var destination)) throw new InvalidOperationException("恢复目标不合法。");
        return RunAsync(request.Target, destination, token);
    }
    private async Task<FileRecycleOutcome> RunAsync(FileRecycleTarget target, string destination, CancellationToken token)
    {
        Paths.Add(target.Path); await Task.Delay(2, token);
        if (Paths.Count == 23)
        {
            if (state == "restore-throw-auth") throw new DsmException("synthetic", "synthetic", 119);
            if (state.EndsWith("cancel", StringComparison.Ordinal))
            {
                try { await Task.Delay(Timeout.Infinite, token); }
                catch (OperationCanceledException) { Cancelled = true; throw; }
            }
            if (state.EndsWith("unknown", StringComparison.Ordinal))
                return new(new(1, MutationResultStatus.SubmittedButUnverified, "recycle", true, true, new(0, 0, 1)), target.Path, destination);
            if (state.EndsWith("auth", StringComparison.Ordinal))
                return new(new(1, MutationResultStatus.ConfirmedFailure, "recycle", false, false, new(0, 1, 0), MutationErrorCategory.Authentication), target.Path, destination);
        }
        return new(new(1, MutationResultStatus.ConfirmedSuccess, "recycle", true, true, new(1, 0, 0)), target.Path, destination,
            new(destination, target.Name, target.IsDirectory, target.Size, target.ModifiedAt, null, true, true));
    }
}

internal sealed class SmokeVmTaskCleanupRepository(string state) : IVirtualMachineManagerRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public VirtualMachineManagerAvailability Availability => new(VirtualMachineManagerAvailabilityStatus.Available, new HashSet<VirtualMachineManagerReadFeature> { VirtualMachineManagerReadFeature.Machines });
    public bool CanReadTasks => true;
    public bool CanClearTasks => state != "taskclear-readonly";
    public List<VirtualMachineTaskSummary> Tasks { get; } = Enumerable.Range(0, state == "taskclear-protected" ? 0 : state == "taskclear-large" ? 205 : 2)
        .Select(index => new VirtualMachineTaskSummary($"finished-{index}", VirtualMachineTaskState.Finished, 100))
        .Concat([new("running", VirtualMachineTaskState.Running, 40), new("protected", VirtualMachineTaskState.Finished, 100) { IsProtected = true }]).ToList();
    public int Writes, Reviews; public bool Resolve; public CancellationToken Token;
    private bool _resolved;
    public VirtualMachineTaskCleanupRequest? Last;
    public TaskCompletionSource<VirtualMachineTaskCleanupResult> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task<IReadOnlyList<VirtualMachineTaskSummary>> LoadVirtualMachineTasksAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<VirtualMachineTaskSummary>>(Tasks.ToArray());
    public Task<IReadOnlyList<VirtualMachineTaskCleanupRecovery>> GetTaskCleanupRecoveriesAsync(CancellationToken token = default) =>
        Task.FromResult<IReadOnlyList<VirtualMachineTaskCleanupRecovery>>(Last is not null && !_resolved && state is "taskclear-unknown" or "taskclear-review" or "taskclear-close" ? [new(Last.RequestId, Last.Keys.Count)] : []);
    public Task<VirtualMachineTaskCleanupResult> ClearFinishedTasksAsync(VirtualMachineTaskCleanupRequest request, CancellationToken token = default)
    {
        Writes++; Last = request; Token = token;
        if (!request.RiskConfirmed || request.Keys.Any(key => key is "running" or "protected")) throw new InvalidOperationException("清理范围或确认不合法。");
        if (state == "taskclear-close") return Completion.Task;
        if (state == "taskclear-changed") return Task.FromResult(new VirtualMachineTaskCleanupResult(request.Keys.Count, 0, 0, 0, request.Keys.Count, MutationErrorCategory.Conflict));
        if (state is "taskclear-unknown" or "taskclear-review") return Task.FromResult(new VirtualMachineTaskCleanupResult(request.Keys.Count, 0, 0, 1, request.Keys.Count - 1));
        Tasks.RemoveAll(item => request.Keys.Contains(item.Key));
        return Task.FromResult(new VirtualMachineTaskCleanupResult(request.Keys.Count, request.Keys.Count, 0, 0, 0));
    }
    public Task<VirtualMachineTaskCleanupResult?> ReviewTaskCleanupAsync(Guid requestId, CancellationToken token = default)
    {
        Reviews++; if (Last?.RequestId != requestId) throw new InvalidOperationException("核对身份错误。");
        if (Resolve) { _resolved = true; Tasks.RemoveAll(item => item.Key == Last.Keys[0]); }
        return Task.FromResult<VirtualMachineTaskCleanupResult?>(new(Last.Keys.Count, Resolve ? 1 : 0, 0, Resolve ? 0 : 1, Last.Keys.Count - 1));
    }
    public Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(CancellationToken token = default) => Task.FromResult(new VirtualMachineManagerSnapshot(ProfileId,
        VirtualMachineManagerSection<VirtualMachineSummary>.Available([]), VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
        VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable, VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
        VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable, VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
        VirtualMachineManagerSection<ServiceEventSummary>.Unavailable));
}

internal sealed class SmokeVmPowerBatchRepository(string state, bool deletion = false, bool images = false) : IVirtualMachineManagerRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public VirtualMachineManagerAvailability Availability => new(VirtualMachineManagerAvailabilityStatus.Available, new HashSet<VirtualMachineManagerReadFeature> { VirtualMachineManagerReadFeature.Machines });
    public bool CanControlPower => !deletion && state != "vmbatch-readonly";
    public bool CanDeleteMachines => deletion && !images && state != "vmbatch-readonly";
    public bool CanDeleteImages => images && state != "vmbatch-readonly";
    public VirtualizationResourceSummary[] Images { get; } = Enumerable.Range(0, state == "vmbatch-empty" ? 0 : 205).Select(index =>
        new VirtualizationResourceSummary($"image-{index:D4}", $"Image {index:D4}", VirtualizationResourceKind.Image, VirtualizationResourceHealth.Unknown,
            Type: state == "vmbatch-running" ? "future" : index % 3 == 0 ? "iso" : index % 3 == 1 ? "disk" : "vdsm")).ToArray();
    public List<VirtualMachineImageDeleteRequest> ImageDeletes { get; } = [];
    public List<VirtualMachineDeleteRecovery> ImagePending { get; } = [];
    public Task<IReadOnlyList<VirtualizationResourceSummary>> LoadImageDeletionTargetsAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<VirtualizationResourceSummary>>(Images.ToArray());
    public Task<IReadOnlyList<VirtualMachineDeleteRecovery>> GetImageDeletionRecoveriesAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<VirtualMachineDeleteRecovery>>(ImagePending.ToArray());
    public Task<MutationResult?> ReviewImageDeletionAsync(string id, CancellationToken token = default)
    { Reads++; if (Resolve) ImagePending.RemoveAll(item => item.Id == id); return Task.FromResult<MutationResult?>(ImageResult(Resolve)); }
    private static MutationResult ImageResult(bool success) => new(1, success ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified,
        "virtualMachineImageDelete", true, !success, success ? new(1, 0, 0) : new(0, 0, 1));
    public async Task<MutationResult> DeleteImageAsync(VirtualMachineImageDeleteRequest request, CancellationToken token = default)
    {
        ImageDeletes.Add(request); Token = token; await Task.Delay(2, token);
        if (state == "vmbatch-close-busy") return await Release.Task;
        if (ImageDeletes.Count == 23 && state is "vmbatch-unknown" or "vmbatch-auth" or "vmbatch-cancel" or "vmbatch-review-after" or "vmbatch-rejected")
        {
            if (state is "vmbatch-auth" or "vmbatch-rejected") return new(1, MutationResultStatus.ConfirmedFailure, "virtualMachineImageDelete", false, false, new(0, 1, 0),
                state == "vmbatch-auth" ? MutationErrorCategory.Authentication : MutationErrorCategory.Permission);
            ImagePending.Add(new(request.Baseline.Id, request.Baseline.Name));
            if (state == "vmbatch-cancel") await Task.Delay(Timeout.Infinite, token);
            return ImageResult(false);
        }
        return ImageResult(true);
    }
    public VirtualMachineSummary[] Machines { get; } = Enumerable.Range(0, state == "vmbatch-empty" ? 0 : 205).Select(index =>
        new VirtualMachineSummary($"vm-{index:D4}", $"VM {index:D4}", state == "vmbatch-running" || state.Contains("off", StringComparison.Ordinal) || state.Contains("shutdown", StringComparison.Ordinal)
            ? VirtualMachineOperationalState.Running : VirtualMachineOperationalState.Stopped, 2, 1073741824, null, null, null)).ToArray();
    public List<VirtualMachinePowerRequest> Calls { get; } = [];
    public List<VirtualMachineDeleteRequest> Deletes { get; } = [];
    public List<VirtualMachineDeleteRecovery> DeletionPending { get; } = [];
    public Task<IReadOnlyList<VirtualMachineDeleteRecovery>> GetDeletionRecoveriesAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<VirtualMachineDeleteRecovery>>(DeletionPending.ToArray());
    public Task<MutationResult?> ReviewDeletionAsync(string id, CancellationToken token = default)
    { Reads++; if (Resolve) DeletionPending.RemoveAll(item => item.Id == id); return Task.FromResult<MutationResult?>(DeleteResult(Resolve)); }
    private static MutationResult DeleteResult(bool success) => new(1, success ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified,
        "virtualMachineDelete", true, !success, success ? new(1, 0, 0) : new(0, 0, 1));
    public async Task<MutationResult> DeleteMachineAsync(VirtualMachineDeleteRequest request, CancellationToken token = default)
    {
        Deletes.Add(request); Token = token; await Task.Delay(2, token);
        if (state == "vmbatch-close-busy") return await Release.Task;
        if (Deletes.Count == 23 && state is "vmbatch-unknown" or "vmbatch-auth" or "vmbatch-cancel" or "vmbatch-review-after" or "vmbatch-rejected")
        {
            if (state is "vmbatch-auth" or "vmbatch-rejected") return new(1, MutationResultStatus.ConfirmedFailure, "virtualMachineDelete", false, false, new(0, 1, 0),
                state == "vmbatch-auth" ? MutationErrorCategory.Authentication : MutationErrorCategory.Permission);
            DeletionPending.Add(new(request.Baseline.Id, request.Baseline.Name));
            if (state == "vmbatch-cancel") await Task.Delay(Timeout.Infinite, token);
            return DeleteResult(false);
        }
        return DeleteResult(true);
    }
    public List<VirtualMachinePowerRecovery> Pending { get; } = [];
    public bool Resolve;
    public int Reads;
    public CancellationToken Token;
    public TaskCompletionSource<MutationResult> Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(CancellationToken token = default) => Task.FromResult(new VirtualMachineManagerSnapshot(ProfileId,
        VirtualMachineManagerSection<VirtualMachineSummary>.Available(Machines.ToArray()),
        VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable, VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
        VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable, VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
        VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable, VirtualMachineManagerSection<ServiceEventSummary>.Unavailable));
    public Task<IReadOnlyList<VirtualMachinePowerRecovery>> GetPowerRecoveriesAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<VirtualMachinePowerRecovery>>(Pending.ToArray());
    public Task<MutationResult?> ReviewPowerAsync(string id, CancellationToken token = default)
    { Reads++; if (Resolve) Pending.RemoveAll(item => item.Id == id); return Task.FromResult<MutationResult?>(Resolve ? Success() : Unknown()); }
    public async Task<MutationResult> ControlPowerAsync(VirtualMachinePowerRequest request, CancellationToken token = default)
    {
        Calls.Add(request); Token = token; await Task.Delay(2, token);
        if (state == "vmbatch-close-busy") return await Release.Task;
        if (Calls.Count == 23 && state is "vmbatch-unknown" or "vmbatch-auth" or "vmbatch-cancel" or "vmbatch-review-after")
        {
            if (state == "vmbatch-auth") return new(1, MutationResultStatus.ConfirmedFailure, "virtualMachinePower", false, false, new(0, 1, 0), MutationErrorCategory.Authentication);
            Pending.Add(new(request.Baseline.Id, request.Baseline.Name, request.Action));
            if (state == "vmbatch-cancel") await Task.Delay(Timeout.Infinite, token);
            return Unknown();
        }
        return Success();
    }
    public static MutationResult Success() => new(1, MutationResultStatus.ConfirmedSuccess, "virtualMachinePower", true, false, new(1, 0, 0));
    private static MutationResult Unknown() => new(1, MutationResultStatus.SubmittedButUnverified, "virtualMachinePower", true, true, new(0, 0, 1));
}

internal sealed class SmokeCopyMoveRecoveryRepository(string state, bool recycle = false, bool restore = false) : IFileCopyMoveRepository, IFileRecycleRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public FileCopyMoveAvailability Availability => new(true, true, 3);
    public CrossNasCopyMoveAvailability CrossNasAvailability => new(false, false);
    public bool SupportsCopyMoveReview => true;
    public bool SupportsRecycleReview => true;
    FileRecycleAvailability IFileRecycleRepository.Availability => new(true, true, 2, 3);
    public FileCopyMovePendingReview Pending { get; } = new(Guid.Parse("88888888-8888-8888-8888-888888888888"), SmokeActivityProbe.Profile,
        FileCopyMoveOperation.Move, recycle ? restore ? "/share/#recycle/item.txt" : "/share/item.txt" : "/source/item.txt",
        recycle ? restore ? "/share/item.txt" : "/share/#recycle/item.txt" : "/destination/item.txt", "item.txt", false, 7);
    public int Reviews, Acknowledgements, Writes;
    public CancellationToken ReviewToken;
    public TaskCompletionSource<FileCopyMoveOutcome?> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource<FileRecycleOutcome?> RecycleCompletion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task<IReadOnlyList<FileRecyclePendingReview>> GetRecycleReviewsAsync(CancellationToken token = default) => state == "review-load-error"
        ? Task.FromException<IReadOnlyList<FileRecyclePendingReview>>(new IOException("synthetic"))
        : Task.FromResult<IReadOnlyList<FileRecyclePendingReview>>(state == "review-empty" || Acknowledgements > 0 ? [] :
            [new(Pending.Id, ProfileId, restore, Pending.SourcePath, Pending.DestinationPath, Pending.Name, false, 7, DateTimeOffset.UnixEpoch)]);
    public Task<FileRecycleOutcome?> ReviewRecycleAsync(Guid id, CancellationToken token = default)
    {
        Reviews++; ReviewToken = token;
        if (id != Pending.Id) throw new InvalidOperationException("核对身份不一致。");
        if (state is "review-close-busy" or "review-reopen") return RecycleCompletion.Task;
        if (state == "review-auth") return Task.FromException<FileRecycleOutcome?>(new DsmException("synthetic", "synthetic", 119));
        if (state == "review-pending") return Task.FromResult<FileRecycleOutcome?>(new(new(1, MutationResultStatus.SubmittedButUnverified,
            restore ? "restoreFromRecycle" : "moveToRecycle", true, true, new(0, 0, 1)), Pending.SourcePath, Pending.DestinationPath));
        return Task.FromResult<FileRecycleOutcome?>(RecycleSuccess());
    }
    public FileRecycleOutcome RecycleSuccess() => new(new(1, MutationResultStatus.ConfirmedSuccess, restore ? "restoreFromRecycle" : "moveToRecycle", true, false, new(1, 0, 0)),
        Pending.SourcePath, Pending.DestinationPath, new(Pending.DestinationPath, Pending.Name, false, 7, DateTimeOffset.UnixEpoch, null, true, true));
    public void AcknowledgeRecycleReview(Guid id) => AcknowledgeCopyMoveReview(id);
    public void Complete()
    { if (recycle) RecycleCompletion.SetResult(RecycleSuccess()); else Completion.SetResult(Success()); }
    public Task<FileRecycleOutcome> MoveToRecycleAsync(MoveToRecycleRequest request, CancellationToken token = default)
    { Writes++; throw new InvalidOperationException("核对不得回收文件。"); }
    public Task<FileRecycleOutcome> RestoreFromRecycleAsync(RestoreFromRecycleRequest request, CancellationToken token = default)
    { Writes++; throw new InvalidOperationException("核对不得恢复文件。"); }
    public Task<IReadOnlyList<FileCopyMovePendingReview>> GetCopyMoveReviewsAsync(CancellationToken token = default) => state == "review-load-error"
        ? Task.FromException<IReadOnlyList<FileCopyMovePendingReview>>(new IOException("synthetic"))
        : Task.FromResult<IReadOnlyList<FileCopyMovePendingReview>>(state == "review-empty" || Acknowledgements > 0 ? [] : [Pending]);
    public Task<FileCopyMoveOutcome?> ReviewCopyMoveAsync(Guid id, CancellationToken token = default)
    {
        Reviews++; ReviewToken = token;
        if (id != Pending.Id) throw new InvalidOperationException("核对身份不一致。");
        if (state is "review-close-busy" or "review-reopen") return Completion.Task;
        if (state == "review-auth") return Task.FromException<FileCopyMoveOutcome?>(new DsmException("synthetic", "synthetic", 119));
        if (state == "review-pending") return Task.FromResult<FileCopyMoveOutcome?>(new(new(1, MutationResultStatus.SubmittedButUnverified, "moveFile", true, true, new(0, 0, 1))));
        return Task.FromResult<FileCopyMoveOutcome?>(Success());
    }
    public FileCopyMoveOutcome Success() => new(new(1, MutationResultStatus.ConfirmedSuccess, "moveFile", true, false, new(1, 0, 0)),
        new(Pending.DestinationPath, Pending.Name, false, 7, DateTimeOffset.UnixEpoch, null, true, true));
    public void AcknowledgeCopyMoveReview(Guid id)
    { if (id != Pending.Id) throw new InvalidOperationException("错误的本地确认身份。"); Acknowledgements++; }
    public Task<FileCopyMoveOutcome> CopyMoveAsync(FileCopyMoveRequest request, CancellationToken token = default)
    { Writes++; throw new InvalidOperationException("核对不得启动写操作。"); }
    public Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(CrossNasCopyMoveRequest request, IProgress<long>? progress = null, CancellationToken token = default)
    { Writes++; throw new InvalidOperationException("核对不得跨 NAS 写入。"); }
}

internal sealed class SmokeLargeCopyMoveRepository(string state) : IFileCopyMoveRepository, IFileCopyMoveFolderSource
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public FileCopyMoveAvailability Availability => new(true, true, 3);
    public CrossNasCopyMoveAvailability CrossNasAvailability => new(false, false);
    public List<FileCopyMoveRequest> Requests { get; } = [];
    public bool Cancelled;
    public bool Writable => state != "copy-large-readonly";
    public Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(string path, CancellationToken token) =>
        Task.FromResult<IReadOnlyList<FileCopyMoveFolder>>(path.Length == 0 ? [new("/destination", "destination", Writable)] : []);
    public bool IsReadOnlyPath(string path) => path == "/destination" && !Writable;
    public async Task<FileCopyMoveOutcome> CopyMoveAsync(FileCopyMoveRequest request, CancellationToken token = default)
    {
        Requests.Add(request); await Task.Yield();
        if (request.DestinationDirectoryPath != "/destination") throw new InvalidOperationException("复制/移动目标没有冻结。");
        if (state.StartsWith("conflict-", StringComparison.Ordinal))
        {
            if (state.EndsWith("cancel", StringComparison.Ordinal))
            {
                try { await Task.Delay(Timeout.Infinite, token); }
                catch (OperationCanceledException) { Cancelled = true; throw; }
            }
            if (state.EndsWith("unknown", StringComparison.Ordinal))
                return new(new(1, MutationResultStatus.SubmittedButUnverified, "copyMove", true, true, new(0, 0, 1)));
            if (request.ConflictPolicy == FileCopyMoveConflictPolicy.Skip && (Requests.Count == 1 || state.Contains("all-skip", StringComparison.Ordinal)))
                return new(new(1, MutationResultStatus.ConfirmedFailure, "copyMove", false, false, new(0, 1, 0), MutationErrorCategory.Conflict)) { SkippedExisting = true };
        }
        if (Requests.Count == 23)
        {
            if (state == "copy-large-cancel")
            {
                try { await Task.Delay(Timeout.Infinite, token); }
                catch (OperationCanceledException) { Cancelled = true; throw; }
            }
            if (state is "copy-large-unknown" or "move-large-unknown")
                return new(new(1, MutationResultStatus.SubmittedButUnverified, "copyMove", true, true, new(0, 0, 1)));
            if (state == "copy-large-auth")
                return new(new(1, MutationResultStatus.ConfirmedFailure, "copyMove", false, false, new(0, 1, 0), MutationErrorCategory.Authentication));
        }
        return new(new(1, MutationResultStatus.ConfirmedSuccess, "copyMove", true, true, new(1, 0, 0)),
            new FileItem("/destination/" + request.Target.Name, request.Target.Name, request.Target.IsDirectory, request.Target.Size, request.Target.ModifiedAt, null, true, true));
    }
    public Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(CrossNasCopyMoveRequest request, IProgress<long>? progress = null, CancellationToken token = default) => throw new NotSupportedException();
}

public class SmokeFileUploadRepository : System.Reflection.DispatchProxy, IFileMutationRepository
{
    public string State = "upload-large";
    public List<string> Names { get; } = [];
    public List<bool> Overwrites { get; } = [];
    public int Active, MaximumActive;
    public bool Cancelled;
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public FileMutationAvailability FileMutationAvailability => new(true, false, 2);
    public List<string> Directories { get; } = [];
    public Task<FileMutationOutcome> RenameAsync(RenameFileItemRequest request, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<FileMutationOutcome> CreateFolderAsync(CreateFolderRequest request, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (request.ProfileId != ProfileId || (request.ParentPath != "/share" && !Directories.Contains(request.ParentPath))) throw new InvalidOperationException("父目录未先创建。");
        var path = request.ParentPath + "/" + request.Name;
        Directories.Add(path);
        var unknown = State == "folder-unknown" && Directories.Count == 23;
        return Task.FromResult(new FileMutationOutcome(
            new(1, unknown ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess, "createFolder", true, true, new(unknown ? 0 : 1, 0, unknown ? 1 : 0)),
            unknown ? null : new FileItem(path, request.Name, true, 0, null, null, true, true)));
    }
    protected override object? Invoke(System.Reflection.MethodInfo? method, object?[]? args)
    {
        if (method!.Name == "UploadFileAsync") return UploadAsync((FileUploadRequest)args![0]!, (IProgress<long>?)args[1], (CancellationToken)args[2]!);
        if (method.Name == "get_AvailableModules") return Array.Empty<AppModule>();
        throw new NotSupportedException("未预期的合成上传请求：" + method.Name);
    }
    private async Task<MutationResult> UploadAsync(FileUploadRequest request, IProgress<long>? progress, CancellationToken token)
    {
        Names.Add(request.FileName); Overwrites.Add(request.Overwrite); Active++; MaximumActive = Math.Max(MaximumActive, Active);
        try
        {
            await Task.Yield();
            if (State.StartsWith("folder-", StringComparison.Ordinal))
            {
                if (Directories.Count != 51 || !Directories.Contains(request.FolderPath) || request.Overwrite) throw new InvalidOperationException("目录上传顺序或不覆盖约束被破坏。");
            }
            else if (request.FolderPath != "/share") throw new InvalidOperationException("上传目标没有冻结。");
            using var memory = new MemoryStream(); await request.Content.CopyToAsync(memory, token);
            if (memory.Length != request.Length || System.Text.Encoding.UTF8.GetString(memory.ToArray()) != "data") throw new InvalidOperationException("上传内容不完整。");
            progress?.Report(request.Length);
            if (State is "upload-cancel" or "folder-file-cancel" && Names.Count == 23)
            {
                try { await Task.Delay(Timeout.Infinite, token); }
                catch (OperationCanceledException) { Cancelled = true; throw; }
            }
            var unknown = State == "upload-unknown" && Names.Count == 23;
            return new(1, unknown ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess,
                "uploadFile", true, true, new(unknown ? 0 : 1, 0, unknown ? 1 : 0));
        }
        finally { Active--; }
    }
}

internal sealed class SmokeFileUploadPicker(IReadOnlyList<string> paths) : IWindowsTransferOpenPicker
{
    public Func<Task>? OnPick;
    public bool Cancelled;
    public string? FolderPath;
    public async Task<IReadOnlyList<string>?> PickMultipleFilePathsAsync(IReadOnlyList<string>? fileTypeFilters = null)
    { if (OnPick is not null) await OnPick(); return Cancelled ? null : paths; }
    public Task<string?> PickSingleFilePathAsync(IReadOnlyList<string>? fileTypeFilters = null) => Task.FromResult<string?>(null);
    public async Task<string?> PickSingleFolderPathAsync()
    { if (OnPick is not null) await OnPick(); return Cancelled ? null : FolderPath; }
}

public class SmokeSelectionDownloadRepository : System.Reflection.DispatchProxy
{
    public string State = "selection-download";
    public string[] Paths = [];
    public int ArchiveCalls, FileCalls;
    public bool Cancelled;
    protected override object? Invoke(System.Reflection.MethodInfo? method, object?[]? args)
    {
        if (method!.Name == "StreamArchiveAsync") return StreamAsync((IReadOnlyList<string>)args![0]!,
            (Func<ReadOnlyMemory<byte>, CancellationToken, ValueTask>)args[1]!, (CancellationToken)args[2]!);
        if (method.Name == "ReadFileRangeResultAsync")
        {
            FileCalls++; var offset = (long)args![1]!; var length = (long)args[2]!;
            var bytes = System.Text.Encoding.UTF8.GetBytes("content").AsSpan((int)offset, (int)length).ToArray();
            return Task.FromResult(new FileRangeReadResult(206, offset, length, offset, length, 7, bytes.Length, bytes, "\"synthetic\"", true));
        }
        if (method.Name == "get_AvailableModules") return Array.Empty<AppModule>();
        throw new NotSupportedException("未预期的合成下载请求：" + method.Name);
    }
    private async Task StreamAsync(IReadOnlyList<string> paths, Func<ReadOnlyMemory<byte>, CancellationToken, ValueTask> write, CancellationToken token)
    {
        ArchiveCalls++; Paths = paths.ToArray();
        if (State == "selection-invalid") { await write(new byte[] { 1, 2, 3 }, token); return; }
        using var memory = new MemoryStream();
        using (var zip = new System.IO.Compression.ZipArchive(memory, System.IO.Compression.ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var path in paths)
            {
                var folder = path == "/share/target";
                var entry = zip.CreateEntry(path.TrimStart('/') + (folder ? "/" : ""));
                if (!folder) { using var writer = new StreamWriter(entry.Open()); writer.Write("content"); }
            }
        }
        await write(memory.ToArray(), token);
        if (State == "selection-cancel")
        {
            try { await Task.Delay(Timeout.Infinite, token); }
            catch (OperationCanceledException) { Cancelled = true; throw; }
        }
    }
}

internal sealed class SmokeSelectionSavePicker(string path) : IWindowsTransferSavePicker
{
    public bool UsedArchive;
    public Action? OnPick;
    public bool Cancelled;
    public string? SuggestedName;
    public Task<string?> PickSavePathAsync(string suggestedName)
    { SuggestedName = suggestedName; OnPick?.Invoke(); return Task.FromResult<string?>(Cancelled ? null : path); }
    public Task<string?> PickArchiveSavePathAsync(string suggestedName)
    { UsedArchive = true; return PickSavePathAsync(suggestedName); }
}

public class SmokeRemoteMountRepository : System.Reflection.DispatchProxy
{
    public string State = "mount-create";
    public int Writes, Reviews;
    public bool Resolve;
    public CancellationToken LastToken;
    private RemoteMountProgress? _pending;
    private static Guid Profile => SmokeActivityProbe.Profile;
    private static RemoteMountConnection Existing => new(Profile, "/share/mount", "//server.invalid/share", FileRemoteProtocol.Cifs, false);
    protected override object? Invoke(System.Reflection.MethodInfo? method, object?[]? args)
    {
        switch (method!.Name)
        {
            case "get_ProfileId": return Profile;
            case "get_Availability": return new FileLocationsAvailability(false, false, true);
            case "get_AllowsRemoteMountManagement": return false;
            case "get_CanWriteFavorites": return false;
            case "get_CanManageRemoteMountWorkflow": return true;
            case "LoadRemoteMountInventoryAsync": return LoadAsync((CancellationToken)args![0]!);
            case "GetRemoteMountOperationsAsync": return Task.FromResult<IReadOnlyList<RemoteMountProgress>>(_pending is null ? [] : [_pending]);
            case "StartRemoteMountOperationAsync": return SubmitAsync((RemoteMountMutationRequest)args![0]!, false, (CancellationToken)args[1]!);
            case "ContinueRemoteMountOperationAsync": return SubmitAsync((RemoteMountMutationRequest)args![0]!, true, (CancellationToken)args[1]!);
            case "ReviewRemoteMountOperationAsync":
                Reviews++; var result = _pending;
                if (Resolve && result is not null)
                { result = result with { Stage = RemoteMountStage.Complete, Outcome = Outcome(RemoteMountStage.Complete) }; _pending = null; }
                return Task.FromResult(result);
            default: throw new NotSupportedException("未预期的合成挂载调用：" + method.Name);
        }
    }
    private async Task<RemoteMountInventory> LoadAsync(CancellationToken token)
    {
        if (State == "mount-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "mount-error") throw new IOException("合成清单失败");
        return new(Profile, true, State == "mount-empty" ? [] : [Existing]);
    }
    private async Task<RemoteMountProgress> SubmitAsync(RemoteMountMutationRequest request, bool continuing, CancellationToken token)
    {
        Writes++; LastToken = token;
        if (State is "mount-close-busy" or "mount-profile-change") await Task.Delay(Timeout.Infinite, token);
        var stage = continuing ? RemoteMountStage.Complete : State is "mount-unknown" or "mount-review" ? RemoteMountStage.VerifyingConnection :
            request.Action == RemoteMountAction.Update ? request.Baseline!.MountPoint == request.Desired!.MountPoint ? RemoteMountStage.ReadyToConnect : RemoteMountStage.ReadyToDisconnectPrevious : RemoteMountStage.Complete;
        var result = new RemoteMountProgress(request.RequestId, request.Action, request.Desired?.MountPoint ?? request.Baseline!.MountPoint, request.Baseline?.MountPoint,
            stage, Outcome(stage), new(request.Baseline, request.Desired is null ? null : RemoteMountSetup.FromDraft(request.Desired)));
        _pending = stage == RemoteMountStage.Complete ? null : result; return result;
    }
    private static MutationResult Outcome(RemoteMountStage stage) => new(1, stage == RemoteMountStage.Complete ? MutationResultStatus.ConfirmedSuccess :
        stage is RemoteMountStage.ReadyToConnect or RemoteMountStage.ReadyToDisconnectPrevious ? MutationResultStatus.PartialSuccess : MutationResultStatus.SubmittedButUnverified,
        "remoteMount", true, true, new(stage == RemoteMountStage.VerifyingConnection ? 0 : 1, 0, stage == RemoteMountStage.Complete ? 0 : 1));
}

public class SmokeDragPreview : System.Reflection.DispatchProxy
{
    protected override object? Invoke(System.Reflection.MethodInfo? method, object?[]? args) => method!.Name switch
    {
        "get_ProfileId" => SmokeActivityProbe.Profile,
        "GetTextEditAvailability" => new FileTextEditAvailability(false, false, []),
        "get_MD5Availability" => new FileMD5Availability(false),
        _ => throw new NotSupportedException("合成拖动测试不读取预览")
    };
}

internal sealed class SmokeContainerMutationRepository : IContainerManagerRepository
{
    private readonly string _state;
    public Guid ProfileId { get; } = Guid.NewGuid();
    public bool CanMutateContainers => _state != "ops-readonly";
    public ContainerManagerAvailability Availability => new(ContainerManagerAvailabilityStatus.InternalObserved, new HashSet<ContainerManagerReadFeature> { ContainerManagerReadFeature.Containers });
    public List<ContainerSummary> Rows { get; }
    private readonly Dictionary<Guid, ContainerMutationRequest> _pending = [];
    public int Writes { get; private set; }
    public int Reads { get; private set; }
    public bool ReviewCompletes { get; set; }
    public bool Cancelled { get; private set; }
    public SmokeContainerMutationRepository(string state)
    {
        _state = state;
        Rows = state == "ops-empty" ? [] : Enumerable.Range(1, 3).Select(id => new ContainerSummary($"sample-{id}", $"Sample service {id}",
            state.StartsWith("ops-transition", StringComparison.Ordinal) ? ContainerOperationalState.Restarting :
            state is "ops-stop" or "ops-restart" ? ContainerOperationalState.Running : ContainerOperationalState.Stopped, "synthetic:latest")).ToList();
        if (state == "ops-recovery")
        { var request = new ContainerMutationRequest(ProfileId, Rows[0], ContainerMutationAction.Start, Guid.NewGuid(), true); _pending.Add(request.RequestId, request); }
    }
    public async Task<ContainerManagerSnapshot> LoadSnapshotAsync(CancellationToken token = default)
    {
        Reads++;
        if (Reads > 1 && _state == "ops-loading") await Task.Delay(Timeout.Infinite, token);
        if (Reads > 1 && _state == "ops-error") throw new IOException("synthetic");
        return new(ProfileId, ContainerManagerSection<ContainerSummary>.Available(Rows.ToArray()),
            ContainerManagerSection<ContainerResourceSummary>.Unavailable, ContainerManagerSection<ContainerResourceSummary>.Unavailable,
            ContainerManagerSection<ContainerResourceSummary>.Unavailable, ContainerManagerSection<ServiceEventSummary>.Unavailable);
    }
    public Task<IReadOnlyList<ContainerMutationRecovery>> GetContainerMutationRecoveriesAsync(CancellationToken token = default) =>
        Task.FromResult<IReadOnlyList<ContainerMutationRecovery>>(_pending.Values.Select(request => new ContainerMutationRecovery(request.RequestId, request.Baseline, request.Action)).ToArray());
    public Task<MutationResult?> ReviewContainerMutationAsync(Guid requestId, CancellationToken token = default)
    {
        if (!_pending.TryGetValue(requestId, out var request)) return Task.FromResult<MutationResult?>(null);
        if (!ReviewCompletes) return Task.FromResult<MutationResult?>(Unknown());
        _pending.Remove(requestId); Apply(request); return Task.FromResult<MutationResult?>(Done());
    }
    public async Task<MutationResult> MutateContainerAsync(ContainerMutationRequest request, CancellationToken token = default)
    {
        if (!request.RiskConfirmed || request.ProfileId != ProfileId || !Rows.Contains(request.Baseline)) throw new InvalidOperationException("确认快照错误。");
        Writes++; _pending.Add(request.RequestId, request);
        if (_state == "ops-close-busy")
        { try { await Task.Delay(Timeout.Infinite, token); } finally { Cancelled = token.IsCancellationRequested; } }
        if (_state is "ops-unknown" or "ops-recovered" or "ops-reopen") return Unknown();
        _pending.Remove(request.RequestId);
        if (_state == "ops-permission" && Writes == 1) return new(1, MutationResultStatus.PermissionDenied, "containerMutation", true, true, new(0, 1, 0), MutationErrorCategory.Permission);
        Apply(request); return Done();
    }
    private void Apply(ContainerMutationRequest request)
    {
        var row = Rows.FirstOrDefault(item => item.Id == request.Baseline.Id); if (row is null) return;
        if (request.Action == ContainerMutationAction.Delete) Rows.Remove(row);
        else Rows[Rows.IndexOf(row)] = row with { State = request.Action == ContainerMutationAction.Stop ? ContainerOperationalState.Stopped : ContainerOperationalState.Running };
    }
    private static MutationResult Done() => new(1, MutationResultStatus.ConfirmedSuccess, "containerMutation", true, true, new(1, 0, 0));
    private static MutationResult Unknown() => new(1, MutationResultStatus.SubmittedButUnverified, "containerMutation", true, true, new(0, 0, 1));
}

internal sealed class SmokeExtractionRepository(string state) : IFileArchiveExtractionRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public FileArchiveExtractionAvailability Availability => new(true, 2, 2);
    public int Calls { get; private set; }
    public async Task<FileArchiveExtractionOutcome> ExtractAsync(FileArchiveExtractionRequest request, CancellationToken token = default)
    {
        Calls++;
        if (request.Options.Password != " synthetic " || request.Options.Codepage != "chs") throw new InvalidOperationException("解压密码或编码未传递。");
        if (state is "extract-overwrite" or "extract-flatten")
        {
            if (!request.Options.Overwrite || !request.OverwriteConfirmed) throw new InvalidOperationException("覆盖缺少确认。");
            if (state == "extract-flatten" && (request.Options.KeepDirectoryStructure || request.Options.CreateSubfolder)) throw new InvalidOperationException("展开目录选项未传递。");
        }
        else if (request.Options.Overwrite || !request.Options.KeepDirectoryStructure || !request.Options.CreateSubfolder)
            throw new InvalidOperationException("默认解压选项未对齐。");
        if (state is "extract-password" or "extract-retry" && Calls == 1)
            return new(new(1, MutationResultStatus.ConfirmedFailure, "extractFile", false, false, new(0, 1, 0),
                MutationErrorCategory.Validation, diagnosticTag: "file.archive-extraction.password-required"));
        if (state == "extract-working") await Task.Delay(Timeout.Infinite, token);
        var unknown = state == "extract-unknown";
        return new(new(1, unknown ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess,
            "extractFile", true, true, unknown ? new(0, 0, 1) : new(1, 0, 0)));
    }
}

internal sealed class SmokeFavoriteRepository(string state, Guid? profileId = null) : IFileLocationsRepository
{
    public Guid ProfileId { get; } = profileId ?? SmokeActivityProbe.Profile;
    public FileLocationsAvailability Availability => new(true, false, false);
    public bool CanWriteFavorites => state != "favorite-readonly";
    public bool AllowsRemoteMountManagement => false;
    public int Writes { get; private set; }
    public int Reviews { get; private set; }
    public bool Cancelled { get; private set; }
    public bool Resolve { get; set; }
    private readonly List<FileFavoriteLocation> _items = state == "favorite-remove" ? [new(profileId ?? SmokeActivityProbe.Profile, "one.txt", "/share/one.txt")] : [];
    private FileFavoriteMutationRecovery? _pending;
    public Task<FileLocationsSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default) => Task.FromResult(new FileLocationsSnapshot(ProfileId, Availability,
        new(_items.ToArray(), _items.Count, _items.Count, FileLocationCompletion.Complete, FileLocationSectionStatus.Available),
        new([], 0, 0, 0, false, FileLocationCompletion.Complete, FileLocationSectionStatus.Unavailable),
        new([], 0, 0, [], false, FileLocationCompletion.Complete, FileLocationSectionStatus.Unavailable)));
    public async Task<MutationResult> AddFavoriteAsync(string path, string? name = null, CancellationToken cancellationToken = default)
    {
        Writes++;
        if (state == "favorite-close-busy")
        { try { await Task.Delay(Timeout.Infinite, cancellationToken); } catch (OperationCanceledException) { Cancelled = true; throw; } }
        if (state == "favorite-permission") return new(1, MutationResultStatus.PermissionDenied, "addFavorite", true, false, new(0, 1, 0), MutationErrorCategory.Permission);
        name ??= path[(path.LastIndexOf('/') + 1)..];
        if (state is "favorite-unknown" or "favorite-review")
        { _pending = new(ProfileId, path, name, true); return Unknown(); }
        _items.Add(new(ProfileId, name, path)); return Success("addFavorite");
    }
    public Task<MutationResult> RemoveFavoriteAsync(string path, CancellationToken cancellationToken = default)
    { Writes++; _items.RemoveAll(item => item.Path == path); return Task.FromResult(Success("removeFavorite")); }
    public Task<IReadOnlyList<FileFavoriteMutationRecovery>> GetFavoriteMutationRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<FileFavoriteMutationRecovery>>(_pending is null ? [] : [_pending]);
    public Task<MutationResult?> ReviewFavoriteMutationAsync(string path, CancellationToken cancellationToken = default)
    {
        Reviews++; if (_pending is null) return Task.FromResult<MutationResult?>(null);
        if (!Resolve) return Task.FromResult<MutationResult?>(Unknown());
        _items.Add(new(ProfileId, _pending.Name!, path)); _pending = null;
        return Task.FromResult<MutationResult?>(Success("addFavorite"));
    }
    private static MutationResult Success(string operation) => new(1, MutationResultStatus.ConfirmedSuccess, operation, true, true, new(1, 0, 0));
    private static MutationResult Unknown() => new(1, MutationResultStatus.SubmittedButUnverified, "addFavorite", true, true, new(0, 0, 1));
    public Task<MutationResult> CreateRemoteMountAsync(RemoteMountDraft draft, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<MutationResult> UpdateRemoteMountAsync(RemoteMountDraft draft, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<MutationResult> DeleteRemoteMountAsync(string mountPoint, CancellationToken cancellationToken = default) => throw new NotSupportedException();
}

internal sealed class SmokeArchiveRepository(string state) : IFileArchiveCompressionRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public FileArchiveCompressionAvailability Availability => new(true, 3, 2, 3);
    public int Writes { get; private set; }
    public IReadOnlyList<FileArchiveCompressionSource>? Sources { get; private set; }
    public async Task<FileArchiveCompressionOutcome> CompressAsync(FileArchiveCompressionRequest request, CancellationToken token = default)
    {
        Writes++;
        Sources = request.Sources.ToArray();
        if (request.Options.Format != FileArchiveFormat.SevenZip || request.Options.Level != FileArchiveCompressionLevel.Best ||
            request.Options.Password != " synthetic " || request.DestinationName != "Sample.7z")
            throw new InvalidOperationException("高级压缩选项未传递。");
        if (state == "archive-working") await Task.Delay(Timeout.Infinite, token);
        var status = state == "archive-error" ? MutationResultStatus.ConfirmedFailure :
            state == "archive-unknown" ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess;
        return new(new(1, status, "compressFile", true, true,
            status == MutationResultStatus.ConfirmedSuccess ? new(1, 0, 0) : new(0, 0, 1)));
    }
}

internal sealed class SmokeDragMoveRepository : IFileBrowserDataSource, IFileCopyMoveRepository, IFileCopyMoveFolderSource
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public FileCopyMoveAvailability Availability => new(true, true, 3);
    public CrossNasCopyMoveAvailability CrossNasAvailability => new(false, false);
    public FileItem Target { get; } = new("/share/target", "target", true, 0, null, null, true, true);
    public List<FileItem> Files { get; } = [new("/share/one.txt", "one.txt", false, 10, DateTimeOffset.UnixEpoch, null, true, true),
        new("/share/two.txt", "two.txt", false, 20, DateTimeOffset.UnixEpoch, null, true, true)];
    public List<FileCopyMoveRequest> Writes { get; } = [];
    public bool TargetWritable { get; set; } = true;
    public bool Partial { get; set; }
    public Task<FilePage> LoadPageAsync(string path, int offset, int limit, FileListOptions options, CancellationToken token)
    {
        var rows = string.IsNullOrEmpty(path) ? new[] { new FileItem("/share", "share", true, 0, null, null, true, true) } :
            Files.Where(file => file.Path[..file.Path.LastIndexOf('/')] == path).Concat(path == "/share" ? [Target] : Array.Empty<FileItem>()).ToArray();
        return Task.FromResult(new FilePage(rows.Skip(offset).Take(limit).ToArray(), rows.Length, offset));
    }
    public Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(string path, CancellationToken token) =>
        Task.FromResult<IReadOnlyList<FileCopyMoveFolder>>(path switch { "" => [new("/share", "share", true)], "/share" => [new(Target.Path, Target.Name, TargetWritable)], _ => [] });
    public bool IsReadOnlyPath(string path) => false;
    public Task<FileCopyMoveOutcome> CopyMoveAsync(FileCopyMoveRequest request, CancellationToken token = default)
    {
        Writes.Add(request);
        if (!request.DestinationCanWrite || Files.SingleOrDefault(file => file.Path == request.Target.Path) is not { } source || source.ModifiedAt != request.Target.ModifiedAt)
            throw new InvalidOperationException("合成移动目标或基线错误");
        if (Partial && Writes.Count == 2) return Task.FromResult(new FileCopyMoveOutcome(new(1, MutationResultStatus.SubmittedButUnverified, "move", true, true, new(0, 0, 1))));
        var moved = source with { Path = request.DestinationDirectoryPath + "/" + source.Name, ModifiedAt = source.ModifiedAt?.AddSeconds(1) };
        Files.Remove(source); Files.Add(moved);
        return Task.FromResult(new FileCopyMoveOutcome(new(1, MutationResultStatus.ConfirmedSuccess, "move", true, false, new(1, 0, 0)), moved));
    }
    public Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(CrossNasCopyMoveRequest request, IProgress<long>? progress = null, CancellationToken token = default) => throw new NotSupportedException();
}

public class SmokeActivityProbe : System.Reflection.DispatchProxy
{
    public static readonly Guid Profile = Guid.Parse("11111111-1111-1111-1111-111111111111");
    public bool Hold { get; set; } = true;
    public bool IgnoreCancellation { get; set; }
    public int Reads;
    public Func<int, int, FileBackgroundTaskPage>? FilePage { get; set; }
    public Func<int, int, DownloadTaskPage>? DownloadPage { get; set; }
    public CancellationToken LastToken { get; private set; }
    public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource Cancelled { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    protected override object? Invoke(System.Reflection.MethodInfo? method, object?[]? args)
    {
        return method!.Name switch
        {
            "get_ProfileId" => Profile,
            "get_IsAvailable" => true,
            "get_Availability" => new DownloadStationAvailability(DownloadStationAvailabilityStatus.Available, new HashSet<DownloadStationReadFeature> { DownloadStationReadFeature.Tasks }),
            "ListTasksAsync" when method.ReturnType == typeof(Task<FileBackgroundTaskPage>) => ReadAsync(FilePage?.Invoke((int)args![0]!, (int)args[1]!) ?? new FileBackgroundTaskPage([], 0, 0, 0, false), (CancellationToken)args![2]!),
            "ListTasksAsync" => ReadAsync(DownloadPage?.Invoke((int)args![0]!, (int)args[1]!) ?? new DownloadTaskPage([], 0, 0, 0, null, false), (CancellationToken)args![2]!),
            _ => throw new InvalidOperationException("合成活动核查不允许其他操作")
        };
    }
    private async Task<T> ReadAsync<T>(T page, CancellationToken token)
    {
        Interlocked.Increment(ref Reads); LastToken = token; Started.TrySetResult();
        using var registration = token.Register(() => Cancelled.TrySetResult());
        try
        {
            if (Hold)
            {
                if (IgnoreCancellation) await Release.Task;
                else await Release.Task.WaitAsync(token);
            }
            return page;
        }
        finally
        {
            // WaitAsync 取消后的延续可能先释放注册；探针以令牌的最终状态补记，不依赖回调顺序。
            if (token.IsCancellationRequested) Cancelled.TrySetResult();
        }
    }
}

internal sealed class SmokeImagePullRepository : IContainerManagerRepository
{
    private static string State => Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "";
    private readonly Dictionary<Guid, ContainerImagePullResult> _pending = [];
    private bool _seeded;
    public Guid ProfileId { get; } = Guid.NewGuid();
    public int Starts { get; private set; }
    public int Reviews { get; private set; }
    public bool Cancelled { get; private set; }
    public bool FinishReview { get; set; }
    public bool CanBrowseRegistry => true;
    public bool CanPullImages => State != "pull-readonly";
    public ContainerManagerAvailability Availability { get; } = new(ContainerManagerAvailabilityStatus.InternalObserved,
        new HashSet<ContainerManagerReadFeature> { ContainerManagerReadFeature.Containers, ContainerManagerReadFeature.Images });
    public Task<ContainerManagerSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default) => Task.FromResult(new ContainerManagerSnapshot(ProfileId,
        ContainerManagerSection<ContainerSummary>.Available([new("sample", "Sample service", ContainerOperationalState.Stopped, "synthetic/web:stable")]),
        ContainerManagerSection<ContainerResourceSummary>.Available([]), ContainerManagerSection<ContainerResourceSummary>.Unavailable,
        ContainerManagerSection<ContainerResourceSummary>.Unavailable, ContainerManagerSection<ServiceEventSummary>.Unavailable));
    public Task<IReadOnlyList<ContainerRegistryImage>> SearchRegistryAsync(string query, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ContainerRegistryImage>>([new("synthetic/web", "docker.io", "Synthetic image", 10, true, null, null)]);
    public Task<IReadOnlyList<string>> LoadRegistryTagsAsync(string repository, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<string>>(["stable", "latest"]);
    public Task<IReadOnlyList<ContainerImagePullResult>> GetImagePullRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        if (State == "pull-read-error") throw new IOException("合成任务读取失败");
        if (State == "pull-recovery" && !_seeded)
        { _seeded = true; var result = Result(Guid.NewGuid(), "synthetic/web", "stable", ContainerImagePullStage.Downloading); _pending.Add(result.RequestId, result); }
        return Task.FromResult<IReadOnlyList<ContainerImagePullResult>>(_pending.Values.ToArray());
    }
    public async Task<ContainerImagePullResult> PullImageAsync(ContainerImagePullRequest request, CancellationToken cancellationToken = default)
    {
        if (!request.RiskConfirmed) throw new InvalidOperationException("合成下载缺少确认"); Starts++;
        if (State == "pull-close-busy")
        { try { await Task.Delay(Timeout.Infinite, cancellationToken); } catch (OperationCanceledException) { Cancelled = true; throw; } }
        var stage = State switch { "pull-no-receipt" => ContainerImagePullStage.AwaitingReceipt, "pull-review" => ContainerImagePullStage.NeedsReview,
            "pull-rejected" => ContainerImagePullStage.Rejected, _ => ContainerImagePullStage.Downloading };
        var result = Result(request.RequestId, request.Repository, request.Tag, stage);
        if (stage != ContainerImagePullStage.Rejected) _pending.Add(request.RequestId, result);
        return result;
    }
    public Task<ContainerImagePullResult?> ReviewImagePullAsync(Guid requestId, CancellationToken cancellationToken = default)
    {
        Reviews++;
        if (!_pending.TryGetValue(requestId, out var previous)) return Task.FromResult<ContainerImagePullResult?>(null);
        var result = Result(requestId, previous.Repository, previous.Tag, FinishReview ? ContainerImagePullStage.Ready : previous.Stage);
        if (FinishReview) _pending.Remove(requestId); else _pending[requestId] = result;
        return Task.FromResult<ContainerImagePullResult?>(result);
    }
    private static ContainerImagePullResult Result(Guid id, string repository, string tag, ContainerImagePullStage stage) =>
        new(id, repository, tag, stage, stage == ContainerImagePullStage.Ready ? 100 : stage == ContainerImagePullStage.Downloading ? 25 : null,
            new(1, stage == ContainerImagePullStage.Ready ? MutationResultStatus.ConfirmedSuccess : stage == ContainerImagePullStage.Rejected ? MutationResultStatus.PermissionDenied : MutationResultStatus.SubmittedButUnverified,
                "pullContainerImage", true, true, stage == ContainerImagePullStage.Ready ? new(1, 0, 0) : stage == ContainerImagePullStage.Rejected ? new(0, 1, 0) : new(0, 0, 1),
                stage == ContainerImagePullStage.Rejected ? MutationErrorCategory.Permission : MutationErrorCategory.Unknown));
}

internal sealed class SmokeImageDeletionRepository : IContainerManagerRepository
{
    private static string State => Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "";
    private readonly List<ContainerImageDeletionRecovery> _pending = [];
    private readonly HashSet<string> _deleted = [];
    private bool _seeded;
    public Guid ProfileId { get; } = Guid.NewGuid();
    public int ImageDeleteCalls { get; private set; }
    public bool ImageDeleteCancelled { get; private set; }
    public bool CanDeleteImages => State != "image-delete-readonly";
    public ContainerManagerAvailability Availability { get; } = new(ContainerManagerAvailabilityStatus.InternalObserved,
        new HashSet<ContainerManagerReadFeature> { ContainerManagerReadFeature.Containers, ContainerManagerReadFeature.Images });
    private static ContainerResourceSummary Target(string suffix) => new("delete-" + suffix, "synthetic/web:" + suffix, ContainerResourceKind.Image, ContainerOperationalState.Unknown)
        { Image = new("synthetic-id", "synthetic/web", suffix) };
    public Task<ContainerManagerSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default) => Task.FromResult(new ContainerManagerSnapshot(ProfileId,
        ContainerManagerSection<ContainerSummary>.Available([new("sample", "Sample service", ContainerOperationalState.Stopped, "synthetic:latest")]),
        ContainerManagerSection<ContainerResourceSummary>.Available(State == "image-delete-empty" ? [] : new[] { Target("a"), Target("b"),
            new ContainerResourceSummary("unknown", "synthetic/legacy", ContainerResourceKind.Image, ContainerOperationalState.Unknown) }.Where(item => !_deleted.Contains(item.Id)).ToArray()),
        ContainerManagerSection<ContainerResourceSummary>.Unavailable, ContainerManagerSection<ContainerResourceSummary>.Unavailable, ContainerManagerSection<ServiceEventSummary>.Unavailable));
    public async Task<IReadOnlyList<ContainerImageDeletionRecovery>> GetImageDeletionRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        if (State == "image-delete-loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        if (State == "image-delete-error") throw new IOException("合成镜像读取失败");
        if (!_seeded && State is "image-delete-pending" or "image-delete-recovered")
        { _seeded = true; _pending.Add(new(Guid.NewGuid(), [Target("a")])); }
        return _pending.ToArray();
    }
    public Task<MutationResult?> ReviewImageDeletionAsync(Guid requestId, CancellationToken cancellationToken = default)
    {
        var pending = _pending.SingleOrDefault(item => item.RequestId == requestId);
        if (pending is null) return Task.FromResult<MutationResult?>(null);
        if (State == "image-delete-recovered")
        { _deleted.Add("delete-a"); _pending.Clear(); return Task.FromResult<MutationResult?>(new(1, MutationResultStatus.ConfirmedSuccess, "deleteContainerImages", true, false, new(1, 0, 0))); }
        var succeeded = pending.Baselines.Count(item => _deleted.Contains(item.Id));
        return Task.FromResult<MutationResult?>(new(1, succeeded > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.SubmittedButUnverified,
            "deleteContainerImages", true, true, new(succeeded, 0, pending.Baselines.Count - succeeded)));
    }
    public async Task<MutationResult> DeleteImagesAsync(ContainerImageDeleteRequest request, CancellationToken cancellationToken = default)
    {
        if (!request.RiskConfirmed) throw new InvalidOperationException("合成删除缺少确认");
        ImageDeleteCalls++;
        if (State == "image-delete-close-busy")
        { try { await Task.Delay(Timeout.Infinite, cancellationToken); } catch (OperationCanceledException) { ImageDeleteCancelled = true; throw; } }
        if (State == "image-delete-rejected") return new(1, MutationResultStatus.PermissionDenied, "deleteContainerImages", true, true, new(0, request.Baselines.Count, 0), MutationErrorCategory.Permission);
        var unknown = State == "image-delete-unknown"; var partial = State == "image-delete-partial";
        var count = unknown ? 0 : partial ? 1 : request.Baselines.Count;
        foreach (var target in request.Baselines.Take(count)) _deleted.Add(target.Id);
        if (unknown || partial) _pending.Add(new(request.RequestId, request.Baselines));
        return new(1, unknown ? MutationResultStatus.SubmittedButUnverified : partial ? MutationResultStatus.PartialSuccess : MutationResultStatus.ConfirmedSuccess,
            "deleteContainerImages", true, unknown || partial, new(count, 0, request.Baselines.Count - count));
    }
}

internal sealed class SmokeRepository : IDsmRepository, INasDetailsRepository, ISynologyPhotosProvider, IChatRepository,
    IContainerManagerRepository, IVirtualMachineManagerRepository, IDownloadStationRepository
{
    private int _liveMessageCount = 5;
    private static readonly VirtualizationResourceSummary CreationStorage = new("store-a", "Demo storage", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy);
    private VirtualMachineCreationRequest? _creation;
    private bool _creationFinished;
    public int VmCreates { get; private set; }
    public int VmImageImports { get; private set; }
    public int VmImageImportReviews { get; private set; }
    public bool VmImageImportCancelled { get; private set; }
    private VirtualMachineImageImportRequest? _imageImportRequest;
    private static VirtualizationResourceSummary[] ImportStorages => [new("store-a", "Primary storage", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy), new("store-b", "Secondary storage", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy)];
    public bool CanImportImages => VmPowerState != "vmimport-readonly";
    public async Task<IReadOnlyList<VirtualizationResourceSummary>> LoadImageImportStoragesAsync(CancellationToken token = default)
    {
        if (VmPowerState == "vmimport-loading")
        { try { await Task.Delay(Timeout.Infinite, token); } catch (OperationCanceledException) { VmImageImportCancelled = true; throw; } }
        if (VmPowerState == "vmimport-error") throw new IOException("合成存储读取失败。");
        return VmPowerState == "vmimport-empty" ? [] : ImportStorages;
    }
    public Task<IReadOnlyList<VirtualMachineImageImportRequest>> GetImageImportRecoveriesAsync(CancellationToken token = default)
    {
        if (VmPowerState == "vmimport-recovery") _imageImportRequest ??= new(ProfileId, "Pending image", "/share/pending.iso", VirtualMachineImageType.Iso, ImportStorages, Guid.NewGuid(), false);
        return Task.FromResult<IReadOnlyList<VirtualMachineImageImportRequest>>(_imageImportRequest is null ? [] : [_imageImportRequest with { RiskConfirmed = false }]);
    }
    public async Task<VirtualMachineImageImportResult> ImportImageAsync(VirtualMachineImageImportRequest request, CancellationToken token = default)
    {
        VmImageImports++; _imageImportRequest = request;
        if (VmPowerState == "vmimport-close-busy")
        { try { await Task.Delay(Timeout.Infinite, token); } catch (OperationCanceledException) { VmImageImportCancelled = true; throw; } }
        return ImportResult(VmPowerState is "vmimport-unknown" or "vmimport-review" or "vmimport-auth" ? VirtualMachineImageImportStage.VerifyReceipt : VirtualMachineImageImportStage.Complete);
    }
    public Task<VirtualMachineImageImportResult?> ReviewImageImportAsync(Guid requestId, CancellationToken token = default)
    { VmImageImportReviews++; return Task.FromResult<VirtualMachineImageImportResult?>(ImportResult(VmPowerState == "vmimport-unknown" ? VirtualMachineImageImportStage.VerifyReceipt : VirtualMachineImageImportStage.Complete)); }
    private VirtualMachineImageImportResult ImportResult(VirtualMachineImageImportStage stage) => new(_imageImportRequest!.RequestId, stage,
        new(1, stage == VirtualMachineImageImportStage.Complete ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified,
            "virtualMachineImageImport", true, true, stage == VirtualMachineImageImportStage.Complete ? new(1, 0, 0) : new(0, 0, 1),
            VmPowerState == "vmimport-auth" ? MutationErrorCategory.Authentication : null), stage == VirtualMachineImageImportStage.Complete ? 100 : null);
    public int VmContinues { get; private set; }
    public int VmCreationReviews { get; private set; }
    public bool VmCreationCancelled { get; private set; }
    public int VmConsoleOpens { get; private set; }
    public int VmConsoleDocumentReads { get; private set; }
    public bool VmConsoleCancelled { get; private set; }
    public VirtualMachineConsoleSession? VmConsoleSession { get; private set; }
    public VirtualMachineConsoleDocument? VmConsoleDocument { get; private set; }
    public int VmConsoleAssetReads { get; private set; }
    public int VmConsoleSocketOpens { get; private set; }
    public bool VmConsoleSocketDisposed { get; private set; }
    public bool CanOpenConsole => VmPowerState.StartsWith("vmconsole-", StringComparison.Ordinal) && VmPowerState != "vmconsole-unavailable";
    public async Task<VirtualMachineConsoleSession> OpenConsoleAsync(VirtualMachineSummary baseline, CancellationToken token = default)
    {
        VmConsoleOpens++;
        if (VmPowerState == "vmconsole-loading")
        { try { await Task.Delay(Timeout.Infinite, token); } catch (OperationCanceledException) { VmConsoleCancelled = true; throw; } }
        if (VmPowerState == "vmconsole-error") throw new DsmException(UserText.Key("VmConsoleLoadFailed"), UserText.Key("VmConsoleReconnect"));
        var origin = VmPowerState == "vmconsole-managed-alias" ? "https://console.invalid:5001/vmm-alias" :
            VmPowerState == "vmconsole-managed-ip" ? "https://127.0.0.1:5001" : VmPowerState == "vmconsole-managed-ipv6" ? "https://[::1]:5001" : "https://console.invalid:5001";
        var policy = VirtualMachineConsolePolicy.Create(new(origin), baseline.Id, baseline.Name, "en-us", Guid.NewGuid());
        var managed = VmPowerState.StartsWith("vmconsole-managed", StringComparison.Ordinal);
        VmConsoleSession = new(ProfileId, baseline.Id, baseline.Name, policy, "synthetic-console-cookie", async cancellation =>
        {
            VmConsoleDocumentReads++;
            if (VmPowerState == "vmconsole-close-document")
            { try { await Task.Delay(Timeout.Infinite, cancellation); } catch (OperationCanceledException) { VmConsoleCancelled = true; throw; } }
            const string html = """
                <!doctype html><meta charset="utf-8"><title>Synthetic console</title>
                <style>body{background:#152234;color:#eef5ff;font:24px system-ui;padding:48px}#screen{border:1px solid #6599bd;padding:36px;min-height:220px}small{font-size:16px}</style>
                <h1>Synthetic VM console</h1><div id="screen" tabindex="0">Keyboard and pointer surface<br><small>No NAS connection or real virtual machine.</small></div>
                <script>window.violations=[];window.fixtureErrors=[];window.addEventListener('error',e=>fixtureErrors.push(e.message)); document.addEventListener('securitypolicyviolation',e=>violations.push(e.effectiveDirective));window.fixtureReady=true;</script>
                """;
            var content = managed ? html + "<script src=\"./fixture.js?v=1\"></script>" : html;
            VmConsoleDocument = new(System.Text.Encoding.UTF8.GetBytes(content), "img-src 'none'"); return VmConsoleDocument;
        }, managed ? async (uri, cancellation) =>
        {
            VmConsoleAssetReads++;
            if (uri.AbsolutePath.EndsWith("/app/locale/zh.json", StringComparison.Ordinal))
            {
                if (VmPowerState == "vmconsole-managed-locale-error") throw new IOException("合成语言读取失败。");
                if (VmPowerState == "vmconsole-managed-close-locale")
                { try { await Task.Delay(Timeout.Infinite, cancellation); } catch (OperationCanceledException) { VmConsoleCancelled = true; throw; } }
                return new VirtualMachineConsoleDocument(System.Text.Encoding.UTF8.GetBytes("{\"ready\":true}"), null, "application/json");
            }
            // 独立按官方页面的 URL 参数拼接 socket，不能复用被测 Policy.SocketUri 掩盖缺失参数。
            var script = "const locale=new XMLHttpRequest();locale.open('GET','app/locale/zh.json');locale.onload=()=>{window.consoleLocaleReady=locale.status===200&&JSON.parse(locale.responseText).ready;" +
                "if(!consoleLocaleReady)throw new Error('synthetic locale failed');const p=new URLSearchParams(location.search);const alias=p.get('app_alias');" +
                "const endpoint='wss://'+location.host+(alias?'/'+alias:'')+'/'+p.get('path')+'?app_id='+p.get('app_id');window.consoleSocket=new WebSocket(endpoint,['binary']);" +
                "consoleSocket.binaryType='arraybuffer';consoleSocket.onopen=()=>consoleSocket.send(new Uint8Array([1,2,255]));" +
                "consoleSocket.onmessage=e=>{window.consoleEcho=Array.from(new Uint8Array(e.data)).join(',');document.getElementById('screen').textContent='Synthetic binary exchange: '+consoleEcho};};" +
                "locale.onerror=()=>fixtureErrors.push('synthetic locale blocked');locale.send();";
            return new VirtualMachineConsoleDocument(System.Text.Encoding.UTF8.GetBytes(script), null, "text/javascript");
        } : null, managed ? async cancellation =>
        {
            VmConsoleSocketOpens++;
            if (VmPowerState == "vmconsole-managed-close")
            { try { await Task.Delay(Timeout.Infinite, cancellation); } catch (OperationCanceledException) { VmConsoleCancelled = true; throw; } }
            return new ConsoleEchoSocket(() => VmConsoleSocketDisposed = true);
        } : null);
        return VmConsoleSession;
    }
    private sealed class ConsoleEchoSocket(Action disposed) : System.Net.WebSockets.WebSocket
    {
        private readonly System.Threading.Channels.Channel<byte[]> _data = System.Threading.Channels.Channel.CreateUnbounded<byte[]>();
        private bool _disposed;
        public override System.Net.WebSockets.WebSocketState State => _disposed ? System.Net.WebSockets.WebSocketState.Aborted : System.Net.WebSockets.WebSocketState.Open;
        public override System.Net.WebSockets.WebSocketCloseStatus? CloseStatus => null;
        public override string? CloseStatusDescription => null;
        public override string? SubProtocol => "binary";
        public override void Abort() { _disposed = true; disposed(); _data.Writer.TryComplete(); }
        public override void Dispose() => Abort();
        public override Task CloseAsync(System.Net.WebSockets.WebSocketCloseStatus status, string? description, CancellationToken token) { Abort(); return Task.CompletedTask; }
        public override Task CloseOutputAsync(System.Net.WebSockets.WebSocketCloseStatus status, string? description, CancellationToken token) => CloseAsync(status, description, token);
        public override Task SendAsync(ArraySegment<byte> bytes, System.Net.WebSockets.WebSocketMessageType type, bool end, CancellationToken token)
        { token.ThrowIfCancellationRequested(); if (type != System.Net.WebSockets.WebSocketMessageType.Binary || !end) throw new InvalidOperationException("合成控制台二进制消息错误。"); _data.Writer.TryWrite(bytes.ToArray()); return Task.CompletedTask; }
        public override async Task<System.Net.WebSockets.WebSocketReceiveResult> ReceiveAsync(ArraySegment<byte> buffer, CancellationToken token)
        { var bytes = await _data.Reader.ReadAsync(token); bytes.CopyTo(buffer.AsSpan()); return new(bytes.Length, System.Net.WebSockets.WebSocketMessageType.Binary, true); }
    }
    public bool VmCreationPowerRequested => _creation?.PowerOnAfterCreation == true;
    public VirtualMachineCreationRequest? VmCreationRequest => _creation;
    public bool CanCreateAdvancedMachine => VmPowerState.StartsWith("vmcreate-advanced", StringComparison.Ordinal);
    public bool VmAdvancedReadFailure { get; set; }
    public Task<VirtualMachineAdvancedCreationInventory> LoadAdvancedCreationInventoryAsync(CancellationToken token = default)
    {
        if (VmPowerState == "vmcreate-advanced-error" || VmAdvancedReadFailure) throw new IOException("合成高级资源读取失败。");
        return Task.FromResult(new VirtualMachineAdvancedCreationInventory(ProfileId, VmPowerState == "vmcreate-advanced-frozen", false,
            [new("store-a", "Demo storage", "host-a", "Demo host", 0, "107374182400", "0", "online", "healthy")],
            [new("iso-a", "Demo installation ISO", "store-a", "host-a", "iso", "online", "healthy")]));
    }
    public bool CanCreateMachine => VmPowerState.StartsWith("vmcreate-", StringComparison.Ordinal) && VmPowerState != "vmcreate-readonly";
    public async Task<IReadOnlyList<VirtualMachineCreationRecovery>> GetCreationRecoveriesAsync(CancellationToken token = default)
    {
        if (VmPowerState == "vmcreate-loading") await Task.Delay(Timeout.Infinite, token);
        if (VmPowerState == "vmcreate-error") throw new IOException("合成创建选项读取失败");
        if (VmPowerState == "vmcreate-recovery" && _creation is null)
            _creation = new(ProfileId, CreationStorage, [new(20480)], [new(null)], new("Pending VM", "Synthetic configuration", 2, 2048, VirtualMachineAutoStart.Off), Guid.NewGuid(), false);
        return _creation is not null && !_creationFinished ? [new(_creation with { RiskConfirmed = false })] : [];
    }
    public async Task<VirtualMachineCreationResult> CreateMachineAsync(VirtualMachineCreationRequest request, CancellationToken token = default)
    {
        VmCreates++; _creation = request;
        if (VmPowerState is "vmcreate-close-busy" or "vmcreate-advanced-close-busy")
        { try { await Task.Delay(Timeout.Infinite, token); } catch (OperationCanceledException) { VmCreationCancelled = true; throw; } }
        return CreationResult(VmPowerState switch { "vmcreate-wait" or "vmcreate-power-wait" or "vmcreate-image-wait" => VirtualMachineCreationStage.Creating,
            "vmcreate-power-unknown" => VirtualMachineCreationStage.VerifyPower, "vmcreate-unknown" or "vmcreate-advanced-unknown" or "vmcreate-image-unknown" => VirtualMachineCreationStage.VerifyReceipt,
            "vmcreate-image-hardware" => VirtualMachineCreationStage.VerifyConfiguration, "vmcreate-partial" => VirtualMachineCreationStage.Rejected, _ => VirtualMachineCreationStage.Complete });
    }
    public Task<VirtualMachineCreationResult?> ContinueCreationAsync(Guid requestId, bool riskConfirmed, CancellationToken token = default)
    { if (!riskConfirmed || requestId != _creation?.RequestId) throw new InvalidOperationException("合成继续缺少确认。"); VmContinues++; return Task.FromResult<VirtualMachineCreationResult?>(CreationResult(VirtualMachineCreationStage.Complete)); }
    public Task<VirtualMachineCreationResult?> ReviewCreationAsync(Guid requestId, CancellationToken token = default)
    { VmCreationReviews++; return Task.FromResult<VirtualMachineCreationResult?>(CreationResult(_creationFinished ? VirtualMachineCreationStage.Complete :
        VmPowerState is "vmcreate-power-wait" or "vmcreate-image-wait" ? VirtualMachineCreationStage.PowerOn : VmPowerState == "vmcreate-power-unknown" ? VirtualMachineCreationStage.VerifyPower :
        VmPowerState == "vmcreate-image-hardware" ? VirtualMachineCreationStage.VerifyConfiguration :
        VmPowerState is "vmcreate-wait" or "vmcreate-recovery" ? VirtualMachineCreationStage.Configure : VirtualMachineCreationStage.VerifyReceipt)); }
    private VirtualMachineCreationResult CreationResult(VirtualMachineCreationStage stage)
    {
        _creationFinished = stage == VirtualMachineCreationStage.Complete;
        return new(_creation!.RequestId, stage, new(1, _creationFinished ? MutationResultStatus.ConfirmedSuccess : stage == VirtualMachineCreationStage.Rejected ? MutationResultStatus.PartialSuccess : MutationResultStatus.SubmittedButUnverified,
            "createVirtualMachine", true, true, _creationFinished ? new(2, 0, 0) : stage == VirtualMachineCreationStage.Rejected ? new(1, 1, 0) : new(0, 0, 1)),
            stage == VirtualMachineCreationStage.Creating ? 20 : 100, _creationFinished ? "created-vm" : null, stage is VirtualMachineCreationStage.Configure or VirtualMachineCreationStage.PowerOn);
    }
    public bool CanReadTasks => VmPowerState.StartsWith("vmtasks-", StringComparison.Ordinal) && VmPowerState != "vmtasks-unavailable";
    public int VmTaskReads { get; private set; }
    public bool VmTaskReadCancelled { get; private set; }
    public async Task<IReadOnlyList<VirtualMachineTaskSummary>> LoadVirtualMachineTasksAsync(CancellationToken token = default)
    {
        VmTaskReads++;
        if (VmPowerState is "vmtasks-loading" or "vmtasks-hide")
        { try { await Task.Delay(Timeout.Infinite, token); } catch (OperationCanceledException) { VmTaskReadCancelled = true; throw; } }
        if (VmPowerState == "vmtasks-error" || VmPowerState == "vmtasks-refresh-error" && VmTaskReads > 1) throw new IOException("合成任务读取失败");
        if (VmPowerState == "vmtasks-empty") return [];
        if (VmPowerState == "vmtasks-finished" || VmPowerState == "vmtasks-poll" && VmTaskReads > 1) return [new("safe-key-a", VirtualMachineTaskState.Finished, 100)];
        return [new("safe-key-a", VirtualMachineTaskState.Running, 30), new("safe-key-b", VirtualMachineTaskState.Finished, 100), new("safe-key-c", VirtualMachineTaskState.ReadFailed, null)];
    }
    private VirtualMachineSettings? _settings;
    private VirtualMachineSettingsRequest? _settingsPending;
    public int VmSettingsCalls { get; private set; }
    public VirtualMachineSettingsRequest? VmLastSettingsRequest { get; private set; }
    public bool CanEditSettings => VmPowerState.StartsWith("vmsettings-", StringComparison.Ordinal) && VmPowerState != "vmsettings-readonly";
    public bool CanEditPriority => VmPowerState.StartsWith("vmsettings-priority-", StringComparison.Ordinal) && VmPowerState != "vmsettings-priority-readonly";
    public async Task<VirtualMachineSettings> LoadSettingsAsync(string id, CancellationToken token = default)
    {
        if (VmPowerState == "vmsettings-loading") await Task.Delay(Timeout.Infinite, token);
        if (VmPowerState == "vmsettings-error") throw new IOException("合成设置读取失败");
        return _settings ??= new(id, VmPowerState is "vmsettings-running" or "vmsettings-priority-running" ? VirtualMachineOperationalState.Running : VirtualMachineOperationalState.Stopped,
            new("Demo VM", "Synthetic description", 2, 2048, VirtualMachineAutoStart.PreviousState)
            { CpuWeight = VmPowerState.StartsWith("vmsettings-priority-", StringComparison.Ordinal) ? VmPowerState == "vmsettings-priority-custom" ? 128 : 256 : null });
    }
    public Task<IReadOnlyList<VirtualMachineSettingsRecovery>> GetSettingsRecoveriesAsync(CancellationToken token = default) =>
        Task.FromResult<IReadOnlyList<VirtualMachineSettingsRecovery>>(_settingsPending is null ? [] : [new(_settingsPending.Baseline.Id, _settingsPending.Desired.Name)]);
    public Task<MutationResult?> ReviewSettingsAsync(string id, CancellationToken token = default) => Task.FromResult<MutationResult?>(
        new(1, MutationResultStatus.PartialSuccess, "saveVirtualMachineSettings", true, true, new(1, 0, 1)));
    public Task<MutationResult> SaveSettingsAsync(VirtualMachineSettingsRequest request, CancellationToken token = default)
    {
        VmSettingsCalls++; VmLastSettingsRequest = request;
        if (VmPowerState is "vmsettings-partial" or "vmsettings-priority-unknown")
        { _settingsPending = request; return Task.FromResult(new MutationResult(1, MutationResultStatus.PartialSuccess, "saveVirtualMachineSettings", true, true, new(1, 0, 1))); }
        _settings = request.Baseline with { Configuration = request.Desired };
        return Task.FromResult(new MutationResult(1, MutationResultStatus.ConfirmedSuccess, "saveVirtualMachineSettings", true, false, new(2, 0, 0)));
    }
    internal static int ActiveRealtimeSubscriptions;
    private static string VmPowerState => Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "";
    private VirtualMachineOperationalState? _vmState;
    private VirtualMachinePowerRecovery? _vmPending;
    private bool _vmPendingSeeded;
    public int VmPowerCalls { get; private set; }
    public bool VmPowerCancelled { get; private set; }
    public bool CanControlPower => VmPowerState.StartsWith("vmpower-", StringComparison.Ordinal) && VmPowerState != "vmpower-readonly" ||
        VmPowerState.StartsWith("vmcreate-", StringComparison.Ordinal) && VmPowerState is not ("vmcreate-readonly" or "vmcreate-power-readonly");
    public async Task<IReadOnlyList<VirtualMachinePowerRecovery>> GetPowerRecoveriesAsync(CancellationToken token = default)
    {
        if (VmPowerState == "vmpower-loading") await Task.Delay(Timeout.Infinite, token);
        if (VmPowerState == "vmpower-error") throw new IOException("合成核查失败");
        if (!_vmPendingSeeded && VmPowerState is "vmpower-pending" or "vmpower-recovered")
        { _vmPending = new("sample-vm", "Demo VM", VirtualMachinePowerAction.PowerOn); _vmPendingSeeded = true; }
        return _vmPending is null ? [] : [_vmPending];
    }
    public Task<MutationResult?> ReviewPowerAsync(string id, CancellationToken token = default)
    {
        if (VmPowerState == "vmpower-recovered")
        { _vmPending = null; _vmState = VirtualMachineOperationalState.Running; return Task.FromResult<MutationResult?>(new(1, MutationResultStatus.ConfirmedSuccess, "virtualMachinePower", true, false, new(1, 0, 0))); }
        return Task.FromResult<MutationResult?>(new(1, MutationResultStatus.SubmittedButUnverified, "virtualMachinePower", true, true, new(0, 0, 1)));
    }
    public async Task<MutationResult> ControlPowerAsync(VirtualMachinePowerRequest request, CancellationToken token = default)
    {
        VmPowerCalls++;
        if (VmPowerState == "vmpower-close-busy")
        { try { await Task.Delay(Timeout.Infinite, token); } catch (OperationCanceledException) { VmPowerCancelled = true; throw; } }
        if (VmPowerState == "vmpower-rejected") return new(1, MutationResultStatus.PermissionDenied, "virtualMachinePower", true, true, new(0, 1, 0), MutationErrorCategory.Permission);
        if (VmPowerState == "vmpower-unknown")
        { _vmPending = new(request.Baseline.Id, request.Baseline.Name, request.Action); return new(1, MutationResultStatus.SubmittedButUnverified, "virtualMachinePower", true, true, new(0, 0, 1)); }
        _vmState = request.Action == VirtualMachinePowerAction.PowerOn ? VirtualMachineOperationalState.Running : VirtualMachineOperationalState.Stopped;
        return new(1, MutationResultStatus.ConfirmedSuccess, "virtualMachinePower", true, false, new(1, 0, 0));
    }
    public bool CanBrowseRegistry => RegistryState != "registry-unavailable";
    private static string RegistryState => Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "";
    public int RegistrySearchCalls { get; private set; }
    public int RegistryTagCalls { get; private set; }
    public bool RegistryCancelled { get; private set; }
    public async Task<IReadOnlyList<ContainerRegistryImage>> SearchRegistryAsync(string query, CancellationToken cancellationToken = default)
    {
        RegistrySearchCalls++;
        if (RegistryState == "registry-loading")
        {
            try { await Task.Delay(Timeout.Infinite, cancellationToken); }
            catch (OperationCanceledException) { RegistryCancelled = true; throw; }
        }
        if (RegistryState == "registry-error") throw new IOException("合成仓库搜索失败");
        if (RegistryState == "registry-empty") return [];
        return [new("synthetic/image-a", "registry.invalid", "Synthetic web image", 125, true, false, null),
            new("synthetic/image-b", "registry.invalid", "Synthetic worker image", null, null, true, true)];
    }
    public async Task<IReadOnlyList<string>> LoadRegistryTagsAsync(string repository, CancellationToken cancellationToken = default)
    {
        RegistryTagCalls++;
        if (RegistryState == "registry-tags-loading")
        {
            try { await Task.Delay(Timeout.Infinite, cancellationToken); }
            catch (OperationCanceledException) { RegistryCancelled = true; throw; }
        }
        if (RegistryState == "registry-tags-error") throw new IOException("合成标签读取失败");
        if (RegistryState == "registry-tags-empty") return [];
        if (RegistryState == "registry-switch" && repository.EndsWith("-a", StringComparison.Ordinal)) await Task.Delay(350);
        return repository.EndsWith("-a", StringComparison.Ordinal) ? ["latest", "stable", "v1.0"] : ["worker-v2", "worker-stable"];
    }
    private readonly List<ContainerNetworkCreationRecovery> _networkPending = [];
    private readonly List<ContainerResourceSummary> _createdNetworks = [];
    private readonly List<ContainerNetworkDeletionRecovery> _networkDeletePending = [];
    private readonly HashSet<string> _deletedNetworkIds = [];
    public int NetworkDeleteCalls { get; private set; }
    public bool NetworkDeleteCancelled { get; private set; }
    public bool CanDeleteNetworks => NetworkCreateState.StartsWith("netdelete-", StringComparison.Ordinal) && NetworkCreateState != "netdelete-readonly";
    public Task<IReadOnlyList<ContainerNetworkDeletionRecovery>> GetNetworkDeletionRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        if (NetworkCreateState is "netdelete-pending" or "netdelete-recovered" && !_deletedNetworkIds.Contains("delete-a") && _networkDeletePending.Count == 0)
            _networkDeletePending.Add(new("delete-a", "synthetic-network-a"));
        return Task.FromResult<IReadOnlyList<ContainerNetworkDeletionRecovery>>(_networkDeletePending.ToArray());
    }
    public Task<MutationResult?> ReviewNetworkDeletionAsync(string id, CancellationToken cancellationToken = default)
    {
        if (NetworkCreateState == "netdelete-recovered")
        { _deletedNetworkIds.Add(id); _networkDeletePending.RemoveAll(item => item.Id == id); return Task.FromResult<MutationResult?>(new(1, MutationResultStatus.ConfirmedSuccess, "deleteContainerNetworks", true, false, new(1, 0, 0))); }
        return Task.FromResult<MutationResult?>(new(1, MutationResultStatus.SubmittedButUnverified, "deleteContainerNetworks", true, true, new(0, 0, 1)));
    }
    public async Task<MutationResult> DeleteNetworksAsync(ContainerNetworkDeleteRequest request, CancellationToken cancellationToken = default)
    {
        NetworkDeleteCalls++;
        if (NetworkCreateState == "netdelete-close-busy")
        {
            try { await Task.Delay(Timeout.Infinite, cancellationToken); }
            catch (OperationCanceledException) { NetworkDeleteCancelled = true; throw; }
        }
        if (NetworkCreateState == "netdelete-rejected") return new(1, MutationResultStatus.PermissionDenied, "deleteContainerNetworks", true, true, new(0, request.Baselines.Count, 0), MutationErrorCategory.Permission);
        var count = NetworkCreateState switch { "netdelete-unknown" => 0, "netdelete-partial" => 1, _ => request.Baselines.Count };
        foreach (var target in request.Baselines.Take(count)) _deletedNetworkIds.Add(target.Id);
        foreach (var target in request.Baselines.Skip(count)) _networkDeletePending.Add(new(target.Id, target.Name));
        return new(1, count == request.Baselines.Count ? MutationResultStatus.ConfirmedSuccess : count > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.SubmittedButUnverified,
            "deleteContainerNetworks", true, count != request.Baselines.Count, new(count, 0, request.Baselines.Count - count));
    }
    public int NetworkCreateCalls { get; private set; }
    public ContainerNetworkCreateRequest? LastNetworkCreate { get; private set; }
    public bool NetworkCreateCancelled { get; private set; }
    private static string NetworkCreateState => Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "";
    public bool CanCreateNetworks => NetworkCreateState.StartsWith("netcreate-", StringComparison.Ordinal) && NetworkCreateState != "netcreate-readonly";
    public async Task PrepareNetworkManagementAsync(CancellationToken cancellationToken = default)
    {
        if (NetworkCreateState is "netcreate-loading" or "netdelete-loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        if (NetworkCreateState is "netcreate-error" or "netdelete-error") throw new IOException("合成网络管理核查失败");
    }
    public Task<IReadOnlyList<ContainerNetworkCreationRecovery>> GetNetworkCreationRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ContainerNetworkCreationRecovery>>(NetworkCreateState is "netcreate-pending" or "netcreate-recovered" ? [new("synthetic-net")] : _networkPending.ToArray());
    public Task<MutationResult?> ReviewNetworkCreationAsync(string name, CancellationToken cancellationToken = default) =>
        Task.FromResult<MutationResult?>(NetworkCreateState == "netcreate-recovered" ? new(1, MutationResultStatus.ConfirmedSuccess, "createContainerNetwork", true, false, new(1, 0, 0)) :
            new(1, MutationResultStatus.SubmittedButUnverified, "createContainerNetwork", true, true, new(0, 0, 1)));
    public async Task<MutationResult> CreateNetworkAsync(ContainerNetworkCreateRequest request, CancellationToken cancellationToken = default)
    {
        NetworkCreateCalls++; LastNetworkCreate = request;
        if (NetworkCreateState == "netcreate-close-busy")
        {
            try { await Task.Delay(Timeout.Infinite, cancellationToken); }
            catch (OperationCanceledException) { NetworkCreateCancelled = true; throw; }
        }
        if (NetworkCreateState == "netcreate-rejected") return new(1, MutationResultStatus.PermissionDenied, "createContainerNetwork", true, true, new(0, 1, 0), MutationErrorCategory.Permission);
        var config = request.Configuration;
        if (NetworkCreateState != "netcreate-unknown") _createdNetworks.Add(new("new-network", config.Name, ContainerResourceKind.Network, ContainerOperationalState.Unknown)
            { Network = new("bridge", 0, [], config.Subnet, config.Gateway, config.IpRange, config.IsIpv6Enabled) });
        if (NetworkCreateState == "netcreate-unknown" || config.IsIpv6Enabled || config.DisableMasquerade)
        {
            _networkPending.Add(new(config.Name));
            return new(1, MutationResultStatus.SubmittedButUnverified, "createContainerNetwork", true, true, new(0, 0, 1),
                diagnosticTag: config.IsIpv6Enabled || config.DisableMasquerade ? "container.network.created-options-unverified" : "container.network.create.unverified");
        }
        return new(1, MutationResultStatus.ConfirmedSuccess, "createContainerNetwork", true, false, new(1, 0, 0));
    }
    public async IAsyncEnumerable<ChatRealtimeEvent> ObserveRealtimeAsync([EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") != "chat-realtime") yield break;
        Interlocked.Increment(ref ActiveRealtimeSubscriptions);
        try
        {
            yield return ChatRealtimeEvent.Connected;
            await Task.Delay(800, cancellationToken);
            Interlocked.Increment(ref _liveMessageCount); yield return ChatRealtimeEvent.ContentChanged;
            await Task.Delay(Timeout.Infinite, cancellationToken);
        }
        finally { Interlocked.Decrement(ref ActiveRealtimeSubscriptions); }
    }
    ContainerManagerAvailability IContainerManagerRepository.Availability => new(ContainerManagerAvailabilityStatus.InternalObserved,
        Enum.GetValues<ContainerManagerReadFeature>().ToHashSet());
    public int ContainerReadCount { get; private set; }
    async Task<ContainerManagerSnapshot> IContainerManagerRepository.LoadSnapshotAsync(CancellationToken cancellationToken)
    {
        ContainerReadCount++;
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE");
        if (state == "network-loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        var details = state == "network-zero" ? new ContainerNetworkDetails("host", 0, [], null, null, null, false) :
            state == "network-unknown" ? new ContainerNetworkDetails(null, 3, null, null, null, null, null) :
            new ContainerNetworkDetails("bridge", 2, ["synthetic-web", "synthetic-db"], "192.0.2.0/24", "192.0.2.1", "192.0.2.128/25", true);
        var networks = state == "network-error" ? ContainerManagerSection<ContainerResourceSummary>.Failed :
            state == "network-unavailable" ? ContainerManagerSection<ContainerResourceSummary>.Unavailable :
            state == "network-empty" ? ContainerManagerSection<ContainerResourceSummary>.Available([]) :
            ContainerManagerSection<ContainerResourceSummary>.Available([new("sample-network", "Demo network", ContainerResourceKind.Network, ContainerOperationalState.Unknown)
            { Network = state == "network-legacy" ? null : details }]);
        if (_createdNetworks.Count > 0) networks = ContainerManagerSection<ContainerResourceSummary>.Available(networks.Items.Concat(_createdNetworks).ToArray());
        if (state?.StartsWith("netdelete-", StringComparison.Ordinal) == true)
        {
            ContainerResourceSummary Network(string id, string name, int count = 0) => new(id, name, ContainerResourceKind.Network, ContainerOperationalState.Unknown)
                { Network = new("bridge", count, count == 0 ? [] : ["synthetic-container"], null, null, null, false) };
            var rows = new[] { Network("delete-a", "synthetic-network-a"), Network("delete-b", "synthetic-network-b"), Network("system", "bridge"), Network("used", "synthetic-in-use", 1) };
            networks = ContainerManagerSection<ContainerResourceSummary>.Available(state == "netdelete-empty" ? [] : rows.Where(row => !_deletedNetworkIds.Contains(row.Id)).ToArray());
        }
        return new ContainerManagerSnapshot(ProfileId,
            ContainerManagerSection<ContainerSummary>.Available([new("sample-a", "Demo service", ContainerOperationalState.Running, "demo:latest"), new("sample-b", "Demo worker", ContainerOperationalState.Stopped, "demo:latest")]),
            ContainerManagerSection<ContainerResourceSummary>.Available([]),
            networks,
            ContainerManagerSection<ContainerResourceSummary>.Available([]), ContainerManagerSection<ServiceEventSummary>.Available([]));
    }
    VirtualMachineManagerAvailability IVirtualMachineManagerRepository.Availability => new(VirtualMachineManagerAvailabilityStatus.Available,
        Enum.GetValues<VirtualMachineManagerReadFeature>().ToHashSet());
    Task<VirtualMachineManagerSnapshot> IVirtualMachineManagerRepository.LoadSnapshotAsync(CancellationToken cancellationToken) =>
        Task.FromResult(new VirtualMachineManagerSnapshot(ProfileId,
            VirtualMachineManagerSection<VirtualMachineSummary>.Available([new("sample-vm", "Demo VM", _vmState ?? (VmPowerState is "vmpower-shutdown" or "vmpower-off" || VmPowerState.StartsWith("vmconsole-", StringComparison.Ordinal) && VmPowerState != "vmconsole-stopped" ? VirtualMachineOperationalState.Running : VirtualMachineOperationalState.Stopped), 2, 2147483648, 34359738368, null, null)]),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available([]), VirtualMachineManagerSection<VirtualizationResourceSummary>.Available(VmPowerState.StartsWith("vmcreate-", StringComparison.Ordinal) && VmPowerState != "vmcreate-empty" ? [CreationStorage] : []),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available([]), VirtualMachineManagerSection<VirtualizationResourceSummary>.Available(VmPowerState.StartsWith("vmcreate-", StringComparison.Ordinal) ? [new("image-a", "Demo disk image", VirtualizationResourceKind.Image, VirtualizationResourceHealth.Unknown, Type: "disk")] : []),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available([]), VirtualMachineManagerSection<ServiceEventSummary>.Available([])));
    DownloadStationAvailability IDownloadStationRepository.Availability => new(DownloadStationAvailabilityStatus.Available,
        new HashSet<DownloadStationReadFeature> { DownloadStationReadFeature.Tasks, DownloadStationReadFeature.ActivitySummary, DownloadStationReadFeature.ServerSettings });
    public Task<DownloadSettingsSnapshot> LoadSettingsAsync(CancellationToken cancellationToken = default) => Task.FromResult(new DownloadSettingsSnapshot(ProfileId,
        new("downloads", false, false, 500, 100, 200, 200, 300, 0, 0, false, false), true, DownloadStationSectionStatus.Available));
    public Task<DownloadTaskPage> ListTasksAsync(int offset, int limit, CancellationToken cancellationToken = default) =>
        Task.FromResult(new DownloadTaskPage(Enumerable.Range(1, 8).Select(index => new DownloadTask(
            $"sample-task-{index}", $"Demo archive {index:00}.zip", index == 1 ? "downloading" : "finished", 104857600,
            index == 1 ? 52428800 : 104857600, index == 1 ? 1048576 : 0, 0, null, null)).ToArray(), 0, 8, 8, null, false));
    public async Task<DownloadStationSnapshot> LoadSnapshotAsync(int offset, int limit, CancellationToken cancellationToken = default) =>
        new(ProfileId, await ListTasksAsync(offset, limit, cancellationToken), new(DownloadStationSectionStatus.Available, new(1048576, 0, 0, 0)), new(DownloadStationSectionStatus.Unavailable, null));
    public Task<DownloadTaskControlOutcome> ControlTaskAsync(DownloadTaskControlRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<DownloadTaskControlOutcome>(new NotSupportedException());
    ChatAvailability IChatRepository.Availability => new(ChatAvailabilityStatus.Available,
        new HashSet<ChatReadFeature> { ChatReadFeature.Users, ChatReadFeature.Conversations, ChatReadFeature.Messages },
        new HashSet<ChatWriteFeature> { ChatWriteFeature.TextMessage });
    public Task<IReadOnlyList<ChatUser>> ListUsersAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ChatUser>>([new("sample-user", "Demo", false, false, false)]);
    public Task<IReadOnlyList<ChatUser>> ListConversationMembersAsync(string conversationId,
        CancellationToken cancellationToken = default) => ListUsersAsync(cancellationToken);
    public Task<IReadOnlyList<ChatConversation>> ListConversationsAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ChatConversation>>([new("sample-conversation", ChatConversationKind.Group,
            "Demo", ["sample-user"], 1, null, null, 0, false)]);
    public Task<ChatMessagePage> ListMessagesAsync(string conversationId, string? beforeCursor, int limit,
        CancellationToken cancellationToken = default) => Task.FromResult(new ChatMessagePage(
            Enumerable.Range(1, _liveMessageCount).Select(index => new ChatMessage($"message-{index}", conversationId, "sample-user", "Demo",
                index % 2 == 0, new DateTimeOffset(2026, 9, 16, 8, index, 0, TimeSpan.Zero),
                $"Sample message {index}", [], ChatEncryptionState.NotEncrypted)).ToArray(), null, false, 0, _liveMessageCount, _liveMessageCount));
    public Task<ChatTextSendOutcome> SendTextAsync(ChatTextSendRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<ChatTextSendOutcome>(new NotSupportedException());
    public ISynologyPhotosRepository SynologyPhotos { get; } = new SmokePhotosRepository();
    public Guid ProfileId { get; } = Guid.Parse("11111111-1111-1111-1111-111111111111");
    public NasDetailsAvailability Availability { get; } = new(NasDetailsAvailabilityStatus.Available,
        Enum.GetValues<NasDetailsReadFeature>().ToHashSet());
    private static NasDetailsSection<T> Empty<T>() => new(NasDetailsSectionStatus.Available, []);
    public Task<NasDetailsSnapshot> LoadDetailsAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(new NasDetailsSnapshot(ProfileId,
            new(NasDetailsSectionStatus.Available, [new("Demo", "7.2", 86400, "CPU", 4, 2400, 8589934592, 38, false)]),
            new(NasDetailsSectionStatus.Available, [
                new("volume-demo", NasStorageItemKind.Volume, 1, "normal", ResourceState.Healthy, 4_000_000_000_000, 1_600_000_000_000, "btrfs"),
                new("pool-demo", NasStorageItemKind.Pool, 1, "normal", ResourceState.Healthy, 4_000_000_000_000, RaidType: "SHR"),
                new("drive-demo", NasStorageItemKind.Drive, 1, "normal", ResourceState.Healthy, 4_000_000_000_000, SmartStatus: "normal", TemperatureCelsius: 32)]),
            Empty<NasSystemUpdateSummary>(), Empty<NasShareAccessSummary>(), Empty<NasSystemActivitySummary>(),
            Empty<NasPackageSummary>(), Empty<NasScheduledTaskSummary>(), Empty<NasLogSummary>(), Empty<NasConnectionSummary>()));
    public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadStorageAnalysisAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(Empty<NasStorageAnalysisSummary>());
    public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadDeepStorageAnalysisAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(Empty<NasStorageAnalysisSummary>());
    public IReadOnlyList<AppModule> AvailableModules { get; } = Enum.GetValues<AppModule>();
    private static readonly string[] Folders = ["Documents", "Photos", "Music", "Video", "Projects", "Archive"];
    public Task<FilePage> ListFilesAsync(string path, CancellationToken cancellationToken = default) =>
        ListFilesAsync(path, 0, 100, FileListOptions.Default, cancellationToken);
    public Task<FilePage> ListFilesAsync(string path, int offset, int limit, CancellationToken cancellationToken = default) =>
        ListFilesAsync(path, offset, limit, FileListOptions.Default, cancellationToken);
    public async Task<FilePage> ListFilesAsync(string path, int offset, int limit, FileListOptions options,
        CancellationToken cancellationToken = default)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE");
        if (state == "loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        if (state == "error") throw new IOException("synthetic read failure");
        var date = new DateTimeOffset(2026, 9, 16, 0, 0, 0, TimeSpan.Zero);
        FileItem[] items = state == "empty" ? [] : string.IsNullOrEmpty(path)
            ? Folders.Select(name => new FileItem("/" + name, name, true, 0, date, null, false, false)).ToArray()
            : Enumerable.Range(1, 36).Select(index => new FileItem($"{path}/Sample-{index:00}.txt",
                $"Sample-{index:00}.txt", false, index * 2048, date, null, false, false)).ToArray();
        return new FilePage(items.Skip(offset).Take(limit).ToArray(), items.Length, offset,
            new StorageSpaceSummary(4_000_000_000_000, 2_400_000_000_000, 1));
    }
    public Task<IReadOnlyList<FileItem>> SearchFilesAsync(string path, string query, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<FileItem>>([]);
    public Task<byte[]> ReadFileRangeAsync(string remotePath, long offset, long length, CancellationToken cancellationToken = default) =>
        Task.FromException<byte[]>(new NotSupportedException());
    public Task<FileRangeReadResult> ReadFileRangeResultAsync(string remotePath, long offset, long length,
        string? expectedContentVersion = null, long? expectedTotalLength = null, CancellationToken cancellationToken = default) =>
        Task.FromException<FileRangeReadResult>(new NotSupportedException());
    public Task CreateFolderAsync(string parentPath, string name, CancellationToken cancellationToken = default) =>
        Task.FromException(new NotSupportedException());
    public Task RenameAsync(string path, string newName, CancellationToken cancellationToken = default) =>
        Task.FromException(new NotSupportedException());
    public Task DeleteFilesAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken = default) =>
        Task.FromException(new NotSupportedException());
    public Task<NasSettingsSnapshot> LoadNasSettingsAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<NasSettingsSnapshot>(new NotSupportedException());
}

internal sealed class SmokePhotosRepository : ISynologyPhotosRepository
{
    public Guid ProfileId { get; } = Guid.Parse("11111111-1111-1111-1111-111111111111");
    public Task<SynologyPhotoAccess> AccessAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(new SynologyPhotoAccess([SynologyPhotoSpace.Personal], "synthetic"));
    public Task<IReadOnlyList<SynologyPhotoDay>> TimelineAsync(SynologyPhotoQuery? query = null,
        CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<SynologyPhotoDay>>(
            Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") == "photo-empty"
                ? [] : [new(new DateOnly(2026, 9, 16), 8)]);
    public async Task<SynologyPhotoPage> PhotosAsync(SynologyPhotoQuery query, int offset, int limit,
        CancellationToken cancellationToken = default)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE");
        if (state == "photo-loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        if (state == "photo-error") throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
        var date = new DateTimeOffset(2026, 9, 16, 0, 0, 0, TimeSpan.Zero);
        var items = Enumerable.Range(1, 8).Select(index => new SynologyPhoto(
            new(ProfileId, SynologyPhotoSpace.Personal, index), $"Sample-{index:00}.jpg",
            2048, date, date, 1, "photo")).Skip(offset).Take(limit).ToArray();
        return new SynologyPhotoPage(items, offset, offset + items.Length, false);
    }
}

internal sealed class SmokeAdvancedChatRepository(string state) : IChatRepository
{
    public int MutationCalls { get; private set; }
    private readonly HashSet<string> _closed = [];
    private readonly HashSet<Guid> _actions = [];
    private bool _pinned;
    public Guid ProfileId { get; } = Guid.NewGuid();
    public ChatAvailability Availability => new(ChatAvailabilityStatus.Available,
        new HashSet<ChatReadFeature> { ChatReadFeature.Reminders, ChatReadFeature.ScheduledMessages, ChatReadFeature.Polls, ChatReadFeature.Conversations, ChatReadFeature.PinnedMessages, ChatReadFeature.Messages, ChatReadFeature.Users },
        state == "advanced-readonly" ? new HashSet<ChatWriteFeature>() : new HashSet<ChatWriteFeature> { ChatWriteFeature.Reminders, ChatWriteFeature.ScheduledMessages, ChatWriteFeature.Polls, ChatWriteFeature.CloseConversation, ChatWriteFeature.ForwardMessage, ChatWriteFeature.PinnedMessages, ChatWriteFeature.DirectConversation, ChatWriteFeature.DeleteOwnMessage });
    public async Task<IReadOnlyList<ChatReminder>> ListRemindersAsync(string conversationId, CancellationToken cancellationToken = default)
    {
        if (state == "advanced-loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        if (state == "advanced-error") throw new IOException("synthetic");
        return state == "advanced-empty" ? [] : [new("sample-message", conversationId, DateTimeOffset.Now.AddHours(1))];
    }
    public Task<IReadOnlyList<ChatScheduledMessage>> ListScheduledMessagesAsync(string conversationId, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ChatScheduledMessage>>([new("sample-schedule", conversationId, "Synthetic scheduled message", DateTimeOffset.Now.AddHours(2))]);
    public Task<ChatReminderSetOutcome> SetReminderAsync(string messageId, string conversationId, DateTimeOffset remindAt, Guid clientRequestId, CancellationToken cancellationToken = default)
    {
        MutationCalls++;
        return Task.FromResult(state == "advanced-success"
            ? new ChatReminderSetOutcome(new MutationResult(1, MutationResultStatus.ConfirmedSuccess, "setReminder", true, false, new(1, 0, 0)), messageId, conversationId, clientRequestId, new(messageId, conversationId, remindAt))
            : state == "advanced-rejected"
                ? new ChatReminderSetOutcome(new MutationResult(1, MutationResultStatus.ConfirmedFailure, "setReminder", true, false, new(0, 1, 0), MutationErrorCategory.Permission), messageId, conversationId, clientRequestId, null)
            : new ChatReminderSetOutcome(new MutationResult(1, MutationResultStatus.SubmittedButUnverified, "setReminder", true, true, new(0, 0, 1)), messageId, conversationId, clientRequestId, null));
    }
    public Task<IReadOnlyList<ChatUser>> ListUsersAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<ChatUser>>([new("self", "Demo self", null, false, true), new("sample-user", "Demo recipient", null, false, false)]);
    public Task<IReadOnlyList<ChatConversation>> ListConversationsAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ChatConversation>>(new[] { "sample-chat", "2", "3" }.Where(id => !_closed.Contains(id))
            .Select(id => new ChatConversation(id, ChatConversationKind.Group, "Demo " + id, ["sample-user"], 1, null, null, 0, false)).ToArray());
    private static MutationResult Completed(string operation) => new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(1, 0, 0));
    public Task<MutationResult> CloseConversationAsync(ChatCloseConversationRequest request, CancellationToken cancellationToken = default)
    {
        if (_actions.Add(request.ClientRequestId)) MutationCalls++;
        if (state == "batch-close" && request.ConversationId == "2") return Task.FromResult(new MutationResult(1, MutationResultStatus.ConfirmedFailure, "closeConversation", false, false, new(0, 1, 0), MutationErrorCategory.Permission));
        _closed.Add(request.ConversationId); return Task.FromResult(Completed("closeConversation"));
    }
    public Task<MutationResult> ForwardMessageAsync(ChatForwardRequest request, CancellationToken cancellationToken = default)
    {
        if (_actions.Add(request.ClientRequestId))
        {
            MutationCalls++;
            if (state == "batch-review" && MutationCalls == 1) return Task.FromResult(new MutationResult(1, MutationResultStatus.SubmittedButUnverified, "forwardMessage", true, true, new(0, 0, 1)));
        }
        return Task.FromResult(Completed("forwardMessage"));
    }
    public Task<MutationResult> DeleteOwnMessageAsync(ChatDeleteMessageRequest request, CancellationToken cancellationToken = default)
    { if (_actions.Add(request.ClientRequestId)) MutationCalls++; return Task.FromResult(Completed("deleteOwnMessage")); }
    public Task<ChatConversationCreateOutcome> OpenDirectConversationAsync(ChatDirectConversationRequest request, CancellationToken cancellationToken = default)
    {
        if (_actions.Add(request.ClientRequestId)) MutationCalls++;
        return Task.FromResult(new ChatConversationCreateOutcome(Completed("chatDirectConversation"), request.ClientRequestId,
            new("4", ChatConversationKind.Direct, "Demo new direct", ["self", request.UserId], 2, null, null, 0, false)));
    }
    public Task<MutationResult> SetMessagePinnedAsync(ChatPinMessageRequest request, CancellationToken cancellationToken = default)
    { MutationCalls++; _pinned = request.IsPinned; return Task.FromResult(Completed("setMessagePinned")); }
    public Task<IReadOnlyList<ChatPinnedMessage>> ListPinnedMessagesAsync(string conversationId, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ChatPinnedMessage>>(_pinned ? [new("sample-message", conversationId, "synthetic-user", "Demo", DateTimeOffset.Now, DateTimeOffset.Now, "Synthetic announcement")] : []);
    public Task<ChatMessage> GetMessageAsync(string conversationId, string messageId, CancellationToken cancellationToken = default) =>
        Task.FromResult(new ChatMessage(messageId, conversationId, "synthetic-user", "Demo", true, DateTimeOffset.Now, "Synthetic message for reminder", [], ChatEncryptionState.NotEncrypted));
    public Task<IReadOnlyList<ChatUser>> ListConversationMembersAsync(string conversationId, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<ChatMessagePage> ListMessagesAsync(string conversationId, string? beforeCursor, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<ChatTextSendOutcome> SendTextAsync(ChatTextSendRequest request, CancellationToken cancellationToken = default) => throw new NotSupportedException();
}

internal sealed class SmokeDownloadBatchRepository(string state) : IDownloadStationRepository
{
    public Guid ProfileId { get; } = Guid.NewGuid();
    public DownloadStationAvailability Availability => new(DownloadStationAvailabilityStatus.Available, new HashSet<DownloadStationReadFeature> { DownloadStationReadFeature.Tasks });
    private readonly HashSet<string> _written = [];
    public int Writes => _written.Count;
    public async Task<DownloadTaskPage> ListTasksAsync(int offset, int limit, CancellationToken cancellationToken = default)
    {
        if (state == "batch-loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        if (state == "batch-error") throw new IOException("synthetic");
        var tasks = state == "batch-empty" ? Array.Empty<DownloadTask>() : Enumerable.Range(1, 3).Select(id =>
            new DownloadTask(id.ToString(), "Synthetic download " + id, state == "batch-resume" ? "paused" : "downloading", 100, 20, 0, 0, null, null)).ToArray();
        return new(tasks, 0, tasks.Length, tasks.Length, null, false);
    }
    private MutationResult Result(string id)
    {
        var first = _written.Add(id);
        if (state == "batch-review" && id == "1" && first) return new(1, MutationResultStatus.SubmittedButUnverified, "downloadBatch", true, true, new(0, 0, 1));
        if (state == "batch-partial" && id == "2") return new(1, MutationResultStatus.ConfirmedFailure, "downloadBatch", true, false, new(0, 1, 0));
        return new(1, MutationResultStatus.ConfirmedSuccess, "downloadBatch", true, false, new(1, 0, 0));
    }
    public Task<DownloadTaskControlOutcome> ControlTaskAsync(DownloadTaskControlRequest request, CancellationToken cancellationToken = default) =>
        Task.FromResult(new DownloadTaskControlOutcome(Result(request.Task.Id), request.Task.Id,
            request.Task with { State = request.Action == DownloadTaskControlAction.Pause ? DownloadTaskState.Paused : DownloadTaskState.Downloading,
                RawStatus = request.Action == DownloadTaskControlAction.Pause ? "paused" : "downloading" }));
    public Task<DownloadTaskDeleteOutcome> DeleteTaskAsync(DownloadTaskDeleteRequest request, CancellationToken cancellationToken = default)
    {
        if (request.ForceComplete != (state == "batch-finish")) throw new InvalidOperationException("结束与移除任务语义混淆。");
        return Task.FromResult(new DownloadTaskDeleteOutcome(Result(request.Task.Id), request.Task.Id));
    }
    public Task<DownloadStationSnapshot> LoadSnapshotAsync(int offset, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
}

internal sealed class SmokeDownloadSettingsRepository(string state) : IDownloadStationRepository, IFileCopyMoveFolderSource
{
    public Guid ProfileId { get; } = Guid.NewGuid();
    public DownloadStationAvailability Availability => new(DownloadStationAvailabilityStatus.Available, new HashSet<DownloadStationReadFeature> { DownloadStationReadFeature.ServerSettings });
    private DownloadStationSettingsSummary _value = new(state == "settings-v1" ? null : "downloads", false, false, 500, 100, 200, 200, 300, 0, 0,
        state == "settings-no-schedule" ? null : false, state == "settings-no-schedule" ? null : false);
    private readonly HashSet<Guid> _basics = [];
    private readonly HashSet<Guid> _schedules = [];
    public int BasicWrites => _basics.Count;
    public int ScheduleWrites => _schedules.Count;
    public async Task<DownloadSettingsSnapshot> LoadSettingsAsync(CancellationToken cancellationToken = default)
    {
        if (state == "settings-loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        if (state == "settings-error") throw new IOException("synthetic");
        return new(ProfileId, _value, state != "settings-v1", state == "settings-no-schedule" ? DownloadStationSectionStatus.Unavailable : DownloadStationSectionStatus.Available);
    }
    public Task<DownloadSettingsSaveOutcome> SaveSettingsAsync(DownloadSettingsSaveRequest request, CancellationToken cancellationToken = default)
    {
        var first = _basics.Add(request.ClientRequestId);
        if (state == "settings-review" && first)
            return Task.FromResult(new DownloadSettingsSaveOutcome(new(1, MutationResultStatus.SubmittedButUnverified, "downloadSettings", true, true, new(0, 1, 1)), null,
                DownloadSettingsComponentState.Unknown, DownloadSettingsComponentState.NotStarted));
        if (state == "settings-review" && !request.ContinueRemaining)
            return Task.FromResult(new DownloadSettingsSaveOutcome(new(1, MutationResultStatus.PartialSuccess, "downloadSettings", true, false, new(1, 1, 0)), null,
                DownloadSettingsComponentState.Confirmed, DownloadSettingsComponentState.NotStarted));
        if (request.Desired.IsScheduleEnabled != request.Expected.Value.IsScheduleEnabled) _schedules.Add(request.ClientRequestId);
        if (state == "settings-partial")
            return Task.FromResult(new DownloadSettingsSaveOutcome(new(1, MutationResultStatus.PartialSuccess, "downloadSettings", true, false, new(1, 1, 0), MutationErrorCategory.Permission), null,
                DownloadSettingsComponentState.Confirmed, DownloadSettingsComponentState.Rejected));
        _value = request.Desired;
        return Task.FromResult(new DownloadSettingsSaveOutcome(new(1, MutationResultStatus.ConfirmedSuccess, "downloadSettings", true, false, new(1, 0, 0)), request.Expected with { Value = _value },
            DownloadSettingsComponentState.Confirmed, _schedules.Count > 0 ? DownloadSettingsComponentState.Confirmed : DownloadSettingsComponentState.Unchanged));
    }
    public bool IsReadOnlyPath(string path) => false;
    public Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(string path, CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<FileCopyMoveFolder>>(state == "settings-empty-folders" ? [] :
        [new("/read-only", "Read-only sample", false), new("/writable", "Writable sample", true)]);
    public Task<DownloadTaskPage> ListTasksAsync(int offset, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<DownloadStationSnapshot> LoadSnapshotAsync(int offset, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<DownloadTaskControlOutcome> ControlTaskAsync(DownloadTaskControlRequest request, CancellationToken cancellationToken = default) => throw new NotSupportedException();
}

// 仅在合成宿主中提供设置能力，不改变生产 Repository 的危险写门。
public class SmokeNasServiceSettingsRepository : System.Reflection.DispatchProxy
{
    public string State { get; set; } = "terminal";
    public int Writes { get; private set; }
    public int ZramReads { get; private set; }
    private async Task<NasZramSnapshot> LoadZramAsync(CancellationToken token)
    {
        ZramReads++;
        if (State == "zram-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "zram-error") throw new IOException("合成内存压缩读取失败");
        if (State == "zram-unavailable") throw new DsmException("synthetic", "synthetic", 102);
        return State switch
        {
            "zram-empty" => new(null, null, NasZramAlgorithm.Unknown),
            "zram-disabled" => new(false, 0, NasZramAlgorithm.Unknown),
            "zram-partial" => new(null, 1_048_576, NasZramAlgorithm.Unknown),
            "zram-algorithm" => new(true, null, NasZramAlgorithm.Zstd),
            _ => new(true, 1_073_741_824, NasZramAlgorithm.Lz4)
        };
    }
    public int ExternalStorageReads { get; private set; }
    private async Task<NasExternalStorageDirectory> LoadExternalStorageAsync(CancellationToken token)
    {
        ExternalStorageReads++;
        if (State == "extstore-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "extstore-error") throw new IOException("合成外接存储读取失败");
        if (State == "extstore-unavailable") throw new DsmException("synthetic", "synthetic", 102);
        var partial = State is "extstore-partial" or "extstore-partial-empty" or "extstore-filtered-unavailable";
        NasExternalStorageDevice[] rows = State is "extstore-empty" or "extstore-partial-empty" ? [] :
            State == "extstore-unknown" ? [new("local", null, NasExternalStorageConnection.Usb, NasExternalStorageStatus.Unknown, null, null)] :
            partial || State == "extstore-filtered" ? [new("usb", "Synthetic USB", NasExternalStorageConnection.Usb, NasExternalStorageStatus.Ready, 1_000_000_000, 250_000_000)] :
            [new("usb", "Synthetic USB", NasExternalStorageConnection.Usb, NasExternalStorageStatus.Ready, 1_000_000_000, 250_000_000),
             new("esata", "Synthetic eSATA", NasExternalStorageConnection.Esata, NasExternalStorageStatus.Busy, 2_000_000_000, null)];
        return new(rows, State == "extstore-truncated" ? 200 : rows.Length, State == "extstore-truncated", 0,
            partial ? NasExternalStorageSources.Usb : NasExternalStorageSources.Usb | NasExternalStorageSources.Esata,
            partial ? NasExternalStorageSources.Esata : NasExternalStorageSources.None);
    }
    public int PowerScheduleReads { get; private set; }
    private async Task<NasPowerScheduleSnapshot> LoadPowerScheduleAsync(CancellationToken token)
    {
        PowerScheduleReads++;
        if (State == "powsched-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "powsched-error") throw new IOException("合成电源计划读取失败");
        if (State == "powsched-unavailable") throw new DsmException("synthetic", "synthetic", 102);
        NasPowerScheduleEntry[] entries = State == "powsched-empty" ? [] : State is "powsched-filtered" or "powsched-unknown" ?
            [new("synthetic", NasPowerScheduleAction.Unknown, null, 8, 30, NasPowerScheduleRecurrence.Unknown, null, [])] :
            [new("one", NasPowerScheduleAction.Startup, true, 8, 30, NasPowerScheduleRecurrence.Weekly, null, [DayOfWeek.Monday, DayOfWeek.Friday]),
             new("two", NasPowerScheduleAction.Shutdown, false, 23, 0, NasPowerScheduleRecurrence.Once, new DateOnly(2026, 12, 31), []),
             new("three", NasPowerScheduleAction.Restart, null, 12, 15, NasPowerScheduleRecurrence.Daily, null, [])];
        return new(entries, State == "powsched-unknown" ? null : "Asia/Shanghai", State == "powsched-partial" ? 200 : entries.Length,
            State == "powsched-partial", State == "powsched-partial" ? 2 : 0);
    }
    private NasRemoteAccessSettings? _remoteAccess;
    private bool _remotePending;
    public NasServiceSettingsSaveRequest<NasRemoteAccessSettings>? RemoteRequest { get; private set; }
    public bool RemoteCancelled { get; private set; }
    private async Task<NasRemoteAccessSettings> LoadRemoteAccessAsync(CancellationToken token)
    {
        if (State == "remote-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "remote-error" || State == "remote-save-read-error" && Writes > 0) throw new IOException("合成远程访问读取失败");
        if (State == "remote-empty") throw new DsmException("synthetic", "synthetic", 102);
        return _remoteAccess ??= State switch
        {
            "remote-partial-read" => new(null, false, true, NasRemoteAccessParts.Router, NasRemoteAccessParts.Relay),
            "remote-only-relay" => new(true, null, true, NasRemoteAccessParts.Relay),
            "remote-failed-fields" => new(null, null, true, NasRemoteAccessParts.None, NasRemoteAccessParts.Relay | NasRemoteAccessParts.Router),
            _ => new(true, false, !State.StartsWith("remote-relay", StringComparison.Ordinal), NasRemoteAccessParts.Relay | NasRemoteAccessParts.Router)
        };
    }
    private Task<MutationResult?> ReviewRemoteAccessAsync()
    {
        if (State == "remote-pending") _remotePending = true;
        if (State == "remote-recovered")
        {
            _remoteAccess = new(false, true, true, NasRemoteAccessParts.Relay | NasRemoteAccessParts.Router);
            return Task.FromResult<MutationResult?>(new(1, MutationResultStatus.ConfirmedSuccess, "saveRemoteAccess", true, false, new(2, 0, 0)));
        }
        return Task.FromResult<MutationResult?>(_remotePending ? new(1, MutationResultStatus.SubmittedButUnverified, "saveRemoteAccess", true, true, new(0, 0, 2)) : null);
    }
    private async Task<MutationResult> SaveRemoteAccessAsync(NasServiceSettingsSaveRequest<NasRemoteAccessSettings> request, CancellationToken token)
    {
        RemoteRequest = request; Writes++;
        if (State == "remote-close-busy")
        {
            try { await Task.Delay(Timeout.Infinite, token); }
            catch (OperationCanceledException) { RemoteCancelled = true; throw; }
        }
        var changes = (request.Baseline.RelayEnabled != request.Desired.RelayEnabled ? 1 : 0) +
            (request.Baseline.RouterConfigurationEnabled != request.Desired.RouterConfigurationEnabled ? 1 : 0);
        if (State == "remote-unknown") { _remotePending = true; return new(1, MutationResultStatus.SubmittedButUnverified, "saveRemoteAccess", true, true, new(0, 0, changes)); }
        if (State == "remote-rejected") return new(1, MutationResultStatus.PermissionDenied, "saveRemoteAccess", true, false, new(0, changes, 0), MutationErrorCategory.Permission);
        if (State == "remote-partial")
        {
            _remoteAccess = request.Baseline with { RelayEnabled = request.Desired.RelayEnabled };
            return new(1, MutationResultStatus.PartialSuccess, "saveRemoteAccess", true, true, new(1, 1, 0));
        }
        _remoteAccess = request.Desired;
        return new(1, MutationResultStatus.ConfirmedSuccess, "saveRemoteAccess", true, false, new(changes, 0, 0));
    }
    private NasDiskTestTarget DiskTarget => new("disk-a", "private-device", "Synthetic disk", State == "disk-unsupported" ? null : true);
    private NasDiskTestType? _diskRunningType;
    public NasDiskTestRequest? DiskRequest { get; private set; }
    public int DiskHistoryReads { get; private set; }
    public bool DiskCancelled { get; private set; }
    private async Task<IReadOnlyList<NasDiskTestTarget>> LoadDisksAsync(CancellationToken token)
    {
        if (State == "disk-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "disk-error") throw new IOException("合成硬盘列表失败");
        return State == "disk-empty" ? [] : [DiskTarget, new("disk-b", "private-other-device", "Second disk", true)];
    }
    private Task<NasDiskTestState> LoadDiskStateAsync(NasDiskTestTarget target)
    {
        if (State == "disk-state-error") return Task.FromException<NasDiskTestState>(new IOException("合成状态失败"));
        var type = DiskRequest is null && State == "disk-stop" ? NasDiskTestType.Extended : _diskRunningType;
        return Task.FromResult(new NasDiskTestState(target, type is not null, type,
            State == "disk-busy-unknown" ? null : State == "disk-busy", type is null ? null : "synthetic-progress", "synthetic-result"));
    }
    private async Task<MutationResult> ExecuteDiskAsync(NasDiskTestRequest request, CancellationToken token)
    {
        DiskRequest = request; Writes++;
        if (State == "disk-close-busy")
        {
            try { await Task.Delay(Timeout.Infinite, token); }
            catch (OperationCanceledException) { DiskCancelled = true; throw; }
        }
        if (State == "disk-unknown") return new(1, MutationResultStatus.SubmittedButUnverified, "diskTest", true, true, new(0, 0, 1));
        if (State == "disk-rejected") return new(1, MutationResultStatus.PermissionDenied, "diskTest", false, false, new(0, 1, 0), MutationErrorCategory.Permission);
        _diskRunningType = request.Command switch { NasDiskTestCommand.Quick => NasDiskTestType.Quick, NasDiskTestCommand.Extended => NasDiskTestType.Extended, _ => null };
        return new(1, MutationResultStatus.ConfirmedSuccess, "diskTest", true, false, new(1, 0, 0), diagnosticTag: request.Command == NasDiskTestCommand.Stop ? "disk.test.stopped" : "disk.test.running");
    }
    private NasTaskEntry _task = new(12, "synthetic-task", "runner", "owner", "script", null, true, "synthetic-next-run", true, true);
    private NasTaskDetail _taskDetail = new(12, "owner", "synthetic-task", "runner", "owner", true,
        new(0, "1,2,3,4,5", null, 1002, [], 3, 0, 0, 0, 3), "synthetic-script", false, "");
    private bool _taskDeleted;
    public NasTaskSaveRequest? TaskSave { get; private set; }
    public NasTaskCommandRequest? TaskCommand { get; private set; }
    public int TaskOutputReads { get; private set; }
    private Task<MutationResult> MutateTaskAsync()
    {
        Writes++;
        return Task.FromResult(State == "task-unknown"
            ? new MutationResult(1, MutationResultStatus.SubmittedButUnverified, "taskMutation", true, true, new(0, 0, 1))
            : State == "task-rejected" ? new(1, MutationResultStatus.PermissionDenied, "taskMutation", false, false, new(0, 1, 0), MutationErrorCategory.Permission)
            : new(1, MutationResultStatus.ConfirmedSuccess, "taskMutation", true, false, new(1, 0, 0), diagnosticTag: TaskCommand?.Command == NasTaskCommand.Run ? "task.run.accepted" : null));
    }
    private async Task<IReadOnlyList<NasTaskEntry>> LoadTasksAsync(CancellationToken token)
    {
        if (State == "task-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "task-error") throw new IOException("合成任务读取失败");
        return State == "task-empty" || _taskDeleted ? [] : [_task with { IsEnabled = State == "task-enable" ? false : _task.IsEnabled }];
    }
    private int _serviceReviewCalls;
    private int _fileServiceReads;
    private int _networkReads;
    private int _securityReads;
    private int _hardwareReads;
    private NasFileServiceSettings? _fileServiceSaved, _fileServiceLastRead;
    private NasRegionSettings? _regionSaved, _regionLastRead;
    private NasEthernetInterface? _networkSaved;
    private NasSecuritySettings? _securitySaved, _securityLastRead;
    private NasHardwareSettings? _hardwareSaved, _hardwareLastRead;
    private NasDDNSRecord? _ddnsSaved;
    private bool _ddnsDeleted;
    public NasDdnsMutationRequest? DdnsRequest { get; private set; }
    private List<NasPackageSummary>? _packages;
    private int _packageReviewCalls;
    public NasPackageMutationRequest? PackageRequest { get; private set; }
    public bool PackageWriteCancelled { get; private set; }
    private List<NasDirectoryEntry>? _directoryUsers, _directoryGroups;
    private int _directoryReviews;
    public NasDirectorySaveRequest? DirectorySave { get; private set; }
    public NasDirectoryDeleteRequest? DirectoryDelete { get; private set; }
    public string? DirectoryPassword { get; private set; }
    public bool DirectoryCancelled { get; private set; }
    private NasPowerRecoveryInfo? _powerRecovery;
    private bool _powerAcknowledged;
    public NasPowerRequest? PowerRequest { get; private set; }
    public int PowerAcknowledgements { get; private set; }
    public bool PowerCancelled { get; private set; }
    private List<NasConnectionEntry>? _connections;
    private int _connectionReviews;
    public NasConnectionDisconnectRequest? ConnectionRequest { get; private set; }
    public bool ConnectionCancelled { get; private set; }
    private bool _networkReviewed;
    public NasRegionSettingsSaveRequest? RegionRequest { get; private set; }
    private NasTerminalSettings _terminal = new(true, 22, false, null);
    private NasProxySettings _proxy = new(true, "proxy.example.invalid", 3128);
    protected override object? Invoke(System.Reflection.MethodInfo? method, object?[]? args)
    {
        var writable = !State.EndsWith("readonly", StringComparison.Ordinal);
        var fileWritable = State.StartsWith("file-save", StringComparison.Ordinal) || State is "file-invalid" or "file-pending";
        var regionWritable = State.StartsWith("region-save", StringComparison.Ordinal) || State is "region-invalid" or "region-manual-edit";
        var networkWritable = State.StartsWith("network-save", StringComparison.Ordinal) ||
            State is "network-invalid" or "network-edit-unknown" or "network-reconnect" or "network-fresh-login";
        var securityWritable = State.StartsWith("security-save", StringComparison.Ordinal) ||
            State is "security-invalid" or "security-pending" or "security-missing-profile";
        var hardwareWritable = State.StartsWith("hardware-save", StringComparison.Ordinal) || State is "hardware-invalid" or "hardware-pending" or "hardware-ups-edit";
        var ddnsWritable = State is "ddns-create" or "ddns-save" or "ddns-test" or "ddns-delete" or "ddns-update" or
            "ddns-unknown" or "ddns-rejected" or "ddns-invalid" or "ddns-late-change" or "ddns-pending";
        var packageWritable = State is "pkg-start" or "pkg-stop" or "pkg-uninstall" or "pkg-unknown" or "pkg-rejected" or
            "pkg-conflict" or "pkg-pending" or "pkg-recovered" or "pkg-changed-target" or "pkg-control-only" or "pkg-close-busy" or "pkg-missing-permission" or "pkg-search-change";
        var directoryWritable = State.StartsWith("dir-", StringComparison.Ordinal) && State is not ("dir-content" or "dir-group-content" or "dir-empty" or "dir-loading" or "dir-user-error" or "dir-filter");
        var powerWritable = State.StartsWith("power-", StringComparison.Ordinal) && State is not ("power-readonly" or "power-loading" or "power-load-error");
        var connectionWritable = State.StartsWith("conn-", StringComparison.Ordinal) && State is not ("conn-readonly" or "conn-empty" or "conn-loading" or "conn-error" or "conn-search");
        var diskWritable = State.StartsWith("disk-", StringComparison.Ordinal) && State != "disk-readonly";
        var remoteWritable = State.StartsWith("remote-", StringComparison.Ordinal) && State != "remote-readonly";
        switch (method?.Name)
        {
            case "get_ProfileId": return Guid.Parse("11111111-1111-1111-1111-111111111111");
            case "LoadZramAsync": return LoadZramAsync((CancellationToken)args![0]!);
            case "LoadExternalStorageAsync": return LoadExternalStorageAsync((CancellationToken)args![0]!);
            case "LoadPowerScheduleAsync": return LoadPowerScheduleAsync((CancellationToken)args![0]!);
            case "LoadRemoteAccessSettingsAsync": return LoadRemoteAccessAsync((CancellationToken)args![0]!);
            case "SaveRemoteAccessSettingsAsync": return SaveRemoteAccessAsync((NasServiceSettingsSaveRequest<NasRemoteAccessSettings>)args![0]!, (CancellationToken)args[1]!);
            case "LoadDiskTestTargetsAsync": return LoadDisksAsync((CancellationToken)args![0]!);
            case "LoadDiskTestStateAsync": return LoadDiskStateAsync((NasDiskTestTarget)args![0]!);
            case "GetDiskTestRecoveriesAsync": return Task.FromResult<IReadOnlyList<NasDiskTestRecovery>>(State == "disk-unknown" && Writes > 0 ? [new(DiskTarget, NasDiskTestCommand.Quick)] : []);
            case "ReviewDiskTestAsync": return Task.FromResult<MutationResult?>(new(1, MutationResultStatus.SubmittedButUnverified, "diskTest", true, true, new(0, 0, 1)));
            case "ExecuteDiskTestAsync": return ExecuteDiskAsync((NasDiskTestRequest)args![0]!, (CancellationToken)args[1]!);
            case "LoadDiskTestHistoryAsync":
                DiskHistoryReads++;
                return State == "disk-history-error" ? Task.FromException<NasDiskTestHistory>(new IOException("合成历史失败")) :
                    Task.FromResult(new NasDiskTestHistory(State == "disk-history-empty" ? [] : [new(NasDiskTestType.Quick, "synthetic-time", "synthetic-result")], State == "disk-history-partial"));
            case "get_CanSaveScheduledTasks": return State != "task-readonly";
            case "get_TaskCommandAvailability": return new NasTaskCommandAvailability(State != "task-readonly", State != "task-readonly", State != "task-readonly");
            case "GetTaskRecoveriesAsync": return Task.FromResult<IReadOnlyList<NasTaskRecoveryInfo>>(State == "task-unknown" && Writes > 0 ? [new(12, _task.Name, _task.RealOwner, NasTaskCommand.Run)] : []);
            case "GetTaskSaveRecoveriesAsync": return Task.FromResult<IReadOnlyList<NasTaskSaveRecoveryInfo>>([]);
            case "ReviewTaskCommandAsync": return Task.FromResult<MutationResult?>(new(1, MutationResultStatus.SubmittedButUnverified, "taskMutation", true, true, new(0, 0, 1)));
            case "LoadScheduledTasksAsync": return LoadTasksAsync((CancellationToken)args![0]!);
            case "LoadScheduledTaskDetailAsync": return State == "task-detail-error" ? Task.FromException<NasTaskDetail>(new IOException("合成详情失败")) :
                Task.FromResult(args![0] is null ? _taskDetail with { Id = null, Name = "", Script = "" } : _taskDetail);
            case "LoadScheduledTaskResultsAsync": return Task.FromResult<IReadOnlyList<NasTaskResult>>(State == "task-no-history" ? [] : [new("result", _task.Name, "synthetic-start", "synthetic-stop", "normal", 0, null)]);
            case "LoadScheduledTaskOutputAsync": TaskOutputReads++; return Task.FromResult(new NasTaskResultOutput("synthetic-command", "synthetic-output"));
            case "SaveScheduledTaskAsync":
                TaskSave = (NasTaskSaveRequest)args![0]!; _taskDetail = TaskSave.Desired with { Id = 12 }; _task = _task with { Name = _taskDetail.Name!, Owner = _taskDetail.Owner };
                return MutateTaskAsync();
            case "ExecuteTaskCommandAsync":
                TaskCommand = (NasTaskCommandRequest)args![0]!;
                if (TaskCommand.Command == NasTaskCommand.Delete) _taskDeleted = true;
                if (TaskCommand.Command is NasTaskCommand.Enable or NasTaskCommand.Disable) _task = _task with { IsEnabled = TaskCommand.Command == NasTaskCommand.Enable };
                return MutateTaskAsync();
            case "LoadConnectionSnapshotAsync": return LoadConnectionsAsync((CancellationToken)args![0]!);
            case "GetConnectionRecoveriesAsync": return Task.FromResult<IReadOnlyList<NasConnectionRecoveryInfo>>(
                State == "conn-pending" || State == "conn-unknown" && Writes > 0 || State == "conn-recovered" && _connectionReviews == 0
                    ? [new("web-key", "synthetic-account", "synthetic-source", "HTTPS")] : []);
            case "ReviewConnectionAsync":
                _connectionReviews++;
                return Task.FromResult<MutationResult?>(State == "conn-recovered" ? new(1, MutationResultStatus.ConfirmedSuccess, "disconnectConnection", true, false, new(1, 0, 0)) :
                    new(1, MutationResultStatus.SubmittedButUnverified, "disconnectConnection", true, true, new(0, 0, 1)));
            case "DisconnectConnectionAsync" when args![0] is NasConnectionDisconnectRequest connectionRequest:
                return DisconnectConnectionAsync(connectionRequest, (CancellationToken)args[1]!);
            case "GetPowerRecoveryAsync": return GetPowerRecoveryAsync((CancellationToken)args![0]!);
            case "AcknowledgePowerRecoveryAsync":
                if (args![0] is not true || State != "power-fresh") return Task.FromResult(false);
                PowerAcknowledgements++; _powerAcknowledged = true; _powerRecovery = null; return Task.FromResult(true);
            case "ExecutePowerActionAsync" when args![0] is NasPowerRequest powerRequest: return ExecutePowerAsync(powerRequest, (CancellationToken)args[1]!);
            case "get_DirectorySaveAvailability": return new NasDirectorySaveAvailability(directoryWritable, directoryWritable);
            case "GetDirectoryRecoveriesAsync": return Task.FromResult<IReadOnlyList<NasDirectoryRecoveryInfo>>(
                State == "dir-pending" || State == "dir-unknown" && Writes > 0
                    ? [new(NasDirectoryKind.User, "synthetic-account", State == "dir-unknown" ? NasDirectoryOperationKind.Update : NasDirectoryOperationKind.Delete)]
                    : State == "dir-recovered" && _directoryReviews == 0 ? [new(NasDirectoryKind.Group, "removed-group")] : []);
            case "ReviewDirectoryEntryAsync":
                _directoryReviews++;
                return Task.FromResult<MutationResult?>(State == "dir-recovered" ? new(1, MutationResultStatus.ConfirmedSuccess, "deleteDirectoryEntry", true, false, new(1, 0, 0)) :
                    new(1, MutationResultStatus.SubmittedButUnverified, "saveDirectoryEntry", true, true, new(0, 0, 1), diagnosticTag: "directory.save.credentials-unverified"));
            case "LoadDirectoryAsync": return LoadDirectoryAsync((NasDirectoryKind)args![0]!, (CancellationToken)args[1]!);
            case "SaveDirectoryEntryAsync":
                DirectorySave = (NasDirectorySaveRequest)args![0]!; DirectoryPassword = (string?)args[1];
                return MutateDirectoryAsync(DirectorySave.Kind, DirectorySave.Desired.Name, false, (CancellationToken)args[3]!);
            case "DeleteDirectoryEntryAsync":
                DirectoryDelete = (NasDirectoryDeleteRequest)args![0]!;
                return MutateDirectoryAsync(DirectoryDelete.Baseline.Kind, DirectoryDelete.Baseline.Name, true, (CancellationToken)args[1]!);
            case "get_PackageControlAvailability": return new NasPackageControlAvailability(packageWritable, packageWritable && State != "pkg-control-only");
            case "GetPackageRecoveriesAsync": return Task.FromResult<IReadOnlyList<NasPackageRecoveryInfo>>(
                State == "pkg-pending" || State == "pkg-unknown" && Writes > 0 || State == "pkg-recovered" && _packageReviewCalls == 0
                    ? [new("synthetic-package", "Synthetic Package", State == "pkg-recovered" ? NasPackageAction.Uninstall : NasPackageAction.Start)] : []);
            case "ReviewPackageAsync":
                _packageReviewCalls++;
                return Task.FromResult<MutationResult?>(State == "pkg-recovered"
                    ? new(1, MutationResultStatus.ConfirmedSuccess, "uninstallPackage", true, false, new(1, 0, 0))
                    : new(1, MutationResultStatus.SubmittedButUnverified, "controlPackage", true, true, new(0, 0, 1)));
            case "LoadPackagesAsync": return LoadPackagesAsync((CancellationToken)args![0]!);
            case "ControlPackageAsync" when args![0] is NasPackageMutationRequest packageRequest:
                return ControlPackageAsync(packageRequest, (CancellationToken)args[1]!);
            case "get_WriteAvailability": return new NasSettingsWriteAvailability(
                ddnsWritable, fileWritable, writable, writable, networkWritable, regionWritable, securityWritable, hardwareWritable, false, false,
                false, false, false, false, powerWritable, packageWritable, directoryWritable, directoryWritable, connectionWritable, diskWritable) { CanSaveRemoteAccess = remoteWritable };
            case "PrepareServiceSettingsAsync": return Task.FromResult(new NasSettingsWriteAvailability(
                ddnsWritable, fileWritable, writable, writable, networkWritable, regionWritable, securityWritable, hardwareWritable, false, false,
                false, false, false, false, powerWritable, packageWritable, directoryWritable, directoryWritable, connectionWritable, diskWritable) { CanSaveRemoteAccess = remoteWritable });
            case "ReviewServiceSettingsAsync":
                if (args![0] is NasServiceSettingsKind.RemoteAccess) return ReviewRemoteAccessAsync();
                _serviceReviewCalls++;
                if (State == "ddns-pending" || State == "ddns-unknown" && Writes > 0) return Task.FromResult<MutationResult?>(new(1,
                    MutationResultStatus.SubmittedButUnverified, "ddnsMutation", true, true, new(0, 0, 1)));
                if (State == "hardware-pending") return Task.FromResult<MutationResult?>(new(1,
                    MutationResultStatus.SubmittedButUnverified, "saveHardware", true, true, new(0, 0, 1)));
                if (State == "security-pending") return Task.FromResult<MutationResult?>(new(1,
                    MutationResultStatus.SubmittedButUnverified, "saveSecurity", true, true, new(0, 0, 1)));
                if (State == "file-pending") return Task.FromResult<MutationResult?>(new(1,
                    MutationResultStatus.SubmittedButUnverified, "saveFileService", true, true, new(0, 0, 1)));
                if (State is "terminal-pending" or "terminal-recovered")
                {
                    var unknown = State == "terminal-pending" || _serviceReviewCalls == 1;
                    if (!unknown) _terminal = _terminal with { SshPort = 2222 };
                    return Task.FromResult<MutationResult?>(new(1,
                        unknown ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess,
                        "saveTerminal", true, unknown, unknown ? new(0, 0, 1) : new(1, 0, 0)));
                }
                return Task.FromResult<MutationResult?>(null);
            case "LoadDDNSProvidersAsync": return LoadDdnsProvidersAsync((CancellationToken)args![0]!);
            case "LoadDDNSRecordsAsync": return Task.FromResult<IReadOnlyList<NasDDNSRecord>>(_ddnsDeleted ? [] : _ddnsSaved is not null ? [_ddnsSaved] : State is "ddns-empty" or "ddns-create" ? [] :
                [new NasDDNSRecord("Example", "Example", "nas.example.invalid", "synthetic", State == "ddns-no-address" ? null : "192.0.2.10", "normal", true, true)
                    { Ipv6 = State == "ddns-no-address" ? null : "2001:db8::1" }]);
            case "MutateDdnsAsync":
                DdnsRequest = (NasDdnsMutationRequest)args![0]!; Writes++;
                if (!DdnsRequest.RiskConfirmed || DdnsRequest.RequestId == Guid.Empty) throw new InvalidOperationException("DDNS 未绑定确认快照。");
                if (State == "ddns-unknown") return Task.FromResult(new MutationResult(1, MutationResultStatus.SubmittedButUnverified, "ddnsMutation", true, true, new(0, 0, 1)));
                if (State == "ddns-rejected") return Task.FromResult(new MutationResult(1, MutationResultStatus.PermissionDenied, "ddnsMutation", true, false, new(0, 1, 0), MutationErrorCategory.Permission));
                if (DdnsRequest.Action == NasDdnsAction.Save) _ddnsSaved = DdnsRequest.Desired;
                if (DdnsRequest.Action == NasDdnsAction.Delete) _ddnsDeleted = true;
                return Task.FromResult(new MutationResult(1, MutationResultStatus.ConfirmedSuccess, "ddnsMutation", true, false, new(1, 0, 0)));
            case "LoadTerminalSettingsAsync": return LoadTerminalAsync((CancellationToken)args![0]!);
            case "LoadProxySettingsAsync": return State == "proxy-error"
                ? Task.FromException<NasProxySettings>(new IOException("合成读取失败")) : Task.FromResult(_proxy);
            case "LoadFileServiceSettingsAsync": return LoadFileServicesAsync((CancellationToken)args![0]!);
            case "LoadRegionSettingsAsync": return LoadRegionAsync((CancellationToken)args![0]!);
            case "LoadEthernetSnapshotAsync": return LoadNetworkAsync((CancellationToken)args![0]!);
            case "LoadSecuritySettingsAsync": return LoadSecurityAsync((CancellationToken)args![0]!);
            case "LoadHardwareSettingsAsync": return LoadHardwareAsync((CancellationToken)args![0]!);
            case "GetEthernetRecoveryAsync": return Task.FromResult<NasEthernetRecoveryInfo?>(_networkReviewed ? null :
                State == "network-fresh-login" ? new("eth0", true, true) :
                State == "network-reconnect" ? new("eth0", false, true) :
                State == "network-save-unknown" && Writes > 0 ? new("eth0", false, false) : null);
            case "ReviewEthernetSettingsAsync":
                if (State == "network-reconnect" && args![0] is not true) throw new InvalidOperationException("新地址未确认即核对。");
                _networkReviewed = true;
                return Task.FromResult<MutationResult?>(new(1, MutationResultStatus.ConfirmedSuccess, "saveNetwork", true, false, new(1, 0, 0)));
            case "SaveEthernetSettingsAsync":
                var networkRequest = (NasServiceSettingsSaveRequest<NasEthernetInterface>)args![0]!;
                if (!networkRequest.RiskConfirmed || networkRequest.RequestId == Guid.Empty ||
                    networkRequest.Baseline.Id != networkRequest.Desired.Id || !NasEthernetSettingsRules.IsValid(networkRequest.Desired))
                    throw new InvalidOperationException("网卡保存缺少确认/有效目标。");
                _networkSaved = networkRequest.Desired; Writes++;
                var networkUnknown = State == "network-save-unknown";
                return Task.FromResult(new MutationResult(1, networkUnknown ? MutationResultStatus.SubmittedButUnverified :
                    MutationResultStatus.ConfirmedSuccess, "saveNetwork", true, networkUnknown, networkUnknown ? new(0, 0, 1) : new(1, 0, 0)));
            case "SaveTerminalSettingsAsync":
                var terminalRequest = (NasServiceSettingsSaveRequest<NasTerminalSettings>)args![0]!;
                if (!terminalRequest.RiskConfirmed || terminalRequest.Baseline != _terminal || terminalRequest.RequestId == Guid.Empty)
                    throw new InvalidOperationException("终端保存缺少确认或原值绑定。");
                _terminal = terminalRequest.Desired;
                return SavedAsync();
            case "SaveProxySettingsAsync":
                var proxyRequest = (NasServiceSettingsSaveRequest<NasProxySettings>)args![0]!;
                if (!proxyRequest.RiskConfirmed || proxyRequest.Baseline != _proxy || proxyRequest.RequestId == Guid.Empty)
                    throw new InvalidOperationException("代理保存缺少确认或原值绑定。");
                _proxy = proxyRequest.Desired;
                return SavedAsync();
            case "SaveFileServiceSettingsAsync":
                var fileRequest = (NasServiceSettingsSaveRequest<NasFileServiceSettings>)args![0]!;
                if (!fileRequest.RiskConfirmed || fileRequest.Baseline != _fileServiceLastRead ||
                    fileRequest.RequestId == Guid.Empty || !NasFileServiceSettingsRules.IsValidChange(fileRequest.Baseline, fileRequest.Desired))
                    throw new InvalidOperationException("文件服务缺少有效基线/确认。");
                _fileServiceSaved = fileRequest.Desired;
                Writes++;
                var unknownFile = State == "file-save-review";
                var partialFile = State == "file-save-partial";
                if (partialFile) _fileServiceSaved = _fileServiceSaved with { SftpPort = fileRequest.Baseline.SftpPort };
                return Task.FromResult(new MutationResult(1, unknownFile ? MutationResultStatus.SubmittedButUnverified :
                    partialFile ? MutationResultStatus.PartialSuccess : MutationResultStatus.ConfirmedSuccess,
                    "saveFileService", true, unknownFile || partialFile,
                    unknownFile ? new(0, 0, 1) : partialFile ? new(1, 1, 0) : new(1, 0, 0)));
            case "SaveRegionSettingsAsync":
                RegionRequest = (NasRegionSettingsSaveRequest)args![0]!;
                var previousRegion = _regionLastRead;
                if (previousRegion is null || !RegionRequest.RiskConfirmed || RegionRequest.RequestId == Guid.Empty ||
                    !NasRegionSettingsRules.IsValid(RegionRequest.Desired, RegionRequest.EditedNasTime) ||
                    RegionRequest.Baseline.Timezone != previousRegion.Timezone ||
                    !RegionRequest.Baseline.NtpServers.SequenceEqual(previousRegion.NtpServers))
                    throw new InvalidOperationException("区域保存缺少有效确认/基线。");
                _regionSaved = RegionRequest.Desired with { NasLocalTime = RegionRequest.EditedNasTime ?? previousRegion.NasLocalTime };
                Writes++;
                var syncFailed = State == "region-save-sync-failed";
                var unverified = State == "region-save-unverified";
                return Task.FromResult(new MutationResult(1, unverified ? MutationResultStatus.SubmittedButUnverified :
                    syncFailed ? MutationResultStatus.PartialSuccess : MutationResultStatus.ConfirmedSuccess,
                    "saveRegion", true, syncFailed || unverified, unverified ? new(0, 0, 1) : syncFailed ? new(1, 0, 1) : new(1, 0, 0),
                    diagnosticTag: syncFailed ? "region.sync.unverified" : State == "region-save-sync" ? "region.sync.accepted" : null));
            case "SaveSecuritySettingsAsync":
                var securityRequest = (NasServiceSettingsSaveRequest<NasSecuritySettings>)args![0]!;
                if (!securityRequest.RiskConfirmed || securityRequest.RequestId == Guid.Empty ||
                    !NasSecuritySettingsRules.IsValidChange(securityRequest.Baseline, securityRequest.Desired) ||
                    securityRequest.Baseline.AutoBlockFailedAttempts != _securityLastRead?.AutoBlockFailedAttempts)
                    throw new InvalidOperationException("安全保存缺少有效基线/确认。");
                _securitySaved = securityRequest.Desired; Writes++;
                var securityPartial = State == "security-save-partial";
                var securityUnknown = State == "security-save-unknown";
                if (securityPartial) _securitySaved = _securitySaved with { PortScanEnabled = _securityLastRead!.PortScanEnabled };
                return Task.FromResult(new MutationResult(1, securityUnknown ? MutationResultStatus.SubmittedButUnverified :
                    securityPartial ? MutationResultStatus.PartialSuccess : MutationResultStatus.ConfirmedSuccess,
                    "saveSecurity", true, securityUnknown || securityPartial,
                    securityUnknown ? new(0, 0, 1) : securityPartial ? new(1, 1, 0) : new(1, 0, 0)));
            case "SaveHardwareSettingsAsync":
                var hardwareRequest = (NasServiceSettingsSaveRequest<NasHardwareSettings>)args![0]!;
                if (!hardwareRequest.RiskConfirmed || hardwareRequest.RequestId == Guid.Empty ||
                    !NasHardwareSettingsRules.IsValidChange(hardwareRequest.Baseline, hardwareRequest.Desired) ||
                    hardwareRequest.Baseline.LedBrightness != _hardwareLastRead?.LedBrightness)
                    throw new InvalidOperationException("硬件保存缺少基线/确认。");
                _hardwareSaved = hardwareRequest.Desired; Writes++;
                var hardwarePartial = State == "hardware-save-partial"; var hardwareUnknown = State == "hardware-save-unknown";
                if (hardwarePartial) _hardwareSaved = _hardwareSaved with { LedBrightness = _hardwareLastRead!.LedBrightness };
                return Task.FromResult(new MutationResult(1, hardwareUnknown ? MutationResultStatus.SubmittedButUnverified :
                    hardwarePartial ? MutationResultStatus.PartialSuccess : MutationResultStatus.ConfirmedSuccess,
                    "saveHardware", true, hardwareUnknown || hardwarePartial,
                    hardwareUnknown ? new(0, 0, 1) : hardwarePartial ? new(1, 1, 0) : new(1, 0, 0)));
            default: throw new NotSupportedException();
        }
    }
    private async Task<NasTerminalSettings> LoadTerminalAsync(CancellationToken token)
    {
        if (State == "terminal-loading") await Task.Delay(Timeout.Infinite, token);
        return State == "terminal-no-port" ? _terminal with { SshPort = null } : _terminal;
    }
    private async Task<NasConnectionSnapshot> LoadConnectionsAsync(CancellationToken token)
    {
        if (State == "conn-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "conn-error") throw new IOException("合成连接读取失败");
        if (_connections is null)
        {
            var service = State == "conn-service";
            var entry = new NasConnectionEntry("synthetic-connection", "private-process", service || State == "conn-missing" ? null : "private-device",
                "synthetic-account", "synthetic-source", service ? "SMB" : "HTTP/HTTPS", "Synthetic service", service ? "SMB" : "HTTPS", "Synthetic location",
                "2026-09-17 10:00:00", State == "conn-unknown-current" ? null : State is "conn-current" or "conn-current-reversed", true)
            { TargetKey = service ? "service-key" : "web-key", IdentityKeys = service ? ["service-key"] : ["web-key"], IsAmbiguous = State == "conn-ambiguous" };
            _connections = State is "conn-empty" or "conn-recovered" ? [] : [entry];
            if (State == "conn-switch-target") _connections.Add(entry with { Id = "other-connection", DeviceId = "private-other-device", Account = "second-account", TargetKey = "other-key", IdentityKeys = ["other-key"] });
        }
        return new(_connections.ToArray(), State == "conn-partial" ? 600 : _connections.Count, State != "conn-partial");
    }
    private async Task<MutationResult> DisconnectConnectionAsync(NasConnectionDisconnectRequest request, CancellationToken token)
    {
        Writes++; ConnectionRequest = request;
        if (!request.RiskConfirmed || request.RequestId == Guid.Empty || request.Baseline.RequiresCurrentSessionConfirmation && !request.CurrentSessionConfirmed)
            throw new InvalidOperationException("连接断开缺少必要确认。");
        if (State == "conn-close-busy")
        {
            try { await Task.Delay(Timeout.Infinite, token); }
            finally { ConnectionCancelled = token.IsCancellationRequested; }
        }
        if (State == "conn-unknown") return new(1, MutationResultStatus.SubmittedButUnverified, "disconnectConnection", true, true, new(0, 0, 1));
        if (State == "conn-rejected") return new(1, MutationResultStatus.PermissionDenied, "disconnectConnection", true, false, new(0, 1, 0), MutationErrorCategory.Permission);
        if (State == "conn-conflict") return new(1, MutationResultStatus.ConfirmedFailure, "disconnectConnection", false, true, new(0, 1, 0), MutationErrorCategory.Conflict);
        _connections!.RemoveAll(item => item.Id == request.Baseline.Id);
        return new(1, MutationResultStatus.ConfirmedSuccess, "disconnectConnection", true, false, new(1, 0, 0));
    }

    private async Task<NasPowerRecoveryInfo?> GetPowerRecoveryAsync(CancellationToken token)
    {
        if (State == "power-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "power-load-error") throw new IOException("合成电源核对失败");
        if (!_powerAcknowledged && State is "power-pending" or "power-fresh")
            return new(NasPowerAction.Reboot, new(1, MutationResultStatus.SubmittedButUnverified, "reboot", true, true, new(0, 0, 1)), State == "power-fresh");
        return _powerRecovery;
    }
    private async Task<MutationResult> ExecutePowerAsync(NasPowerRequest request, CancellationToken token)
    {
        Writes++; PowerRequest = request;
        if (!request.RiskConfirmed || request.RequestId == Guid.Empty) throw new InvalidOperationException("电源操作未绑定确认。");
        if (State == "power-close-busy")
        {
            try { await Task.Delay(Timeout.Infinite, token); }
            finally { PowerCancelled = token.IsCancellationRequested; }
        }
        if (State == "power-rejected") return new(1, MutationResultStatus.PermissionDenied, "powerAction", true, false, new(0, 1, 0), MutationErrorCategory.Permission);
        var unknown = State == "power-unknown";
        var result = new MutationResult(1, unknown ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess,
            "powerAction", true, unknown, unknown ? new(0, 0, 1) : new(1, 0, 0));
        _powerRecovery = new(request.Action, result, false); return result;
    }

    private async Task<IReadOnlyList<NasDirectoryEntry>> LoadDirectoryAsync(NasDirectoryKind kind, CancellationToken token)
    {
        if (kind == NasDirectoryKind.User && State == "dir-loading") await Task.Delay(Timeout.Infinite, token);
        if (kind == NasDirectoryKind.User && State == "dir-user-error" || kind == NasDirectoryKind.Group && State == "dir-group-error") throw new IOException("合成目录读取失败");
        _directoryUsers ??= State == "dir-empty" ? [] : [new(NasDirectoryKind.User, "synthetic-account", 100, "Synthetic account", State == "dir-missing-fields" ? null : "synthetic@example.invalid",
            State == "dir-missing-fields" ? null : false, new[] { "synthetic-group" }, true, true) { IsCurrentAccount = State == "dir-current" }];
        _directoryGroups ??= State == "dir-recovered" ? [] : [new(NasDirectoryKind.Group, "synthetic-group", 101, "Synthetic group", null, null, null, true, true),
            new(NasDirectoryKind.Group, "second-group", 102, "Second group", null, null, null, true, true)];
        return (kind == NasDirectoryKind.User ? _directoryUsers : _directoryGroups).ToArray();
    }
    private async Task<MutationResult> MutateDirectoryAsync(NasDirectoryKind kind, string name, bool delete, CancellationToken token)
    {
        Writes++;
        if (delete ? DirectoryDelete?.RiskConfirmed != true : DirectorySave?.RiskConfirmed != true) throw new InvalidOperationException("目录操作缺少确认。");
        if (State == "dir-close-busy")
        {
            try { await Task.Delay(Timeout.Infinite, token); }
            finally { DirectoryCancelled = token.IsCancellationRequested; }
        }
        if (State == "dir-unknown") return new(1, MutationResultStatus.SubmittedButUnverified, "saveDirectoryEntry", true, true, new(0, 0, 1), diagnosticTag: "directory.save.credentials-unverified");
        if (State == "dir-rejected") return new(1, MutationResultStatus.PermissionDenied, "saveDirectoryEntry", true, false, new(0, 1, 0), MutationErrorCategory.Permission);
        if (State == "dir-conflict") return new(1, MutationResultStatus.ConfirmedFailure, "saveDirectoryEntry", false, true, new(0, 1, 0), MutationErrorCategory.Conflict);
        var entries = kind == NasDirectoryKind.User ? _directoryUsers! : _directoryGroups!;
        var original = entries.FirstOrDefault(item => item.Name == name); entries.RemoveAll(item => item.Name == name);
        if (!delete)
        {
            var value = DirectorySave!.Desired;
            entries.Add(new(kind, name, original?.NumericId ?? 103, value.Description, value.Email, value.IsExpired, value.Groups ?? original?.Groups, true, true));
        }
        return new(1, MutationResultStatus.ConfirmedSuccess, "directoryMutation", true, false, new(1, 0, 0));
    }

    private async Task<IReadOnlyList<NasPackageSummary>> LoadPackagesAsync(CancellationToken token)
    {
        if (State == "pkg-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "pkg-error") throw new IOException("合成套件读取失败");
        if (_packages is null)
        {
            var running = State == "pkg-stop";
            var package = new NasPackageSummary("synthetic-package", "Synthetic Package", "1.0", running ? "running" : "stopped", running ? ResourceState.Running : ResourceState.Stopped)
            {
                Startable = State == "pkg-missing-permission" ? null : true, InstallType = State == "pkg-missing-permission" ? null : "user",
                UninstallAllowed = State == "pkg-missing-permission" ? null : true, DesktopApps = [],
                AvailableOperations = State == "pkg-missing-permission" ? null : new[] { "start", "stop", "uninstall", "upgrade" },
            };
            _packages = State is "pkg-empty" or "pkg-recovered" ? [] : [package];
            if (State == "pkg-changed-target") _packages.Add(package with { Id = "second-package", Name = "Second Package" });
        }
        return _packages.ToArray();
    }
    private async Task<MutationResult> ControlPackageAsync(NasPackageMutationRequest request, CancellationToken token)
    {
        Writes++; PackageRequest = request;
        if (!request.RiskConfirmed || request.RequestId == Guid.Empty) throw new InvalidOperationException("套件操作缺失确认。");
        if (State == "pkg-close-busy")
        {
            try { await Task.Delay(Timeout.Infinite, token); }
            finally { PackageWriteCancelled = token.IsCancellationRequested; }
        }
        if (State == "pkg-unknown") return new(1, MutationResultStatus.SubmittedButUnverified, "controlPackage", true, true, new(0, 0, 1));
        if (State == "pkg-rejected") return new(1, MutationResultStatus.PermissionDenied, "controlPackage", true, false, new(0, 1, 0), MutationErrorCategory.Permission);
        if (State == "pkg-conflict") return new(1, MutationResultStatus.ConfirmedFailure, "controlPackage", false, true, new(0, 1, 0), MutationErrorCategory.Conflict);
        _packages!.RemoveAll(item => item.Id == request.Baseline.Id);
        if (request.Action != NasPackageAction.Uninstall) _packages.Add(request.Baseline with
        { Status = request.Action == NasPackageAction.Start ? "running" : "stopped", State = request.Action == NasPackageAction.Start ? ResourceState.Running : ResourceState.Stopped });
        return new(1, MutationResultStatus.ConfirmedSuccess, "controlPackage", true, false, new(1, 0, 0));
    }

    private async Task<IReadOnlyList<NasDDNSProvider>> LoadDdnsProvidersAsync(CancellationToken token)
    {
        if (!State.StartsWith("ddns-", StringComparison.Ordinal)) return [];
        if (State == "ddns-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "ddns-error") throw new IOException("合成 DDNS 读取失败");
        if (State == "ddns-unavailable") throw new DsmException("synthetic", "synthetic", 102);
        return [new("Example", "Synthetic provider", null)];
    }
    private async Task<NasHardwareSettings> LoadHardwareAsync(CancellationToken token)
    {
        if (_hardwareSaved is not null) return _hardwareLastRead = _hardwareSaved;
        _hardwareReads++;
        if (State == "hardware-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "hardware-error") throw new IOException("合成硬件读取失败");
        if (State == "hardware-unavailable") throw new DsmException("synthetic", "synthetic", 102);
        if (State == "hardware-empty") return new(null, null, null, null, null, null, null, null);
        var partial = State == "hardware-partial" || State == "hardware-recovered" && _hardwareReads == 1;
        return _hardwareLastRead = new(true, 5, partial ? null : "coolfan", null, null, true, "SLAVE", "120")
        {
            LedMinimum = 0, LedMaximum = 10,
            AvailableSections = partial ? (NasHardwareSections)59 : (NasHardwareSections)63,
            FailedSections = partial ? NasHardwareSections.Fan : NasHardwareSections.None,
            Beep = new(true, true, false, false, true, "volume_crash"),
            Hibernation = new(true, false, true, true, false),
            Ups = new(State != "hardware-ups-edit", "SLAVE", 120, false, true, State is "hardware-ups-empty" or "hardware-ups-edit" ? "" : "192.0.2.50", null),
        };
    }
    private async Task<NasSecuritySettings> LoadSecurityAsync(CancellationToken token)
    {
        if (_securitySaved is not null) return _securityLastRead = _securitySaved;
        _securityReads++;
        if (State == "security-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "security-error") throw new IOException("合成安全设置读取失败");
        if (State == "security-unavailable") throw new DsmException("synthetic", "synthetic", 102);
        if (State == "security-empty") return new(null, null, null, null, null, null, null);
        var partial = State == "security-partial" || State == "security-recovered" && _securityReads == 1;
        return _securityLastRead = new(true, 5, 10, State == "security-no-expiry" ? 0 : 7, null,
            partial ? null : State == "security-missing-profile" ? false : true, true)
        {
            AvailableSections = partial ? NasSecuritySections.AutoBlock | NasSecuritySections.Dos | NasSecuritySections.PortScan : (NasSecuritySections)15,
            FailedSections = partial ? NasSecuritySections.Firewall : NasSecuritySections.None,
            FirewallProfileName = partial || State == "security-missing-profile" ? null : "Synthetic profile",
            DosProtection = [new("eth0", "Synthetic LAN", true), new("bond0", "Synthetic bond", false)],
        };
    }
    private async Task<NasEthernetSnapshot> LoadNetworkAsync(CancellationToken token)
    {
        _networkReads++;
        if (State == "network-fresh-login") throw new InvalidOperationException("旧会话被用于新地址读取。");
        if (_networkSaved is not null) return new([_networkSaved], 0);
        if (State == "network-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "network-error") throw new IOException("合成网络读取失败");
        if (State == "network-unavailable") throw new DsmException("synthetic", "synthetic", 102);
        if (State == "network-empty") return new([], 0);
        if (State is "network-unknown" or "network-edit-unknown") return new([new("eth0", "Synthetic LAN", true, null, null, null, [], null, null)], 0);
        var partial = State == "network-partial" || State == "network-recovered" && _networkReads == 1;
        return new([new("eth0", "Synthetic LAN", false, "192.0.2.10", "255.255.255.0", "192.0.2.1",
            ["192.0.2.53"], 1500, 10) { IsDefaultGateway = true, VlanEnabled = true, ReportedDns = "192.0.2.53" }], partial ? 1 : 0);
    }

    private async Task<NasRegionSettings> LoadRegionAsync(CancellationToken token)
    {
        if (_regionSaved is not null) return _regionLastRead = _regionSaved;
        if (State == "region-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "region-error") throw new IOException("合成读取失败");
        if (State == "region-unavailable") throw new DsmException("synthetic", "synthetic", 102);
        return _regionLastRead = new("Y-m-d", "H:i", "UTC", ["time.example.invalid"], "2026/7/26")
        {
            Mode = State == "region-unknown" ? NasRegionTimeMode.Unknown :
                State is "region-manual" or "region-manual-edit" ? NasRegionTimeMode.Manual : NasRegionTimeMode.Network,
            NasLocalTime = State == "region-no-clock" ? null : new DateTime(2026, 7, 26, 18, 30, 10, DateTimeKind.Unspecified),
            TimeZones = [new("UTC", "UTC")],
        };
    }

    private async Task<NasFileServiceSettings> LoadFileServicesAsync(CancellationToken token)
    {
        _fileServiceReads++;
        if (_fileServiceSaved is not null) return _fileServiceLastRead = _fileServiceSaved;
        if (State == "file-loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "file-error") throw new IOException("合成读取失败");
        if (State == "file-unavailable") throw new DsmException("synthetic", "synthetic", 102);
        if (State == "file-empty") return new();
        var partial = State == "file-partial" || State == "file-recovered" && _fileServiceReads == 1;
        return _fileServiceLastRead = new()
        {
            AvailableFields = partial ? NasFileServiceFields.Smb | NasFileServiceFields.Ftps | NasFileServiceFields.FtpPort : (NasFileServiceFields)1023,
            FailedFields = partial ? NasFileServiceFields.Nfs | NasFileServiceFields.Ftp | NasFileServiceFields.Sftp : NasFileServiceFields.None,
            SmbEnabled = true, NfsEnabled = false, FtpEnabled = false, FtpsEnabled = true,
            FtpPort = 21, SftpEnabled = true, SftpPort = 2222, SsdpEnabled = true, BonjourEnabled = true,
            TimeMachineEnabled = true,
        };
    }
    private Task<MutationResult> SavedAsync()
    {
        Writes++;
        var unknown = State == "terminal-review";
        return Task.FromResult(new MutationResult(1,
            unknown ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess,
            "saveSettings", true, unknown, unknown ? new(0, 0, 1) : new(1, 0, 0)));
    }
}

internal static class SmokeSnapshot
{
    internal static void RecordFailure(Exception error) => System.IO.File.WriteAllText(
        System.IO.Path.Combine(AppContext.BaseDirectory, "smoke-failure.txt"), error.ToString());

    internal static async Task SaveAsync(FrameworkElement root)
    {
        // 测试宿主输出自身 XAML，不抓取桌面或其他应用。
        var theme = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_THEME");
        var windowRoot = (Application.Current as App)?.MainWindow?.Content as FrameworkElement ?? root;
        if (Enum.TryParse<ElementTheme>(theme, out var requested)) windowRoot.RequestedTheme = requested;
        await Task.Delay(1500);
        var scenario = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_SCENARIO") ?? "files";
        if (scenario == "tray-lifecycle") { await SaveTrayLifecycleAsync(root); return; }
        if (scenario == "cloud-settings") { await SaveCloudSettingsAsync(root); return; }
        if (scenario == "notification-lifecycle") { await SaveNotificationLifecycleAsync(root); return; }
        if (scenario == "vm-networks") { await SaveVirtualMachineNetworksAsync(root); return; }
        if (scenario == "chat-tools") { await SaveChatToolsAsync(root); return; }
        if (scenario == "remote-mounts") { await SaveRemoteMountsAsync(root); return; }
        if (scenario == "container-networks") { await SaveContainerNetworksAsync(root); return; }
        if (scenario == "container-network-create") { await SaveContainerNetworkCreationAsync(root); return; }
        if (scenario == "container-network-delete") { await SaveContainerNetworkDeletionAsync(root); return; }
        if (scenario == "container-image-delete") { await SaveContainerImageDeletionAsync(root); return; }
        if (scenario == "container-image-pull") { await SaveContainerImagePullAsync(root); return; }
        if (scenario == "container-operations") { await SaveContainerMutationsAsync(root); return; }
        if (scenario == "container-registry") { await SaveContainerRegistryAsync(root); return; }
        if (scenario == "transfer-lifecycle") { await SaveTransferLifecycleAsync(root); return; }
        if (scenario == "transfer-pagination") { await SaveTransferPaginationAsync(root); return; }
        if (scenario == "files-drag-move") { await SaveFileDragMoveAsync(root); return; }
        if (scenario == "files-archive") { await SaveFileArchiveAsync(root); return; }
        if (scenario == "files-favorites") { await SaveFileFavoritesAsync(root); return; }
        if (scenario == "files-selection-download") { await SaveSelectionDownloadAsync(root); return; }
        if (scenario == "files-folder-upload") { await SaveFolderUploadAsync(root); return; }
        if (scenario == "files-upload-batch") { await SaveFileUploadBatchAsync(root); return; }
        if (scenario == "files-recycle-recovery") { await SaveCopyRecoveryAsync(root, recycle: true); return; }
        if (scenario == "files-copy-recovery") { await SaveCopyRecoveryAsync(root); return; }
        if (scenario == "files-copy-conflicts") { await SaveCopyConflictsAsync(root); return; }
        if (scenario == "files-large-recycle") { await SaveLargeRecycleAsync(root); return; }
        if (scenario == "files-large-copy-move") { await SaveLargeCopyMoveAsync(root); return; }
        if (scenario == "files-extract") { await SaveFileExtractionAsync(root); return; }
        if (scenario == "vm-create") { await SaveVirtualMachineCreationAsync(root); return; }
        if (scenario == "vm-tasks") { await SaveVirtualMachineTasksAsync(root); return; }
        if (scenario == "vm-settings") { await SaveVirtualMachineSettingsAsync(root); return; }
        if (scenario == "vm-console") { await SaveVirtualMachineConsoleAsync(root); return; }
        if (scenario == "vm-image-import") { await SaveVirtualMachineImageImportAsync(root); return; }
        if (scenario == "vm-image-delete") { await SaveVirtualMachinePowerBatchAsync(root, deletion: true, images: true); return; }
        if (scenario == "vm-delete") { await SaveVirtualMachinePowerBatchAsync(root, deletion: true); return; }
        if (scenario == "vm-task-cleanup") { await SaveVirtualMachineTaskCleanupAsync(root); return; }
        if (scenario == "vm-power-batch") { await SaveVirtualMachinePowerBatchAsync(root); return; }
        if (scenario == "vm-power") { await SaveVirtualMachinePowerAsync(root); return; }
        if (scenario == "download-settings") { await SaveDownloadSettingsAsync(root); return; }
        if (scenario == "download-batch") { await SaveDownloadBatchAsync(root); return; }
        if (scenario == "download-file-options") { await SaveDownloadFileOptionsAsync(root); return; }
        if (scenario == "nas-service-settings") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-region-settings") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-network-settings") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-security-settings") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-hardware-settings") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-ddns-settings") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-package-settings") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-directory-settings") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-power-settings") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-connection-settings") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-task-settings") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-disk-tests") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-remote-access") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-power-schedule") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-external-storage") { await SaveNasServiceSettingsAsync(root); return; }
        if (scenario == "nas-zram") { await SaveNasServiceSettingsAsync(root); return; }
        if (root is Frame { Content: ShellPage shell })
        {
            var shellNavigation = (NavigationView)shell.FindName("Navigation");
            switch (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_PANE"))
            {
                case "open": shellNavigation.IsPaneOpen = true; break;
                case "compact": shellNavigation.IsPaneOpen = false; break;
                case "cycle":
                    shellNavigation.IsPaneOpen = false;
                    await Task.Delay(200);
                    shell.ToggleNavigationPane();
                    await Task.Delay(200);
                    shell.ToggleNavigationPane();
                    break;
            }
            var content = (Frame)shell.FindName("ContentFrame");
            var module = scenario switch
            {
                "photos" => AppModule.Photos,
                "chat" => AppModule.Chat,
                "downloads" => AppModule.Downloads,
                "containers" => AppModule.Containers,
                "vms" => AppModule.VirtualMachines,
                _ => (AppModule?)null,
            };
            if (module is { } selectedModule)
            {
                var navigation = (NavigationView)shell.FindName("Navigation");
                navigation.SelectedItem = navigation.MenuItems.OfType<NavigationViewItem>()
                    .Single(item => item.Tag is AppModule candidate && candidate == selectedModule);
                await Task.Delay(500);
                if (scenario == "downloads" && Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") == "link-create" && content.Content is DownloadStationPage downloadsPage)
                {
                    // 调用实际页面入口，检查 URI 与复用的目录选项一起控制确认按钮；不发送任务。
                    var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
                    var opened = (Task)typeof(DownloadStationPage).GetMethod("ShowCreateTaskDialogAsync", flags)!.Invoke(downloadsPage, null)!;
                    await Task.Delay(350);
                    var dialog = (ContentDialog)typeof(DownloadStationPage).GetField("_linkCreateDialog", flags)!.GetValue(downloadsPage)!;
                    var children = ((StackPanel)dialog.Content).Children;
                    var uriBox = children.OfType<TextBox>().Single();
                    var options = children.OfType<DownloadCreateOptionsDialogContent>().Single();
                    if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("空链接可提交。");
                    uriBox.Text = "https://example.invalid/synthetic.iso"; await Task.Delay(100);
                    if (!dialog.IsPrimaryButtonEnabled || ((PasswordBox)options.FindName("ArchivePassword")).Visibility != Visibility.Collapsed)
                        throw new InvalidOperationException("普通链接创建选项或提交门不正确。");
                    await WriteSnapshotAsync(dialog); dialog.Hide(); await opened; return;
                }
                if (scenario == "chat" && content.Content is ChatPage { DataContext: LanStash.App.Features.Chat.ChatBrowserViewModel chat } chatPage)
                {
                    await chat.SelectConversationAsync(chat.Conversations[0]);
                    if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") == "chat-realtime")
                    {
                        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                        while (chat.Messages.Count != 6) await Task.Delay(20, timeout.Token);
                        await chatPage.SetWindowVisibleAsync(false);
                        while (SmokeRepository.ActiveRealtimeSubscriptions != 0) await Task.Delay(20, timeout.Token);
                        static ScrollViewer? Scroll(DependencyObject element)
                        {
                            if (element is ScrollViewer found) return found;
                            for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(element); index++)
                                if (Scroll(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(element, index)) is { } child) return child;
                            return null;
                        }
                        var messageList = (ListView)chatPage.FindName("MessageList");
                        var scroll = Scroll(messageList) ?? throw new InvalidOperationException("消息滚动容器缺失。");
                        scroll.ChangeView(null, 0, null, disableAnimation: true); await Task.Delay(100);
                        await chatPage.SetWindowVisibleAsync(true);
                        while (SmokeRepository.ActiveRealtimeSubscriptions != 1) await Task.Delay(20, timeout.Token);
                        while (chat.Messages.Count != 7) await Task.Delay(20, timeout.Token);
                        await Task.Delay(150);
                        if (scroll.VerticalOffset > 4) throw new InvalidOperationException("阅读历史时新事件抢走了滚动位置。");
                        scroll.ChangeView(null, scroll.ScrollableHeight, null, disableAnimation: true); await Task.Delay(100);
                        if (messageList.ItemsPanelRoot is not ItemsStackPanel { ItemsUpdatingScrollMode: ItemsUpdatingScrollMode.KeepLastItemInView })
                            throw new InvalidOperationException("回到底部后没有恢复新消息跟随。");
                    }
                }
            }
            if (scenario == "nas")
            {
                var navigation = (NavigationView)shell.FindName("Navigation");
                navigation.SelectedItem = navigation.MenuItems.OfType<NavigationViewItem>()
                    .Single(item => item.Tag is AppModule.NasSettings);
                await Task.Delay(400);
                var nas = (NasDetailsPage)content.Content;
                var sections = (ListView)nas.FindName("SectionList");
                sections.SelectedItem = sections.Items.OfType<NasDetailsSectionOption>()
                    .Single(item => item.Kind == NasDetailsSectionKind.StorageHealth);
            }
            else if (content.Content is FilesPage files)
            {
                if (scenario is "selected" or "list")
                {
                    await files.BrowserModel.OpenAsync(files.BrowserModel.Items[0]);
                    files.BrowserModel.SelectedItem = files.BrowserModel.Items[0];
                    if (scenario == "list") files.BrowserModel.Layout = FileBrowserLayout.List;
                }
                if (scenario == "filtered-empty") files.BrowserModel.SetFilter("no-matching-synthetic-item");
            }
        }
        await Task.Delay(250);
        if (root is Frame { Content: ShellPage currentShell })
        {
            var page = ((Frame)currentShell.FindName("ContentFrame")).Content as FrameworkElement
                ?? throw new InvalidOperationException("合成页面未加载。");
            var expected = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") switch
            {
                "loading" => "LoadingState",
                "empty" => "EmptyState",
                "error" => "ErrorState",
                _ => scenario switch
                {
                    "filtered-empty" => "FilteredEmptyState",
                    "photos" => "LibraryRoot",
                    "containers" => "SectionPivot",
                    "vms" => "MachineList",
                    _ => "ContentState",
                },
            };
            if (page.FindName(expected) is not FrameworkElement { Visibility: Visibility.Visible })
                throw new InvalidOperationException($"合成页面没有显示预期状态：{expected}");
            if (scenario == "photos" && Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") is { } photoState &&
                photoState.StartsWith("photo-", StringComparison.Ordinal))
            {
                var localization = Localization.LocalizationService.Current;
                var messageKey = photoState switch
                {
                    "photo-error" => "PhotosServiceInvalidResponse",
                    "photo-loading" => "PhotosLoadingDescription",
                    _ => "PhotosEmptyDescription",
                };
                if (page.FindName("EmptyPanel") is not FrameworkElement { Visibility: Visibility.Visible } ||
                    page.FindName("EmptyMessage") is not TextBlock message || message.Text != localization.Get(messageKey))
                    throw new InvalidOperationException("照片状态说明与实际结果不一致。");
                if (photoState == "photo-error" && page.FindName("ErrorBar") is not InfoBar { IsOpen: true })
                    throw new InvalidOperationException("照片失败没有显示重试入口。");
            }
            if (scenario == "selected" && page.FindName("InspectorDetails") is not FrameworkElement { Visibility: Visibility.Visible })
                throw new InvalidOperationException("选中后未显示文件详情。");
            if (scenario == "list" && page.FindName("FileList") is not FrameworkElement { Visibility: Visibility.Visible })
                throw new InvalidOperationException("列表模式未显示。");
        }
        await Task.Delay(600);
        root.UpdateLayout();
        if (root is Frame { Content: LoginPage login })
        {
            var connect = (Button)login.FindName("ConnectButton");
            var bounds = connect.TransformToVisual(root).TransformBounds(new Windows.Foundation.Rect(0, 0, connect.ActualWidth, connect.ActualHeight));
            if (bounds.Y < 0 || bounds.Bottom > root.ActualHeight || bounds.Right > root.ActualWidth || connect.ActualHeight < 44)
                throw new InvalidOperationException("登录连接按钮超出可见范围。");
            if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") == "login-error" &&
                ((InfoBar)login.FindName("ErrorBar")).Visibility != Visibility.Visible)
                throw new InvalidOperationException("登录错误没有显示。");
        }
        if (windowRoot.ActualTheme != root.ActualTheme)
            throw new InvalidOperationException("窗口标题栏与页面主题不一致。");
        if ((Application.Current as App)?.MainWindow is { } window)
        {
            var title = (TextBlock)windowRoot.FindName("WindowTitle");
            var expectedForeground = ((Microsoft.UI.Xaml.Media.SolidColorBrush)title.Foreground).Color;
            if (window.AppWindow.TitleBar.ButtonForegroundColor != expectedForeground ||
                window.AppWindow.TitleBar.ButtonBackgroundColor != Microsoft.UI.Colors.Transparent)
                throw new InvalidOperationException("原生标题栏按钮没有同步窗口主题。");
        }
        if (root is Frame { Content: ShellPage checkedShell })
        {
            var navigation = (NavigationView)checkedShell.FindName("Navigation");
            foreach (var item in navigation.MenuItems.OfType<NavigationViewItem>())
            {
                if (item.Icon is not PathIcon icon) continue;
                var rectangle = icon.TransformToVisual(root).TransformBounds(new Windows.Foundation.Rect(0, 0, icon.ActualWidth, icon.ActualHeight));
                var paneWidth = navigation.IsPaneOpen ? navigation.OpenPaneLength : navigation.CompactPaneLength;
                if (rectangle.X < 0 || rectangle.Right > paneWidth || rectangle.Y < 0 || rectangle.Bottom > root.ActualHeight)
                    throw new InvalidOperationException("导航图标超出侧栏可见范围。");
                var geometry = icon.Data.Bounds;
                if (geometry.X < 0 || geometry.Y < 0 || geometry.Right > icon.Width || geometry.Bottom > icon.Height)
                    throw new InvalidOperationException("导航图标路径超出图标视口。");
            }
            if (!navigation.IsPaneOpen && ((FrameworkElement)checkedShell.FindName("StorageFooterItem")).Visibility != Visibility.Collapsed)
                throw new InvalidOperationException("紧凑导航仍显示展开详情。");
        }
        if (root is Frame { Content: ShellPage layoutShell } &&
            ((Frame)layoutShell.FindName("ContentFrame")).Content is FrameworkElement layoutPage)
        {
            var bounds = new[] { "RefreshButton", "SettingsButton", "SearchBox", "CreateTaskButton", "SectionPivot", "ResourcePivot", "Sections" }
                .Select(name => (name, element: layoutPage.FindName(name) as FrameworkElement))
                .Where(pair => pair.element is not null)
                .Select(pair => new { pair.name, pair.element!.ActualWidth, pair.element.ActualHeight,
                    Visibility = pair.element.Visibility.ToString(),
                    X = pair.element.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point()).X,
                    Y = pair.element.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point()).Y }).ToArray();
            var overflow = bounds.Where(item => item.Visibility == "Visible" && item.ActualWidth > 0 &&
                (item.X < 0 || item.X + item.ActualWidth > root.ActualWidth + 1 || item.Y < 0)).ToArray();
            if (overflow.Length > 0)
                throw new InvalidOperationException("工具栏控件超出窗口可见范围：" + string.Join(", ", overflow.Select(item => $"{item.name} ({item.X},{item.Y},{item.ActualWidth})")));
            System.IO.File.WriteAllText(System.IO.Path.Combine(AppContext.BaseDirectory, "smoke-layout.json"),
                System.Text.Json.JsonSerializer.Serialize(new { PageWidth = layoutPage.ActualWidth,
                    RasterizationScale = root.XamlRoot.RasterizationScale, Theme = windowRoot.ActualTheme.ToString(), Bounds = bounds }));
            if (layoutPage is FilesPage)
            {
                foreach (var name in new[] { "GridLayoutButton", "ListLayoutButton", "InspectorButton" })
                {
                    var button = (Microsoft.UI.Xaml.Controls.Primitives.ToggleButton)layoutPage.FindName(name);
                    var icon = (FrameworkElement)button.Content;
                    var iconBounds = icon.TransformToVisual(button).TransformBounds(new Windows.Foundation.Rect(0, 0, icon.ActualWidth, icon.ActualHeight));
                    if (Math.Abs(iconBounds.X + iconBounds.Width / 2 - button.ActualWidth / 2) > 1 ||
                        Math.Abs(iconBounds.Y + iconBounds.Height / 2 - button.ActualHeight / 2) > 1)
                        throw new InvalidOperationException("视图按钮图标没有在选中背景内居中。");
                }
            }
        }
        await WriteSnapshotAsync(windowRoot);
    }

    private static async Task SaveDownloadFileOptionsAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "file-options";
        var folders = new SmokeDownloadSettingsRepository(state == "file-empty" ? "settings-empty-folders" : "settings-basic");
        using var model = new DownloadCreateOptionsViewModel(state == "file-legacy" ? null : folders);
        if (state is "file-folders" or "file-empty") await model.BrowseAsync("");
        using var content = new DownloadCreateOptionsDialogContent(model, "synthetic.torrent");
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = root.ActualTheme, Content = content,
            Title = Localization.LocalizationService.Current.Get("DownloadCreateFileTitle"), PrimaryButtonText = Localization.LocalizationService.Current.Get("DownloadStationCreateSubmit"),
            CloseButtonText = Localization.LocalizationService.Current.Get("ActionCancel"), DefaultButton = ContentDialogButton.Close,
            PrimaryButtonStyle = content.ActionButtonStyle, CloseButtonStyle = content.ActionButtonStyle, IsPrimaryButtonEnabled = content.CanSubmit };
        void Update() => dialog.IsPrimaryButtonEnabled = content.CanSubmit;
        content.StateChanged += Update; var showing = dialog.ShowAsync(); await Task.Delay(350);
        if (state == "file-folders")
        {
            var list = (ListView)content.FindName("FolderList"); list.SelectedItem = model.Folders[0];
            if (((Button)content.FindName("ChooseButton")).IsEnabled) throw new InvalidOperationException("只读目录可以选中。");
            list.SelectedItem = model.Folders[1];
            if (!((Button)content.FindName("ChooseButton")).IsEnabled || content.CanSubmit) throw new InvalidOperationException("目录选择尚未结束就可提交。");
        }
        else if (state == "file-submit")
        {
            var password = (PasswordBox)content.FindName("ArchivePassword"); password.Password = "  synthetic  ";
            if (content.TakePassword() != "  synthetic  " || password.Password.Length != 0) throw new InvalidOperationException("解压密码被修改或没有清除。");
            content.BeginSubmission(); if (content.CanSubmit) throw new InvalidOperationException("任务文件可以重复提交。");
        }
        else if (state == "file-options") ((PasswordBox)content.FindName("ArchivePassword")).Password = "synthetic";
        if (state == "file-legacy" && ((Button)content.FindName("BrowseButton")).Visibility != Visibility.Collapsed) throw new InvalidOperationException("无目录能力时仍显示浏览入口。");
        if (state == "file-empty" && ((TextBlock)content.FindName("EmptyText")).Visibility != Visibility.Visible) throw new InvalidOperationException("目录空状态缺失。");
        await Task.Delay(150); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog);
        content.StateChanged -= Update; dialog.Hide(); await showing;
    }

    private static async Task SaveDownloadBatchAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "batch-pause";
        var repository = new SmokeDownloadBatchRepository(state);
        using var model = new DownloadTaskBatchViewModel(repository);
        var load = model.LoadAsync(); if (state != "batch-loading") await load;
        model.SetAction(state switch { "batch-resume" => DownloadBatchAction.Resume, "batch-remove" => DownloadBatchAction.RemoveTask,
            "batch-finish" => DownloadBatchAction.FinishIncomplete, _ => DownloadBatchAction.Pause });
        using var content = new DownloadTaskBatchDialogContent(model);
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = root.ActualTheme, Content = content,
            Title = Localization.LocalizationService.Current.Get("DownloadBatchTitle"), CloseButtonText = Localization.LocalizationService.Current.Get("DownloadSettingsClose"),
            PrimaryButtonText = content.PrimaryText, DefaultButton = ContentDialogButton.Close,
            PrimaryButtonStyle = content.ActionButtonStyle, CloseButtonStyle = content.ActionButtonStyle };
        void Update() { dialog.PrimaryButtonText = content.PrimaryText; dialog.IsPrimaryButtonEnabled = content.CanSubmit; }
        content.StateChanged += Update; Update(); var showing = dialog.ShowAsync(); await Task.Delay(350);
        if (state == "batch-filtered") { ((TextBox)content.FindName("FilterBox")).Text = "no match"; await Task.Delay(150); }
        if (state is "batch-pause" or "batch-resume" or "batch-remove" or "batch-finish" or "batch-review" or "batch-partial")
        {
            ((ListView)content.FindName("TaskChoices")).SelectAll();
            if (content.CanSubmit) throw new InvalidOperationException("批量下载任务未确认即开放操作。");
            ((CheckBox)content.FindName("Confirmation")).IsChecked = true; await content.SubmitAsync();
            if (state == "batch-review")
            {
                if (!model.RequiresReview || repository.Writes != 1) throw new InvalidOperationException("未知结果未暂停。");
                await content.SubmitAsync(); await content.SubmitAsync();
                if (repository.Writes != 1 || !model.CanContinue || content.CanSubmit) throw new InvalidOperationException("核对触发了新写操作。");
                ((CheckBox)content.FindName("Confirmation")).IsChecked = true; await content.SubmitAsync();
            }
            await content.SubmitAsync();
            if (repository.Writes != 3 || model.HasPending || content.CanSubmit) throw new InvalidOperationException("批量结果或连点防护不正确。");
        }
        if (state is "batch-empty" or "batch-filtered" && ((TextBlock)content.FindName("EmptyText")).Visibility != Visibility.Visible) throw new InvalidOperationException("批量空状态缺失。");
        if (state == "batch-loading" && !((ProgressRing)content.FindName("LoadingRing")).IsActive) throw new InvalidOperationException("加载状态缺失。");
        if (state == "batch-error" && ((TextBlock)content.FindName("ErrorText")).Visibility != Visibility.Visible) throw new InvalidOperationException("错误状态缺失。");
        await Task.Delay(150); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog);
        content.StateChanged -= Update; dialog.Hide(); await showing; model.CancelLoading(); await load;
    }

    private static async Task SaveRemoteMountsAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "mount-create";
        var repository = System.Reflection.DispatchProxy.Create<IFileLocationsRepository, SmokeRemoteMountRepository>();
        var fake = (SmokeRemoteMountRepository)repository; fake.State = state;
        using var browser = new FileBrowserViewModel(new SmokeDragMoveRepository());
        using var model = new Features.Files.Locations.FileLocationsViewModel(); model.Activate(repository.ProfileId, repository, browser);
        using var owner = new FileLocationsView(); owner.Attach(model, (_, _, _) => Task.FromResult(false), _ => Task.CompletedTask);
        ((Frame)shell.FindName("ContentFrame")).Content = owner; await Task.Delay(150);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        Task Open() => (Task)typeof(FileLocationsView).GetMethod("ShowRemoteManagementAsync", flags)!.Invoke(owner, new object?[] { null, RemoteMountAction.Create })!;
        ContentDialog Dialog() => (ContentDialog)typeof(FileLocationsView).GetField("_remoteManagementDialog", flags)!.GetValue(owner)!;
        var showing = Open(); await Task.Delay(220); if (showing.IsCompleted) await showing;
        var dialog = Dialog(); var content = (RemoteMountManagementDialogContent)dialog.Content;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("挂载窗口主题或默认动作错误。");
        if (state == "mount-loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("缺少加载状态。");
        if (state == "mount-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("缺少错误状态。");
        if (state == "mount-empty" && Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("缺少空状态。");
        if (state == "mount-filter")
        {
            Control<TextBox>("FilterInput").Text = "no-match";
            await Task.Delay(100);
            if (Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible || Control<ListView>("ConnectionList").Items.Count != 0) throw new InvalidOperationException("筛选空状态错误。");
        }
        if (state is not ("mount-loading" or "mount-error" or "mount-empty" or "mount-filter"))
        {
            var edit = state is "mount-same" or "mount-move" or "mount-disconnect" or "mount-reopen";
            if (edit) Control<ListView>("ConnectionList").SelectedIndex = 0;
            else
            {
                Control<TextBox>("ServerInput").Text = "server.invalid"; Control<TextBox>("RemotePathInput").Text = "share";
                Control<TextBox>("TargetInput").Text = "/share/new";
            }
            await Task.Delay(100);
            if (state == "mount-disconnect") Control<ComboBox>("ActionInput").SelectedIndex = 1;
            if (state == "mount-move") Control<TextBox>("TargetInput").Text = "/share/new";
            if (state == "mount-nfs")
            {
                Control<ComboBox>("ProtocolInput").SelectedIndex = 1; Control<ComboBox>("NfsTransportInput").SelectedIndex = 1;
                Control<ComboBox>("NfsVersionInput").SelectedIndex = 1;
                await Task.Delay(100);
                if (Control<ComboBox>("NfsTransportInput").IsEnabled || Control<ComboBox>("NfsTransportInput").SelectedIndex != 0) throw new InvalidOperationException("NFS 4 未固定 TCP。");
            }
            else if (state != "mount-disconnect") Control<PasswordBox>("PasswordInput").Password = "synthetic-secret";
            await Task.Delay(100);
            await content.SaveAsync(); if (fake.Writes != 0) throw new InvalidOperationException("未确认也发送了挂载。");
            Control<CheckBox>("RiskAcknowledgement").IsChecked = true;
            if (!content.CanSave || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("有效挂载未开放。");
            if (state == "mount-change")
            {
                Control<TextBox>("TargetInput").Text = "/share/changed"; await content.SaveAsync();
                await Task.Delay(100);
                if (fake.Writes != 0 || content.CanSave || Control<CheckBox>("RiskAcknowledgement").IsChecked == true) throw new InvalidOperationException("修改目标复用了旧确认。");
            }
            else if (state == "mount-confirm")
            {
                var risk = Control<CheckBox>("RiskAcknowledgement"); if (!risk.Focus(FocusState.Keyboard)) throw new InvalidOperationException("确认无法键盘聚焦。");
                risk.StartBringIntoView();
            }
            else
            {
                var saving = content.SaveAsync();
                if (state is "mount-close-busy" or "mount-profile-change")
                {
                    await Task.Delay(70); await content.SaveAsync(); if (fake.Writes != 1) throw new InvalidOperationException("出现并发重复提交。");
                    dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
                    if (state == "mount-profile-change") model.Deactivate();
                    else typeof(FileLocationsView).GetMethod("CloseRemoteManagement", flags)!.Invoke(owner, null);
                    await Task.Delay(80); await saving; await showing;
                    if (!fake.LastToken.IsCancellationRequested || Control<PasswordBox>("PasswordInput").Password.Length != 0) throw new InvalidOperationException("关闭/切换没有取消并清理密码。");
                    MarkSnapshotComplete();
                    return;
                }
                await saving; await content.SaveAsync();
                if (fake.Writes != 1 || content.CanSave || Control<PasswordBox>("PasswordInput").Password.Length != 0) throw new InvalidOperationException("提交后密码或确认未清除。");
                if (state == "mount-review")
                {
                    var viewModel = (Features.Files.Locations.RemoteMountManagementViewModel)typeof(RemoteMountManagementDialogContent).GetField("_model", flags)!.GetValue(content)!;
                    fake.Resolve = true; await viewModel.ReviewAsync();
                    if (fake.Writes != 1 || fake.Reviews != 1 || viewModel.Progress?.Stage != RemoteMountStage.Complete) throw new InvalidOperationException("核查结果发生写入。");
                }
                if (state == "mount-reopen")
                {
                    dialog.Hide(); await showing.WaitAsync(TimeSpan.FromSeconds(5)); showing = Open(); await Task.Delay(220);
                    if (showing.IsCompleted) await showing;
                    dialog = Dialog(); content = (RemoteMountManagementDialogContent)dialog.Content;
                    if (Control<PasswordBox>("PasswordInput").Password.Length != 0 || !Control<PasswordBox>("PasswordInput").IsEnabled || content.CanSave || Control<TextBox>("TargetInput").IsEnabled) throw new InvalidOperationException("恢复未冻结配置或泄露密码。");
                }
                if (state is "mount-same" or "mount-move")
                {
                    if (state == "mount-same") Control<PasswordBox>("PasswordInput").Password = "reentered-secret";
                    Control<CheckBox>("RiskAcknowledgement").IsChecked = true; if (!content.CanSave) throw new InvalidOperationException("无法明确继续第二步。");
                    await content.SaveAsync(); if (fake.Writes != 2 || content.CanSave) throw new InvalidOperationException("两步修改状态错误。");
                }
            }
        }
        await Task.Delay(120); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false).WaitAsync(TimeSpan.FromSeconds(5));
        dialog.Hide(); await showing.WaitAsync(TimeSpan.FromSeconds(5)); MarkSnapshotComplete();
    }

    private static async Task SaveContainerNetworkCreationAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "netcreate-auto";
        var repository = new SmokeRepository(); using var page = new ContainerManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(350);
        ((Pivot)page.FindName("SectionPivot")).SelectedIndex = 3;
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var opened = (Task)typeof(ContainerManagerPage).GetMethod("ShowNetworkCreationAsync", flags)!.Invoke(page, null)!; await Task.Delay(350);
        if (opened.IsCompleted) await opened;
        var dialog = (ContentDialog)typeof(ContainerManagerPage).GetField("_networkCreationDialog", flags)!.GetValue(page)!;
        var content = (ContainerNetworkCreateDialogContent)dialog.Content;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("创建窗口主题或默认按钮错误。");
        if (state == "netcreate-loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("创建核查加载状态缺失。");
        if (state == "netcreate-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("创建核查错误状态缺失。");
        if (state is not ("netcreate-loading" or "netcreate-error"))
        {
            Control<TextBox>("NameInput").Text = state == "netcreate-invalid-name" ? "bad name" : "synthetic-net";
            if (state is "netcreate-manual" or "netcreate-outside" or "netcreate-confirm")
            {
                Control<ComboBox>("Ipv4Mode").SelectedIndex = 1; Control<TextBox>("SubnetInput").Text = "192.0.2.0/24";
                Control<TextBox>("RangeInput").Text = "192.0.2.128/25";
                Control<TextBox>("GatewayInput").Text = state == "netcreate-outside" ? "198.51.100.1" : "192.0.2.1";
            }
            if (state is "netcreate-ipv6" or "netcreate-confirm")
            {
                Control<ComboBox>("Ipv6Mode").SelectedIndex = 1; Control<TextBox>("Ipv6SubnetInput").Text = "fd00::/64";
                Control<TextBox>("Ipv6GatewayInput").Text = "fd00::1";
            }
            if (state == "netcreate-masquerade") Control<CheckBox>("MasqueradeInput").IsChecked = true;
            await content.SaveAsync(); if (repository.NetworkCreateCalls != 0) throw new InvalidOperationException("创建没有要求确认。");
            Control<CheckBox>("RiskAcknowledgement").IsChecked = true; await Task.Delay(80);
            if (state is "netcreate-readonly" or "netcreate-invalid-name" or "netcreate-outside" or "netcreate-pending" or "netcreate-recovered")
            {
                if (content.CanSave || dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("不允许的创建被启用。");
                await content.SaveAsync(); if (repository.NetworkCreateCalls != 0) throw new InvalidOperationException("保护入口仍发送请求。");
            }
            else
            {
                if (!content.CanSave || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("有效创建不能确认。");
                if (state == "netcreate-late-change")
                {
                    Control<TextBox>("NameInput").Text = "changed-net"; await content.SaveAsync();
                    if (repository.NetworkCreateCalls != 0 || Control<CheckBox>("RiskAcknowledgement").IsChecked == true) throw new InvalidOperationException("改名沿用旧确认。");
                }
                else if (state == "netcreate-confirm")
                {
                    var risk = Control<CheckBox>("RiskAcknowledgement"); if (!risk.Focus(FocusState.Keyboard)) throw new InvalidOperationException("风险确认不能键盘聚焦。");
                    risk.StartBringIntoView(); await Task.Delay(150);
                }
                else
                {
                    var saving = content.SaveAsync();
                    if (state == "netcreate-close-busy")
                    {
                        await Task.Delay(80); await content.SaveAsync(); if (repository.NetworkCreateCalls != 1) throw new InvalidOperationException("并发重复创建。");
                        await WriteSnapshotAsync(dialog); page.Dispose(); await opened; await saving;
                        if (!repository.NetworkCreateCancelled) throw new InvalidOperationException("关闭后创建未取消等待。"); return;
                    }
                    await saving; await content.SaveAsync(); if (repository.NetworkCreateCalls != 1) throw new InvalidOperationException("重复提交创建。");
                    if (!Control<InfoBar>("FeedbackNotice").IsOpen) throw new InvalidOperationException("创建没有结果反馈。");
                    if (state is "netcreate-ipv6" or "netcreate-masquerade" && Control<InfoBar>("FeedbackNotice").Severity == InfoBarSeverity.Success) throw new InvalidOperationException("未核实高级选项被报成功。");
                    if (state == "netcreate-unknown") { await content.ReloadAsync(); await content.SaveAsync(); if (repository.NetworkCreateCalls != 1 || content.CanSave) throw new InvalidOperationException("核查重放创建。"); }
                }
            }
        }
        await WriteSnapshotAsync(dialog); dialog.Hide(); await opened;
        if (state == "netcreate-auto" && ((ListView)page.FindName("NetworksList")).Items.Count != 2) throw new InvalidOperationException("创建后主列表没有刷新。");
    }

    private static async Task SaveContainerMutationsAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "ops-confirm";
        var repository = new SmokeContainerMutationRepository(state); using var page = new ContainerManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(250);
        if (state == "ops-transition-state")
        {
            if (new Features.Containers.ContainerItem(repository.Rows[0]).StatusText != Localization.LocalizationService.Current.Get("ContainerManagerStatusRestarting"))
                throw new InvalidOperationException("重启状态显示错误。");
            var pivot = (Pivot)page.FindName("SectionPivot");
            pivot.ApplyTemplate(); await Task.Delay(500); pivot.SelectedItem = pivot.Items[1];
            await Task.Delay(700); page.UpdateLayout();
            var list = (ListView)page.FindName("ContainerList"); var pane = (FrameworkElement)page.FindName("ContentState");
            if (pivot.SelectedIndex != 1 || list.Items.Count != 3 || pane.Visibility != Visibility.Visible || pane.ActualHeight <= 0)
                throw new InvalidOperationException($"重启清单未呈现：index={pivot.SelectedIndex}, count={list.Items.Count}, visible={pane.Visibility}, height={pane.ActualHeight}");
            list.ScrollIntoView(list.Items[0]); await Task.Delay(200); list.UpdateLayout();
            var row = list.ContainerFromIndex(0) as ListViewItem ?? throw new InvalidOperationException("重启条目未实例化。");
            static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
            {
                for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
                { var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i); yield return child; foreach (var nested in Descendants(child)) yield return nested; }
            }
            if (!Descendants(row).OfType<TextBlock>().Any(block => block.Text == Localization.LocalizationService.Current.Get("ContainerManagerStatusRestarting")))
                throw new InvalidOperationException("重启状态没有绑定到实际列表文本。");
            await WriteSnapshotAsync(row); return;
        }
        if (!((Button)page.FindName("ManageContainersButton")).IsEnabled) throw new InvalidOperationException("容器管理入口不可用。");
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        Task Show() => (Task)typeof(ContainerManagerPage).GetMethod("ShowContainerMutationsAsync", flags)!.Invoke(page, null)!;
        ContentDialog Dialog() => (ContentDialog)typeof(ContainerManagerPage).GetField("_containerMutationDialog", flags)!.GetValue(page)!;
        var opened = Show(); await Task.Delay(300);
        var dialog = Dialog(); var content = (ContainerMutationDialogContent)dialog.Content;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme || dialog.IsPrimaryButtonEnabled || repository.Writes != 0)
            throw new InvalidOperationException("容器默认按钮、主题或确认前状态错误。");
        if (state == "ops-loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("加载状态缺失。");
        if (state == "ops-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("读取失败被忽略。");
        if (state == "ops-empty" && Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("空状态缺失。");
        if (state == "ops-readonly" && Control<TextBlock>("ReadOnlyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("不可操作原因缺失。");
        if (state == "ops-filtered")
        { Control<TextBox>("SearchBox").Text = "missing"; await Task.Delay(100); if (Control<ListView>("TargetsList").Items.Count != 0 || Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("筛选空状态缺失。"); }
        if (state == "ops-recovery" && (Control<TextBlock>("PendingNotice").Visibility != Visibility.Visible || repository.Writes != 0)) throw new InvalidOperationException("恢复状态重放或不可见。");
        if (state is not ("ops-loading" or "ops-error" or "ops-empty" or "ops-readonly" or "ops-filtered" or "ops-recovery"))
        {
            var action = state switch { "ops-stop" or "ops-transition-stop" => ContainerMutationAction.Stop, "ops-restart" or "ops-transition-restart" => ContainerMutationAction.Restart, "ops-delete" => ContainerMutationAction.Delete, _ => ContainerMutationAction.Start };
            Control<ComboBox>("ActionPicker").SelectedIndex = (int)action;
            var targets = Control<ListView>("TargetsList"); foreach (var item in targets.Items.ToArray()) targets.SelectedItems.Add(item);
            if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("选择即提交，缺少确认。");
            Control<CheckBox>("RiskAcknowledgement").IsChecked = true;
            if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("确认后仍不能操作。");
            if (state == "ops-change")
            { Control<TextBox>("SearchBox").Text = "1"; await Task.Delay(100); if (dialog.IsPrimaryButtonEnabled || Control<CheckBox>("RiskAcknowledgement").IsChecked == true) throw new InvalidOperationException("筛选改变未清除确认。"); }
            else if (state != "ops-confirm")
            {
                var saving = content.SaveAsync();
                if (state == "ops-close-busy")
                {
                    await Task.Delay(80); await content.SaveAsync(); if (repository.Writes != 1) throw new InvalidOperationException("并发重复提交。");
                    await WriteSnapshotAsync(dialog, markComplete: false); page.Dispose(); await opened; await saving;
                    if (!repository.Cancelled) throw new InvalidOperationException("关闭后等待没有取消。"); MarkSnapshotComplete(); return;
                }
                await saving; await content.SaveAsync();
                var expectedWrites = state is "ops-unknown" or "ops-recovered" or "ops-reopen" ? 1 : 3;
                if (repository.Writes != expectedWrites || dialog.IsPrimaryButtonEnabled || !Control<InfoBar>("FeedbackNotice").IsOpen) throw new InvalidOperationException("批次结果或防重复错误。");
                if (state is "ops-unknown" or "ops-recovered" or "ops-reopen")
                {
                    if (state == "ops-recovered") repository.ReviewCompletes = true;
                    if (state == "ops-reopen")
                    { dialog.Hide(); await opened; opened = Show(); await Task.Delay(300); dialog = Dialog(); content = (ContainerMutationDialogContent)dialog.Content; }
                    else await content.ReloadAsync();
                    if (repository.Writes != 1 || content.CanSave || (state != "ops-recovered" && Control<TextBlock>("PendingNotice").Visibility != Visibility.Visible)) throw new InvalidOperationException("核查重放或丢失未确认操作。");
                }
                else if ((Control<InfoBar>("FeedbackNotice").Severity == InfoBarSeverity.Success) == (state == "ops-permission")) throw new InvalidOperationException("部分失败被误报全部成功。");
            }
        }
        await Task.Delay(150); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
        if (state == "ops-loading") page.Dispose(); else dialog.Hide();
        await opened;
        if (state is "ops-start" or "ops-stop" or "ops-restart" or "ops-delete" && repository.Reads < 3) throw new InvalidOperationException("操作后主列表未刷新。");
        MarkSnapshotComplete();
    }

    private static async Task SaveContainerNetworkDeletionAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "netdelete-confirm";
        var repository = new SmokeRepository(); using var page = new ContainerManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(350);
        ((Pivot)page.FindName("SectionPivot")).SelectedIndex = 3;
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var opened = (Task)typeof(ContainerManagerPage).GetMethod("ShowNetworkDeletionAsync", flags)!.Invoke(page, null)!; await Task.Delay(350);
        if (opened.IsCompleted) await opened;
        var dialog = (ContentDialog)typeof(ContainerManagerPage).GetField("_networkDeletionDialog", flags)!.GetValue(page)!;
        var content = (ContainerNetworkDeleteDialogContent)dialog.Content;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        var list = Control<ListView>("TargetsList"); var risk = Control<CheckBox>("RiskAcknowledgement");
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("删除窗口主题或默认按钮错误。");
        if (state == "netdelete-loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("删除加载状态缺失。");
        if (state == "netdelete-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("删除错误状态缺失。");
        if (state == "netdelete-empty" && Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("删除空状态缺失。");
        if (state is not ("netdelete-loading" or "netdelete-error" or "netdelete-empty"))
        {
            if (list.Items.Cast<ContainerResourceSummary>().Any(item => item.Id is "system" or "used")) throw new InvalidOperationException("保护网络进入删除选项。");
            foreach (var item in list.Items.ToArray()) list.SelectedItems.Add(item);
            await content.SaveAsync(); if (repository.NetworkDeleteCalls != 0) throw new InvalidOperationException("未确认即删除。");
            risk.IsChecked = true; await Task.Delay(80);
            if (state == "netdelete-readonly")
            {
                await content.SaveAsync(); if (content.CanSave || repository.NetworkDeleteCalls != 0) throw new InvalidOperationException("只读删除门失效。");
            }
            else if (state is "netdelete-pending" or "netdelete-recovered")
            {
                if (list.Items.Cast<ContainerResourceSummary>().Any(item => item.Id == "delete-a")) throw new InvalidOperationException("待核查或已删除目标可重复删除。");
            }
            else if (state == "netdelete-change")
            {
                list.SelectedItems.RemoveAt(0); await content.SaveAsync();
                if (content.CanSave || risk.IsChecked == true || repository.NetworkDeleteCalls != 0) throw new InvalidOperationException("改变选择沿用旧确认。");
            }
            else if (state == "netdelete-confirm")
            {
                if (!content.CanSave || !dialog.IsPrimaryButtonEnabled || !risk.Focus(FocusState.Keyboard)) throw new InvalidOperationException("有效选择不能确认或聚焦。");
                risk.StartBringIntoView(); await Task.Delay(150);
            }
            else
            {
                var saving = content.SaveAsync();
                if (state == "netdelete-close-busy")
                {
                    await Task.Delay(80); await content.SaveAsync(); if (repository.NetworkDeleteCalls != 1) throw new InvalidOperationException("并发重复删除。");
                    await WriteSnapshotAsync(dialog); page.Dispose(); await opened; await saving;
                    if (!repository.NetworkDeleteCancelled) throw new InvalidOperationException("关闭未取消删除等待。"); return;
                }
                await saving; await content.SaveAsync(); if (repository.NetworkDeleteCalls != 1 || content.CanSave) throw new InvalidOperationException("重复删除。");
                if (!Control<InfoBar>("FeedbackNotice").IsOpen) throw new InvalidOperationException("删除结果缺失。");
                if (state != "netdelete-success" && Control<InfoBar>("FeedbackNotice").Severity == InfoBarSeverity.Success) throw new InvalidOperationException("未确认删除误报成功。");
                if (state == "netdelete-unknown")
                {
                    await content.ReloadAsync(); await content.SaveAsync();
                    if (repository.NetworkDeleteCalls != 1 || list.Items.Count != 0 || Control<TextBlock>("PendingNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("未知结果重放或丢失。");
                }
            }
        }
        await WriteSnapshotAsync(dialog); dialog.Hide(); await opened;
        if (state == "netdelete-success" && ((ListView)page.FindName("NetworksList")).Items.Count != 2) throw new InvalidOperationException("删除后主列表未刷新。");
    }

    private static async Task SaveContainerImageDeletionAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "image-delete-confirm";
        var repository = new SmokeImageDeletionRepository(); using var page = new ContainerManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(350);
        ((Pivot)page.FindName("SectionPivot")).SelectedIndex = 2;
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var opened = (Task)typeof(ContainerManagerPage).GetMethod("ShowImageDeletionAsync", flags)!.Invoke(page, null)!; await Task.Delay(350);
        if (opened.IsCompleted) await opened;
        var dialog = (ContentDialog)typeof(ContainerManagerPage).GetField("_imageDeletionDialog", flags)!.GetValue(page)!;
        var content = (ContainerImageDeleteDialogContent)dialog.Content;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        var list = Control<ListView>("TargetsList"); var risk = Control<CheckBox>("RiskAcknowledgement");
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("删除窗口主题或默认按钮错误。");
        if (state == "image-delete-loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("删除加载状态缺失。");
        if (state == "image-delete-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("删除错误状态缺失。");
        if (state == "image-delete-empty" && Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("删除空状态缺失。");
        if (state is not ("image-delete-loading" or "image-delete-error" or "image-delete-empty"))
        {
            if (list.Items.Cast<ContainerResourceSummary>().Any(item => item.Id == "unknown")) throw new InvalidOperationException("缺少标签的镜像进入删除选项。");
            foreach (var item in list.Items.ToArray()) list.SelectedItems.Add(item);
            await content.SaveAsync(); if (repository.ImageDeleteCalls != 0) throw new InvalidOperationException("未确认即删除。");
            risk.IsChecked = true; await Task.Delay(80);
            if (state == "image-delete-readonly")
            {
                await content.SaveAsync(); if (content.CanSave || repository.ImageDeleteCalls != 0) throw new InvalidOperationException("只读删除门失效。");
            }
            else if (state is "image-delete-pending" or "image-delete-recovered")
            {
                if (list.Items.Cast<ContainerResourceSummary>().Any(item => item.Id == "delete-a")) throw new InvalidOperationException("待核查或已删除目标可重复删除。");
            }
            else if (state == "image-delete-change")
            {
                list.SelectedItems.RemoveAt(0); await content.SaveAsync();
                if (content.CanSave || risk.IsChecked == true || repository.ImageDeleteCalls != 0) throw new InvalidOperationException("改变选择沿用旧确认。");
            }
            else if (state == "image-delete-confirm")
            {
                if (!content.CanSave || !dialog.IsPrimaryButtonEnabled || !risk.Focus(FocusState.Keyboard)) throw new InvalidOperationException("有效选择不能确认或聚焦。");
                risk.StartBringIntoView(); await Task.Delay(150);
            }
            else
            {
                var saving = content.SaveAsync();
                if (state == "image-delete-close-busy")
                {
                    await Task.Delay(80); await content.SaveAsync(); if (repository.ImageDeleteCalls != 1) throw new InvalidOperationException("并发重复删除。");
                    await WriteSnapshotAsync(dialog); page.Dispose(); await opened; await saving;
                    if (!repository.ImageDeleteCancelled) throw new InvalidOperationException("关闭未取消删除等待。"); return;
                }
                await saving; await content.SaveAsync(); if (repository.ImageDeleteCalls != 1 || content.CanSave) throw new InvalidOperationException("重复删除。");
                if (!Control<InfoBar>("FeedbackNotice").IsOpen) throw new InvalidOperationException("删除结果缺失。");
                if (state != "image-delete-success" && Control<InfoBar>("FeedbackNotice").Severity == InfoBarSeverity.Success) throw new InvalidOperationException("未确认删除误报成功。");
                if (state == "image-delete-unknown")
                {
                    await content.ReloadAsync(); await content.SaveAsync();
                    if (repository.ImageDeleteCalls != 1 || list.Items.Count != 0 || Control<TextBlock>("PendingNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("未知结果重放或丢失。");
                    if (Control<InfoBar>("FeedbackNotice").Message != LanStash.App.Localization.LocalizationService.Current.Format("ContainerImageDeleteUnknown", 0, 2))
                        throw new InvalidOperationException("合成恢复结果数量与所选标签不符。");
                }
            }
        }
        await WriteSnapshotAsync(dialog, markComplete: false); if (state == "image-delete-loading") page.Dispose(); else dialog.Hide(); await opened;
        if (state == "image-delete-success" && ((ListView)page.FindName("ImagesList")).Items.Count != 1) throw new InvalidOperationException("删除后主列表未刷新。");
        MarkSnapshotComplete();
    }

    private static async Task SaveContainerImagePullAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "pull-confirm";
        var repository = new SmokeImagePullRepository(); using var page = new ContainerManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(350);
        ((Pivot)page.FindName("SectionPivot")).SelectedIndex = 2;
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        Task Show() => (Task)typeof(ContainerManagerPage).GetMethod("ShowRegistryAsync", flags)!.Invoke(page, null)!;
        ContentDialog Dialog() => (ContentDialog)typeof(ContainerManagerPage).GetField("_registryDialog", flags)!.GetValue(page)!;
        var opened = Show(); await Task.Delay(350); if (opened.IsCompleted) await opened;
        var dialog = Dialog(); var content = (ContainerRegistryDialogContent)dialog.Content;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("下载窗口主题或默认按钮错误。");
        if (state == "pull-read-error")
        { if (!Control<InfoBar>("PullErrorNotice").IsOpen) throw new InvalidOperationException("任务读取错误提示缺失。"); }
        else if (state == "pull-recovery")
        { if (Control<ListView>("PullTasksList").Items.Count != 1 || repository.Starts != 0) throw new InvalidOperationException("恢复任务被重发或缺失。"); }
        else
        {
            Control<TextBox>("QueryInput").Text = "synthetic"; await content.SearchAsync();
            Control<ListView>("ResultsList").SelectedIndex = 0; await Task.Delay(100);
            Control<ListView>("TagsList").SelectedIndex = 0; await Task.Delay(80);
            await content.PullAsync(); if (repository.Starts != 0) throw new InvalidOperationException("下载未确认即提交。");
            Control<CheckBox>("PullConfirmation").IsChecked = true;
            if (state == "pull-readonly")
            { await content.PullAsync(); if (Control<Button>("PullButton").IsEnabled || repository.Starts != 0) throw new InvalidOperationException("下载权限门无效。"); }
            else if (state == "pull-change")
            {
                Control<ListView>("TagsList").SelectedIndex = 1;
                if (Control<CheckBox>("PullConfirmation").IsChecked == true || Control<Button>("PullButton").IsEnabled) throw new InvalidOperationException("标签改变未清除确认。");
            }
            else if (state == "pull-confirm")
            { if (!Control<Button>("PullButton").IsEnabled) throw new InvalidOperationException("有效确认无法开始下载。"); Control<Button>("PullButton").StartBringIntoView(); }
            else
            {
                var starting = content.PullAsync();
                if (state == "pull-close-busy")
                {
                    await Task.Delay(80); await content.PullAsync(); if (repository.Starts != 1) throw new InvalidOperationException("重复启动下载。");
                    await WriteSnapshotAsync(dialog, markComplete: false); page.Dispose(); await opened; await starting;
                    if (!repository.Cancelled) throw new InvalidOperationException("关闭未停止本地等待。"); MarkSnapshotComplete(); return;
                }
                await starting; await content.PullAsync();
                if (repository.Starts != 1 || Control<Button>("PullButton").IsEnabled) throw new InvalidOperationException("重复启动下载或确认未失效。");
                if (state == "pull-ready") { repository.FinishReview = true; await content.ReviewPullsAsync(); }
                if (state == "pull-auto") { await Task.Delay(5400); if (repository.Reviews == 0) throw new InvalidOperationException("可见下载任务没有自动刷新。"); }
                if (state == "pull-reopen")
                {
                    var closedContent = content; var stoppedAtClose = false;
                    dialog.Closed += (_, _) => stoppedAtClose = !((Microsoft.UI.Dispatching.DispatcherQueueTimer)typeof(ContainerRegistryDialogContent)
                        .GetField("_pullTimer", flags)!.GetValue(closedContent)!).IsRunning;
                    dialog.Hide(); await opened;
                    if (!stoppedAtClose) throw new InvalidOperationException("隐藏窗口仍保留任务轮询定时器。");
                    opened = Show(); await Task.Delay(350); dialog = Dialog(); content = (ContainerRegistryDialogContent)dialog.Content;
                }
                var result = ((ContainerImagePullItem)Control<ListView>("PullTasksList").Items.Single()).Result;
                var expected = state switch { "pull-ready" => ContainerImagePullStage.Ready, "pull-no-receipt" => ContainerImagePullStage.AwaitingReceipt,
                    "pull-review" => ContainerImagePullStage.NeedsReview, "pull-rejected" => ContainerImagePullStage.Rejected, _ => ContainerImagePullStage.Downloading };
                if (result.Stage != expected || repository.Starts != 1) throw new InvalidOperationException("下载进度、结果或只读恢复错误。");
            }
        }
        if (Control<ListView>("PullTasksList").Items.Count > 0) content.ShowPullProgress();
        await Task.Delay(150); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
        dialog.Hide(); await opened; MarkSnapshotComplete();
    }

    private static async Task SaveContainerRegistryAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "registry-content";
        var repository = new SmokeRepository(); using var page = new ContainerManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(350);
        ((Pivot)page.FindName("SectionPivot")).SelectedIndex = 2;
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var opened = (Task)typeof(ContainerManagerPage).GetMethod("ShowRegistryAsync", flags)!.Invoke(page, null)!; await Task.Delay(250);
        if (opened.IsCompleted) await opened;
        var dialog = (ContentDialog)typeof(ContainerManagerPage).GetField("_registryDialog", flags)!.GetValue(page)!;
        var content = (ContainerRegistryDialogContent)dialog.Content;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("映像搜索主题或关闭按钮错误。");
        if (state == "registry-initial" && Control<TextBlock>("InitialNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("搜索初始状态缺失。");
        if (state == "registry-unavailable")
        {
            if (Control<TextBlock>("UnavailableNotice").Visibility != Visibility.Visible || Control<Button>("SearchButton").IsEnabled) throw new InvalidOperationException("搜索不支持状态错误。");
        }
        if (state is not ("registry-initial" or "registry-unavailable"))
        {
            Control<TextBox>("QueryInput").Text = "synthetic"; var searching = content.SearchAsync();
            if (state == "registry-loading")
            {
                if (!Control<ProgressRing>("SearchProgress").IsActive) throw new InvalidOperationException("搜索加载状态缺失。");
                await WriteSnapshotAsync(dialog); page.Dispose(); await opened; await searching;
                if (!repository.RegistryCancelled) throw new InvalidOperationException("关闭未取消搜索。"); return;
            }
            await searching;
            if (state == "registry-error" && (!Control<InfoBar>("SearchErrorNotice").IsOpen || Control<TextBlock>("EmptyNotice").Visibility == Visibility.Visible)) throw new InvalidOperationException("搜索失败冒充空列表。");
            if (state == "registry-empty" && Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("搜索空状态缺失。");
            if (state is not ("registry-error" or "registry-empty"))
            {
                var list = Control<ListView>("ResultsList"); if (list.Items.Count != 2) throw new InvalidOperationException("搜索结果缺失。");
                list.SelectedIndex = 0; await Task.Delay(80);
                var tags = Control<ListView>("TagsList");
                if (state == "registry-tags-loading")
                {
                    if (!Control<ProgressRing>("TagsProgress").IsActive) throw new InvalidOperationException("标签加载状态缺失。");
                    await WriteSnapshotAsync(dialog); page.Dispose(); await opened;
                    await Task.Delay(80); if (!repository.RegistryCancelled) throw new InvalidOperationException("关闭未取消标签读取。"); return;
                }
                if (state == "registry-tags-error" && !Control<InfoBar>("TagsErrorNotice").IsOpen) throw new InvalidOperationException("标签错误状态缺失。");
                if (state == "registry-tags-empty" && Control<TextBlock>("TagsEmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("标签空状态缺失。");
                if (state == "registry-switch")
                {
                    list.SelectedIndex = 1; await Task.Delay(450);
                    if (tags.Items.Cast<string>().Any(tag => !tag.StartsWith("worker-", StringComparison.Ordinal))) throw new InvalidOperationException("旧标签覆盖新仓库。");
                }
                if (state is "registry-content" or "registry-filtered" or "registry-select")
                {
                    if (tags.Items.Count != 3) throw new InvalidOperationException("标签未显示。");
                    tags.SelectedIndex = 1; if (!Control<TextBlock>("SelectedReference").Text.Contains("synthetic/image-a:stable", StringComparison.Ordinal)) throw new InvalidOperationException("标签选择未绑定仓库。");
                    if (state == "registry-filtered")
                    {
                        Control<TextBox>("TagFilterInput").Text = "missing";
                        await Task.Delay(80);
                        if (tags.Items.Count != 0) throw new InvalidOperationException("筛选未清空标签列表。");
                        if (Control<TextBlock>("TagsFilteredNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("筛选空状态未显示。");
                        if (Control<TextBlock>("SelectedReference").Text.Length != 0) throw new InvalidOperationException("筛选保留了旧标签选择。");
                    }
                    if (state == "registry-select")
                    { Control<TextBlock>("SelectedReference").StartBringIntoView(); }
                }
            }
        }
        await WriteSnapshotAsync(dialog); dialog.Hide(); await opened;
        if (repository.NetworkCreateCalls != 0 || repository.NetworkDeleteCalls != 0) throw new InvalidOperationException("只读搜索触发写操作。");
    }

    private static async Task SaveVirtualMachineCreationAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE"); var repository = new SmokeRepository();
        using var page = new VirtualMachineManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        if (!((Button)page.FindName("CreateMachineButton")).IsEnabled) throw new InvalidOperationException("缺少创建入口。");
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var showing = (Task)typeof(VirtualMachineManagerPage).GetMethod("ShowCreationAsync", flags)!.Invoke(page, null)!; await Task.Delay(300);
        if (showing.IsCompleted) await showing;
        var dialog = (ContentDialog)typeof(VirtualMachineManagerPage).GetField("_creationDialog", flags)!.GetValue(page)!;
        var content = (VirtualMachineCreationDialogContent)dialog.Content;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("创建默认按钮或主题错误。");
        await content.SubmitAsync(); if (repository.VmCreates != 0) throw new InvalidOperationException("未确认即创建。");
        if (state == "vmcreate-loading" && !Control<ProgressRing>("BusyIndicator").IsActive) throw new InvalidOperationException("未显示创建加载状态。");
        if (state is "vmcreate-empty" or "vmcreate-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("未显示空资源或错误状态。");
        if (state is not ("vmcreate-loading" or "vmcreate-empty" or "vmcreate-error"))
        {
            if (state == "vmcreate-recovery")
            {
                Control<ComboBox>("RecoveryInput").SelectedIndex = 0; await Task.Delay(80);
                if (Control<TextBox>("NameInput").Text != "Pending VM" || Control<TextBox>("NameInput").IsEnabled || content.CanSubmit) throw new InvalidOperationException("恢复没有绑定原配置或复用了旧确认。");
            }
            else
            {
                Control<TextBox>("NameInput").Text = "New synthetic VM"; await Task.Delay(50);
                if (state?.StartsWith("vmcreate-advanced", StringComparison.Ordinal) == true)
                {
                    var system = Control<ComboBox>("OperatingSystemInput");
                    if (state is "vmcreate-advanced-error" or "vmcreate-advanced-frozen")
                    { if (system.IsEnabled || Control<TextBlock>("AdvancedUnavailableNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("高级选项不可用状态缺失。"); }
                    else
                    {
                        if (!system.IsEnabled) throw new InvalidOperationException("已有高级创建能力但选项未开放。");
                        system.SelectedIndex = 2; await Task.Delay(40); Control<ComboBox>("FirmwareInput").SelectedIndex = 1;
                        Control<ComboBox>("BootImageInput").SelectedIndex = 1; await Task.Delay(40);
                        if (Control<StackPanel>("AdvancedFields").Visibility != Visibility.Visible) throw new InvalidOperationException("固件和安装介质未显示。");
                        if (state == "vmcreate-advanced-invalid") ((TextBox)((StackPanel)Control<StackPanel>("DiskRows").Children[0]).Children[1]).Text = "10241";
                    }
                }
                if (state == "vmcreate-form")
                { Invoke(Control<Button>("AddDiskButton")); Invoke(Control<Button>("AddNetworkButton")); await Task.Delay(50); if (Control<StackPanel>("DiskRows").Children.Count != 2 || Control<StackPanel>("NetworkRows").Children.Count != 2) throw new InvalidOperationException("多磁盘/网卡未添加。"); }
                if (state?.StartsWith("vmcreate-image", StringComparison.Ordinal) == true)
                { ((ComboBox)((StackPanel)Control<StackPanel>("DiskRows").Children[0]).Children[0]).SelectedIndex = 1; await Task.Delay(50); }
                if (state == "vmcreate-invalid") Control<TextBox>("CpuInput").Text = "2.5";
            }
            await Task.Delay(50); Control<CheckBox>("RiskAcknowledgement").IsChecked = true;
            if (state == "vmcreate-advanced-fallback")
            {
                repository.VmAdvancedReadFailure = true; await content.RefreshAsync();
                var system = Control<ComboBox>("OperatingSystemInput");
                if (content.CanSubmit || !system.IsEnabled || system.SelectedIndex != 2) throw new InvalidOperationException("高级读取失败后错误提交或锁死模式选择。");
                system.SelectedIndex = 0; await Task.Delay(40); Control<CheckBox>("RiskAcknowledgement").IsChecked = true;
            }
            if (state == "vmcreate-advanced-edit")
            {
                if (!content.CanSubmit) throw new InvalidOperationException("高级配置无法确认。");
                Control<ComboBox>("FirmwareInput").SelectedIndex = 0; await Task.Delay(40);
                if (content.CanSubmit || Control<CheckBox>("RiskAcknowledgement").IsChecked == true) throw new InvalidOperationException("固件变化保留旧确认。");
                Control<CheckBox>("RiskAcknowledgement").IsChecked = true;
                Control<ComboBox>("BootImageInput").SelectedIndex = 0; await Task.Delay(40);
                if (content.CanSubmit) throw new InvalidOperationException("安装介质变化保留旧确认。");
                Control<CheckBox>("RiskAcknowledgement").IsChecked = true;
            }
            if (state?.StartsWith("vmcreate-power-", StringComparison.Ordinal) == true || state is "vmcreate-image-power" or "vmcreate-image-wait" or "vmcreate-image-hardware")
            {
                var power = Control<CheckBox>("PowerOnInput");
                if (state == "vmcreate-power-readonly")
                { if (power.IsEnabled || !content.CanSubmit) throw new InvalidOperationException("缺少电源能力不应阻止普通创建。"); }
                else
                {
                    if (!power.IsEnabled) throw new InvalidOperationException("有能力时开机选项不可用。");
                    power.IsChecked = true;
                    if (content.CanSubmit || Control<CheckBox>("RiskAcknowledgement").IsChecked == true) throw new InvalidOperationException("修改开机选项未撤销确认。");
                    Control<CheckBox>("RiskAcknowledgement").IsChecked = true;
                }
            }
            if (state is "vmcreate-invalid" or "vmcreate-readonly" or "vmcreate-advanced-invalid")
            { if (content.CanSubmit || dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("无效或只读创建被启用。"); }
            else if (state is not ("vmcreate-form" or "vmcreate-confirm" or "vmcreate-power-confirm" or "vmcreate-advanced-form" or "vmcreate-advanced-confirm" or "vmcreate-advanced-edit"))
            {
                if (!content.CanSubmit || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("有效创建确认或原生提交按钮未启用。");
                async Task SubmitFromNativeButtonAsync()
                {
                    static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
                    {
                        for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
                        { var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i); yield return child; foreach (var nested in Descendants(child)) yield return nested; }
                    }
                    var primary = Descendants(dialog).OfType<Button>().Single(button => button.Content is string text && text == content.PrimaryText);
                    if (!primary.IsEnabled) throw new InvalidOperationException("实际原生创建按钮被禁用。");
                    Invoke(primary);
                    for (var i = 0; i < 100 && !Control<InfoBar>("FeedbackNotice").IsOpen; i++) await Task.Delay(20);
                    if (repository.VmCreates != 1 || !Control<InfoBar>("FeedbackNotice").IsOpen) throw new InvalidOperationException("原生按钮没有完成创建操作接线。");
                }
                var sending = state == "vmcreate-advanced-ui-submit" ? SubmitFromNativeButtonAsync() : content.SubmitAsync();
                if (state is "vmcreate-close-busy" or "vmcreate-advanced-close-busy")
                { await Task.Delay(70); await content.SubmitAsync(); if (repository.VmCreates != 1) throw new InvalidOperationException("创建被重复提交。"); await WriteSnapshotAsync(dialog, markComplete: false); page.Dispose(); await showing; await sending; if (!repository.VmCreationCancelled) throw new InvalidOperationException("关闭未取消本地等待。"); MarkSnapshotComplete(); return; }
                await sending; await content.SubmitAsync();
                if (state?.StartsWith("vmcreate-image", StringComparison.Ordinal) == true)
                {
                    if (repository.VmCreationRequest?.Disks.Single().Image is not { Type: "disk" }) throw new InvalidOperationException("选定映像未进入创建请求。");
                    if (state is "vmcreate-image" or "vmcreate-image-power" && !Control<InfoBar>("FeedbackNotice").Message.Contains(LanStash.App.Localization.LocalizationService.Current.Get(state == "vmcreate-image-power" ? "VmCreatePoweredOn" : "VmCreateCompleted"), StringComparison.Ordinal))
                        throw new InvalidOperationException("完成的克隆仍停在来源待核查。");
                }
                if (state is "vmcreate-advanced-success" or "vmcreate-advanced-unknown" or "vmcreate-advanced-ui-submit")
                {
                    var advanced = repository.VmCreationRequest?.Advanced;
                    if (advanced is not { OperatingSystem: VirtualMachineOperatingSystem.Linux, Firmware: VirtualMachineFirmware.Uefi, BootImage.Id: "iso-a" }) throw new InvalidOperationException("高级配置没有进入已确认请求。");
                }
                if (state?.StartsWith("vmcreate-power-", StringComparison.Ordinal) == true && repository.VmCreationPowerRequested != (state != "vmcreate-power-readonly")) throw new InvalidOperationException("开机选项未绑定创建请求。");
                if (state is "vmcreate-wait" or "vmcreate-power-wait" or "vmcreate-image-wait")
                { await Task.Delay(2200); if (repository.VmCreationReviews < 1 || repository.VmContinues != 0 || content.CanSubmit) throw new InvalidOperationException("自动核查发生写入或沿用确认。"); Control<CheckBox>("RiskAcknowledgement").IsChecked = true; await content.SubmitAsync(); if (repository.VmContinues != 1) throw new InvalidOperationException("确认后不能继续配置。"); }
                if (state is "vmcreate-unknown" or "vmcreate-advanced-unknown" or "vmcreate-image-unknown" or "vmcreate-image-hardware") { await content.RefreshAsync(); if (repository.VmCreates != 1 || content.CanSubmit || repository.VmContinues != 0) throw new InvalidOperationException("未知创建被重放。"); }
                if (state == "vmcreate-power-unknown") { await content.RefreshAsync(); if (repository.VmCreates != 1 || repository.VmContinues != 0 || content.CanSubmit) throw new InvalidOperationException("未知开机被继续或重放。"); }
                if (!Control<InfoBar>("FeedbackNotice").IsOpen) throw new InvalidOperationException("缺少创建结果反馈。");
            }
        }
        if (state is "vmcreate-confirm" or "vmcreate-power-confirm" or "vmcreate-advanced-confirm")
        {
            var scroll = Control<ScrollViewer>("FormScroll"); scroll.UpdateLayout(); scroll.ChangeView(null, scroll.ScrollableHeight, null, true); await Task.Delay(80);
            var confirmation = Control<CheckBox>("RiskAcknowledgement");
            confirmation.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false, VerticalAlignmentRatio = 1 }); await Task.Delay(80);
            if (confirmation.TransformToVisual(scroll).TransformPoint(new(0, 0)).Y + confirmation.ActualHeight > scroll.ActualHeight + 1)
                throw new InvalidOperationException("确认框未完整进入可滚动视口。");
            if (!content.CanSubmit || !Control<TextBlock>("ConfirmationSummary").Text.Contains("New synthetic VM", StringComparison.Ordinal)) throw new InvalidOperationException("确认摘要没有绑定当前配置。");
            if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("确认通过但原生创建按钮仍禁用。");
            if (state == "vmcreate-advanced-confirm" && (!Control<TextBlock>("ConfirmationSummary").Text.Contains("UEFI", StringComparison.Ordinal) ||
                !Control<TextBlock>("ConfirmationSummary").Text.Contains("Demo installation ISO", StringComparison.Ordinal) || Control<TextBlock>("ConfirmationSummary").Text.Contains("VmCreate", StringComparison.Ordinal)))
                throw new InvalidOperationException("高级确认摘要缺少选定值或泄漏资源键。");
        }
        await WriteSnapshotAsync(dialog, markComplete: false); dialog.Hide(); await showing; MarkSnapshotComplete();
    }

    private static async Task SaveVirtualMachineTaskCleanupAsync(FrameworkElement root)
    {
        static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
        {
            for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
            { var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i); yield return child; foreach (var nested in Descendants(child)) yield return nested; }
        }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
            .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "taskclear-success";
        var repository = new SmokeVmTaskCleanupRepository(state); using var page = new VirtualMachineManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(200);
        ((Pivot)page.FindName("ResourcePivot")).SelectedItem = page.FindName("TasksTab"); await Task.Delay(250);
        var pane = (VirtualMachineTasksControl)page.FindName("TasksPane");
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (VirtualMachineTasksViewModel)typeof(VirtualMachineTasksControl).GetField("_model", flags)!.GetValue(pane)!;
        if (state is "taskclear-readonly" or "taskclear-protected")
        {
            if (model.CanPrepareCleanup || ((Button)pane.FindName("ClearButton")).IsEnabled) throw new InvalidOperationException("不可清理任务仍可确认。");
            await model.SubmitCleanupAsync(); if (repository.Writes != 0) throw new InvalidOperationException("无确认清理。");
            await WriteSnapshotAsync(page); return;
        }
        var showing = (Task)typeof(VirtualMachineTasksControl).GetMethod("ShowCleanupAsync", flags)!.Invoke(pane, null)!;
        await Task.Delay(180);
        var dialog = (ContentDialog)typeof(VirtualMachineTasksControl).GetField("_cleanupDialog", flags)!.GetValue(pane)!;
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme || repository.Writes != 0) throw new InvalidOperationException("确认之前提交或窗口状态错误。");
        if (state != "taskclear-form")
        {
            if (state == "taskclear-added") repository.Tasks.Add(new("later", VirtualMachineTaskState.Finished, 100));
            Invoke(Descendants(dialog).OfType<Button>().Single(item => item.Name == "PrimaryButton")); await Task.Delay(120);
            if (state == "taskclear-close")
            {
                if (!model.IsCleaning) throw new InvalidOperationException("未进入清理等待。");
                await WriteSnapshotAsync(dialog, markComplete: false); dialog.Hide(); await showing;
                repository.Completion.SetResult(new(2, 0, 0, 1, 1)); await Task.Delay(220);
                if (!repository.Token.IsCancellationRequested || model.LastCleanup is not null || !model.CanReviewCleanup) throw new InvalidOperationException("关闭后迟到结果或恢复入口错误。");
                MarkSnapshotComplete(); return;
            }
            await model.SubmitCleanupAsync();
            if (repository.Writes != 1 || repository.Last?.Keys.Count != (state == "taskclear-large" ? 205 : 2)) throw new InvalidOperationException("清理范围截断或重复提交。");
            if (state == "taskclear-added" && !repository.Tasks.Any(item => item.Key == "later")) throw new InvalidOperationException("新增任务被扩入确认范围。");
            if (state == "taskclear-changed" && model.LastCleanup?.NotStartedCount != 2) throw new InvalidOperationException("变化目标没有阻止清理。");
            if (state == "taskclear-review")
            {
                dialog.Hide(); await showing;
                var reviewButton = (Button)pane.FindName("ReviewClearButton");
                for (var index = 0; index < 100 && (!reviewButton.IsEnabled || reviewButton.Visibility != Visibility.Visible); index++) await Task.Delay(10);
                if (!model.CanReviewCleanup || !reviewButton.IsEnabled) throw new InvalidOperationException("清理完成后未出现可用核对入口。");
                repository.Resolve = true; Invoke(reviewButton); await Task.Delay(180);
                if (repository.Writes != 1 || repository.Reviews != 1 || model.LastCleanup?.ClearedCount != 1 || model.LastCleanup.NotStartedCount != 1)
                    throw new InvalidOperationException("核对重放或继续了未执行项。");
                await WriteSnapshotAsync(page); return;
            }
        }
        await Task.Delay(100); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
        dialog.Hide(); await showing; MarkSnapshotComplete();
    }

    private static async Task SaveVirtualMachineTasksAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE"); var repository = new SmokeRepository();
        using var page = new VirtualMachineManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        if (repository.VmTaskReads != 0) throw new InvalidOperationException("任务页尚未显示即开始读取。");
        var pivot = (Pivot)page.FindName("ResourcePivot"); pivot.SelectedItem = page.FindName("TasksTab"); await Task.Delay(450);
        var pane = (VirtualMachineTasksControl)page.FindName("TasksPane");
        T Control<T>(string name) where T : FrameworkElement => (T)pane.FindName(name);
        if (state == "vmtasks-unavailable" && (Control<TextBlock>("UnavailableState").Visibility != Visibility.Visible || repository.VmTaskReads != 0)) throw new InvalidOperationException("缺少不可用状态或越过能力门。");
        if (state == "vmtasks-empty" && Control<TextBlock>("EmptyState").Visibility != Visibility.Visible) throw new InvalidOperationException("未显示任务为空。");
        if (state == "vmtasks-error" && Control<TextBlock>("ErrorState").Visibility != Visibility.Visible) throw new InvalidOperationException("未显示读取错误。");
        if (state is "vmtasks-loading" or "vmtasks-hide" && !Control<ProgressRing>("LoadingState").IsActive) throw new InvalidOperationException("未显示加载状态。");
        if (state == "vmtasks-refresh-error")
        { await pane.RefreshAsync(); await Task.Delay(50); if (Control<ListView>("TaskList").Items.Count != 3 || !Control<InfoBar>("RefreshError").IsOpen) throw new InvalidOperationException("刷新失败丢弃已有任务。"); }
        if (state == "vmtasks-poll")
        { await Task.Delay(2200); if (repository.VmTaskReads != 2 || Control<ListView>("TaskList").Items.Count != 1) throw new InvalidOperationException("任务轮询未更新终态。"); }
        await WriteSnapshotAsync(root, markComplete: false);
        pivot.SelectedIndex = 0; await Task.Delay(60);
        if (state is "vmtasks-loading" or "vmtasks-hide" && !repository.VmTaskReadCancelled) throw new InvalidOperationException("离页未取消读取。");
        var count = repository.VmTaskReads; if (state is "vmtasks-poll" or "vmtasks-finished" or "vmtasks-hide") { await Task.Delay(2100); if (repository.VmTaskReads != count) throw new InvalidOperationException("离页后仍在轮询。"); }
        MarkSnapshotComplete();
    }

    private static async Task SaveVirtualMachineImageImportAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE");
        var repository = new SmokeRepository(); using var page = new VirtualMachineManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        if (!((Button)page.FindName("ImportImageButton")).IsEnabled) throw new InvalidOperationException("导入管理入口未启用。");
        var showing = (Task)typeof(VirtualMachineManagerPage).GetMethod("ShowImageImportAsync", flags)!.Invoke(page, null)!; await Task.Delay(250);
        if (showing.IsCompleted) await showing;
        var dialog = (ContentDialog)typeof(VirtualMachineManagerPage).GetField("_imageImportDialog", flags)!.GetValue(page)!;
        var content = (VirtualMachineImageImportDialogContent)dialog.Content;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("导入窗口主题或默认动作错误。");
        await content.SubmitAsync(); if (repository.VmImageImports != 0) throw new InvalidOperationException("未经确认即导入。");
        if (state == "vmimport-loading")
        { if (!Control<ProgressRing>("BusyIndicator").IsActive) throw new InvalidOperationException("缺少加载状态。"); await WriteSnapshotAsync(dialog, markComplete: false); page.Dispose(); await showing; for (var i = 0; i < 50 && !repository.VmImageImportCancelled; i++) await Task.Delay(20); if (!repository.VmImageImportCancelled) throw new InvalidOperationException("关闭未取消读取。"); MarkSnapshotComplete(); return; }
        if (state is "vmimport-error" or "vmimport-empty")
        { if (!Control<InfoBar>("ErrorNotice").IsOpen || content.CanSubmit) throw new InvalidOperationException("空存储或错误未阻止导入。"); }
        else if (state == "vmimport-recovery")
        { Control<ComboBox>("RecoveryInput").SelectedIndex = 0; await Task.Delay(100); if (repository.VmImageImports != 0 || repository.VmImageImportReviews != 1) throw new InvalidOperationException("恢复入口不是只读核查。"); }
        else
        {
            Control<TextBox>("NameInput").Text = "Synthetic image"; Control<TextBox>("PathInput").Text = "/share/example.iso";
            Control<ComboBox>("TypeInput").SelectedIndex = 1; var storage = Control<ListView>("StorageInput");
            foreach (var item in storage.Items) storage.SelectedItems.Add(item); await Task.Delay(50);
            var confirm = Control<CheckBox>("RiskAcknowledgement"); confirm.IsChecked = true;
            if (state == "vmimport-readonly") { if (confirm.IsEnabled || content.CanSubmit) throw new InvalidOperationException("只读连接可导入。"); }
            else
            {
                if (!content.CanSubmit) throw new InvalidOperationException("完整确认后未开放导入。");
                if (state == "vmimport-edit")
                { Control<TextBox>("PathInput").Text = "/share/changed.iso"; if (content.CanSubmit || confirm.IsChecked == true) throw new InvalidOperationException("来源变化保留了旧确认。"); }
                else if (state != "vmimport-form")
                {
                    var submitting = content.SubmitAsync();
                    if (state == "vmimport-close-busy")
                    { await Task.Delay(100); await content.SubmitAsync(); if (repository.VmImageImports != 1) throw new InvalidOperationException("重复导入。"); await WriteSnapshotAsync(dialog, markComplete: false); page.Dispose(); await showing; await submitting; if (!repository.VmImageImportCancelled) throw new InvalidOperationException("关闭未取消本地等待。"); MarkSnapshotComplete(); return; }
                    await submitting; await content.SubmitAsync();
                    if (repository.VmImageImports != 1 || content.CanSubmit || !Control<InfoBar>("FeedbackNotice").IsOpen) throw new InvalidOperationException("提交反馈或防重错误。");
                    if (state is "vmimport-review" or "vmimport-unknown")
                    { await content.RefreshAsync(); if (repository.VmImageImports != 1 || repository.VmImageImportReviews != 1) throw new InvalidOperationException("核查重复提交导入。"); }
                    if (state == "vmimport-auth" && content.CanRefresh) throw new InvalidOperationException("认证失效仍自动核查。");
                }
            }
        }
        await WriteSnapshotAsync(dialog, markComplete: false); dialog.Hide(); await showing; MarkSnapshotComplete();
    }

    private static async Task SaveVirtualMachineConsoleAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "vmconsole-ready";
        var repository = new SmokeRepository(); using var page = new VirtualMachineManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(250);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (LanStash.App.Features.VirtualMachines.VirtualMachineManagerViewModel)typeof(VirtualMachineManagerPage).GetField("_viewModel", flags)!.GetValue(page)!;
        model.SelectMachine(model.Machines.First()); await Task.Delay(100);
        var button = (Button)page.FindName("ConsoleButton");
        if (state is "vmconsole-unavailable" or "vmconsole-stopped")
        { if (button.IsEnabled || repository.VmConsoleOpens != 0) throw new InvalidOperationException("无能力或关机时控制台仍可启动。"); await WriteSnapshotAsync(page); return; }
        if (!button.IsEnabled) throw new InvalidOperationException("运行中控制台入口不可用。");
        Task Open() => (Task)typeof(VirtualMachineManagerPage).GetMethod("ShowConsoleAsync", flags)!.Invoke(page, null)!;
        VirtualMachineConsoleWindow Window() => (VirtualMachineConsoleWindow)typeof(VirtualMachineManagerPage).GetField("_consoleWindow", flags)!.GetValue(page)!;
        static async Task Until(Func<bool> predicate) { for (var i = 0; i < 150 && !predicate(); i++) await Task.Delay(80); if (!predicate()) throw new InvalidOperationException("控制台状态等待超时。"); }
        var opening = Open(); await Until(() => Window() is not null); var window = Window();
        if (state == "vmconsole-loading")
        { await Task.Delay(150); if (!window.SmokeLoading) throw new InvalidOperationException("缺少会话加载反馈。"); await WriteSnapshotAsync(window.SmokeRoot, false); page.Dispose(); await opening; if (!repository.VmConsoleCancelled) throw new InvalidOperationException("关闭未取消会话准备。"); MarkSnapshotComplete(); return; }
        await opening;
        if (state == "vmconsole-error")
        { if (!window.SmokeHasError || window.SmokeCore is not null) throw new InvalidOperationException("失败后仍创建浏览会话。"); await WriteSnapshotAsync(window.SmokeRoot, false); window.Close(); MarkSnapshotComplete(); return; }
        if (state == "vmconsole-managed-locale-error")
        {
            await Until(() => window.SmokeHasError);
            if (window.SmokeCore is not null || repository.VmConsoleSocketOpens != 0) throw new InvalidOperationException("语言失败后仍保留浏览器或连接。");
            await WriteSnapshotAsync(window.SmokeRoot, false); var failedProfile = window.SmokeProfilePath!; window.Close(); await Until(() => !Directory.Exists(failedProfile)); MarkSnapshotComplete(); return;
        }
        await Until(() => window.SmokeHasError || repository.VmConsoleDocumentReads > 0);
        if (window.SmokeHasError || window.SmokeCore is not { } core) throw new InvalidOperationException("真实 WebView2 组件未成功加载。");
        var profile = window.SmokeProfilePath!;
        var managed = repository.VmConsoleSession!.UsesManagedTransport;
        if (!core.Profile.IsInPrivateModeEnabled || core.Profile.IsPasswordAutosaveEnabled || core.Profile.IsGeneralAutofillEnabled || core.Settings.AreHostObjectsAllowed || core.Settings.IsWebMessageEnabled != managed || core.Settings.AreDevToolsEnabled)
            throw new InvalidOperationException("临时浏览会话隔离选项未生效。");
        var cookies = await core.CookieManager.GetCookiesAsync(repository.VmConsoleSession!.Policy.NavigationUri.AbsoluteUri);
        if (managed && cookies.Count != 0) throw new InvalidOperationException("托管控制台向网页释放了 Cookie。");
        var cookie = managed ? null : cookies.Single(item => item.Name == "id");
        if (!managed && (cookie!.Value != "synthetic-console-cookie" || !cookie.IsHttpOnly || !cookie.IsSecure || !cookie.IsSession || cookie.SameSite != Microsoft.Web.WebView2.Core.CoreWebView2CookieSameSiteKind.Strict))
            throw new InvalidOperationException("控制台 Cookie 边界不正确。");
        if (state == "vmconsole-close-document")
        { await WriteSnapshotAsync(window.SmokeRoot, false); page.Dispose(); await Until(() => repository.VmConsoleCancelled && !Directory.Exists(profile)); MarkSnapshotComplete(); return; }
        await Until(() => window.SmokeHasError || !window.SmokeLoading);
        if (window.SmokeHasError || await core.ExecuteScriptAsync("window.fixtureReady === true") != "true") throw new InvalidOperationException("合成控制台页面未实际显示。");
        if (managed)
        {
            if (state == "vmconsole-managed-close-locale")
            { await Until(() => repository.VmConsoleAssetReads == 2); await WriteSnapshotAsync(window.SmokeRoot, false); window.Close(); await Until(() => repository.VmConsoleCancelled && !Directory.Exists(profile)); if (repository.VmConsoleSocketOpens != 0) throw new InvalidOperationException("关闭语言读取时仍打开连接。"); MarkSnapshotComplete(); return; }
            try { await Until(() => repository.VmConsoleSocketOpens == 1); }
            catch (InvalidOperationException error)
            {
                var detail = await core.ExecuteScriptAsync("JSON.stringify({socket:WebSocket.name,state:window.consoleSocket?.readyState,errors:window.fixtureErrors})");
                throw new InvalidOperationException($"合成控制台连接未开始；资源读取 {repository.VmConsoleAssetReads}，脚本状态 {detail}", error);
            }
            if (repository.VmConsoleAssetReads != 2 || await core.ExecuteScriptAsync("window.consoleLocaleReady === true") != "true") throw new InvalidOperationException("托管静态脚本或语言 XHR 未加载。");
            if (state == "vmconsole-managed-close")
            { await WriteSnapshotAsync(window.SmokeRoot, false); window.Close(); await Until(() => repository.VmConsoleCancelled && !Directory.Exists(profile)); MarkSnapshotComplete(); return; }
            for (var i = 0; i < 100 && await core.ExecuteScriptAsync("window.consoleEcho === '1,2,255'") != "true"; i++) await Task.Delay(50);
            if (await core.ExecuteScriptAsync("window.consoleEcho === '1,2,255' && consoleSocket.readyState === WebSocket.OPEN") != "true") throw new InvalidOperationException("网页与原生二进制消息桥未实际往返。");
            await core.ExecuteScriptAsync("window.foreignBlocked=false;window.otherWindowBlocked=false;try{new WebSocket('wss://blocked.invalid/socket')}catch{foreignBlocked=true};try{new WebSocket(consoleSocket.url.replace(/app_id=[^&]+/,'app_id=other-window'))}catch{otherWindowBlocked=true};fetch(location.origin+'/api').catch(()=>{});var forbiddenLocale=new XMLHttpRequest();forbiddenLocale.open('GET','app/locale/config.json');forbiddenLocale.onload=()=>window.blockedLocaleStatus=forbiddenLocale.status;forbiddenLocale.send();chrome.webview.postMessage({context:'wrong',id:99,kind:'open'});");
            await Task.Delay(150);
            if (await core.ExecuteScriptAsync("foreignBlocked && otherWindowBlocked && blockedLocaleStatus === 403 && violations.includes('connect-src') && document.cookie === ''") != "true" || repository.VmConsoleSocketOpens != 1 || repository.VmConsoleAssetReads != 2)
                throw new InvalidOperationException("托管控制台连接隔离未生效。");
            if (state == "vmconsole-managed-reconnect")
            {
                await core.ExecuteScriptAsync("consoleSocket.close()");
                for (var i = 0; i < 100 && await core.ExecuteScriptAsync("consoleSocket.readyState === WebSocket.CLOSED") != "true"; i++) await Task.Delay(50);
                if (await core.ExecuteScriptAsync("consoleSocket.readyState === WebSocket.CLOSED") != "true" || !repository.VmConsoleSocketDisposed) throw new InvalidOperationException("重连前未关闭旧连接。");
                var endpoint = System.Text.Json.JsonSerializer.Serialize(repository.VmConsoleSession.Policy.SocketUri!.AbsoluteUri);
                await core.ExecuteScriptAsync("window.consoleEcho='';window.consoleSocket=new WebSocket(" + endpoint + ",['binary']);consoleSocket.binaryType='arraybuffer';consoleSocket.onopen=()=>consoleSocket.send(new Uint8Array([9,8]));consoleSocket.onmessage=e=>consoleEcho=Array.from(new Uint8Array(e.data)).join(',')");
                for (var i = 0; i < 100 && await core.ExecuteScriptAsync("consoleEcho === '9,8'") != "true"; i++) await Task.Delay(50);
                if (repository.VmConsoleSocketOpens != 2 || await core.ExecuteScriptAsync("consoleEcho === '9,8'") != "true") throw new InvalidOperationException("托管控制台未能重新连接。");
            }
        }
        if (state == "vmconsole-policy")
        {
            await core.ExecuteScriptAsync("try{new WebSocket('wss://blocked.invalid/socket')}catch{};fetch('https://blocked.invalid/api').catch(()=>{});var img=new Image();img.src='https://console.invalid:5001/image';document.body.append(img);try{new Worker('https://console.invalid:5001/worker.js')}catch{}");
            await Task.Delay(250);
            if (await core.ExecuteScriptAsync("['connect-src','img-src','worker-src'].every(x=>violations.includes(x))") != "true") throw new InvalidOperationException("浏览器没有执行服务器和应用两层 CSP。");
            if (await core.ExecuteScriptAsync("window.open('https://blocked.invalid/') === null") != "true") throw new InvalidOperationException("弹窗未被阻止。");
        }
        if (state == "vmconsole-fullscreen")
        { window.SmokeToggleFullscreen(); await Task.Delay(100); if (!window.SmokeIsFullscreen) throw new InvalidOperationException("未进入原生全屏。");
          window.SmokeToggleFullscreen(); if (window.SmokeIsFullscreen) throw new InvalidOperationException("未退出原生全屏。"); }
        if (state == "vmconsole-navigate")
        { core.Navigate("https://blocked.invalid/"); await Until(() => window.SmokeHasError); if (window.SmokeCore is not null) throw new InvalidOperationException("外部导航后会话未释放。"); }
        else
        {
            using var preview = new MemoryStream(); using var native = preview.AsRandomAccessStream();
            await core.CapturePreviewAsync(Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat.Png, native);
            await File.WriteAllBytesAsync(Path.Combine(AppContext.BaseDirectory, "workspace-console-page.png"), preview.ToArray());
        }
        await WriteSnapshotAsync(window.SmokeRoot, false); var document = repository.VmConsoleDocument!;
        window.Close(); await Until(() => !Directory.Exists(profile));
        if (managed && !repository.VmConsoleSocketDisposed) throw new InvalidOperationException("关闭窗口未释放托管控制台连接。");
        if (document.Content.Any(value => value != 0)) throw new InvalidOperationException("关闭后仍保留控制台正文。");
        if (state == "vmconsole-reopen")
        {
            await Open(); var next = Window(); await Until(() => next.SmokeHasError || repository.VmConsoleDocumentReads == 2 && !next.SmokeLoading);
            if (next.SmokeHasError || next.SmokeProfilePath == profile || repository.VmConsoleOpens != 2) throw new InvalidOperationException("重开没有创建独立会话。");
            var nextProfile = next.SmokeProfilePath!; next.Close(); await Until(() => !Directory.Exists(nextProfile));
        }
        MarkSnapshotComplete();
    }

    private static async Task SaveVirtualMachineSettingsAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = VmSettingsScenario(); var repository = new SmokeRepository();
        var model = new LanStash.App.Features.VirtualMachines.VirtualMachineManagerViewModel();
        using var page = new VirtualMachineManagerPage(repository, model);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300); model.SelectMachine(model.Machines[0]);
        await Task.Delay(50);
        if (!((Button)page.FindName("EditSettingsButton")).IsEnabled) throw new InvalidOperationException("未启用设置读取入口。");
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var showing = (Task)typeof(VirtualMachineManagerPage).GetMethod("ShowSettingsAsync", flags)!.Invoke(page, null)!; await Task.Delay(300);
        if (showing.IsCompleted) await showing;
        var dialog = (ContentDialog)typeof(VirtualMachineManagerPage).GetField("_settingsDialog", flags)!.GetValue(page)!;
        var content = (VirtualMachineSettingsDialogContent)dialog.Content;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("编辑窗口默认按钮或主题错误。");
        await content.SaveAsync(); if (repository.VmSettingsCalls != 0) throw new InvalidOperationException("未确认即保存。");
        if (state == "vmsettings-loading" && !Control<ProgressRing>("BusyIndicator").IsActive) throw new InvalidOperationException("未显示加载状态。");
        if (state == "vmsettings-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("未显示错误状态。");
        if (state is not ("vmsettings-loading" or "vmsettings-error"))
        {
            if (Control<ComboBox>("StartupInput").SelectedIndex != 1) throw new InvalidOperationException("三态启动原值错误。");
            if (state == "vmsettings-running" && Control<TextBox>("CpuInput").IsEnabled) throw new InvalidOperationException("运行中允许硬件修改。");
            Control<TextBox>("NameInput").Text = "Renamed VM";
            Control<TextBox>("DescriptionInput").Text = "Updated description"; await Task.Delay(50);
            if (state == "vmsettings-invalid") Control<TextBox>("MemoryInput").Text = "2.5";
            await Task.Delay(50); Control<CheckBox>("RiskAcknowledgement").IsChecked = true;
            if (state.StartsWith("vmsettings-priority-", StringComparison.Ordinal))
            {
                var priority = Control<ComboBox>("PriorityInput");
                if (state == "vmsettings-priority-readonly")
                { if (priority.IsEnabled || !content.CanSave) throw new InvalidOperationException("优先级只读不应阻断基础保存。"); }
                else
                {
                    if (!priority.IsEnabled || priority.Items.Count != (state == "vmsettings-priority-custom" ? 6 : 5)) throw new InvalidOperationException("优先级档位或能力不正确。");
                    priority.SelectedIndex = priority.Items.Count - 1;
                    if (content.CanSave || Control<CheckBox>("RiskAcknowledgement").IsChecked == true) throw new InvalidOperationException("修改优先级没有撤销旧确认。");
                    Control<CheckBox>("RiskAcknowledgement").IsChecked = true;
                    if (state == "vmsettings-priority-running" && Control<TextBox>("CpuInput").IsEnabled) throw new InvalidOperationException("优先级编辑不应解锁运行中硬件。");
                }
            }
            if (state is "vmsettings-readonly" or "vmsettings-invalid")
            { if (content.CanSave || dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("无效或只读设置允许保存。"); }
            else if (state == "vmsettings-priority-form")
            { if (!content.CanSave) throw new InvalidOperationException("优先级修改无法确认。"); }
            else
            {
                if (!content.CanSave || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("有效修改无法保存。");
                await content.SaveAsync(); await content.SaveAsync();
                if (repository.VmSettingsCalls != 1 || !Control<InfoBar>("FeedbackNotice").IsOpen) throw new InvalidOperationException("重复保存或缺少反馈。");
                if (state.StartsWith("vmsettings-priority-", StringComparison.Ordinal) && repository.VmLastSettingsRequest?.Desired.CpuWeight != (state == "vmsettings-priority-readonly" ? 256 : 1024)) throw new InvalidOperationException("优先级未绑定已确认请求。");
                if (state is "vmsettings-partial" or "vmsettings-priority-unknown")
                { await content.ReloadAsync(); if (Control<TextBox>("NameInput").IsEnabled || Control<InfoBar>("FeedbackNotice").Severity == InfoBarSeverity.Success || repository.VmSettingsCalls != 1) throw new InvalidOperationException("部分保存被重放或误报成功。"); }
                else if (Control<TextBox>("NameInput").Text != "Renamed VM" || content.CanSave || !content.CanReload || !dialog.IsSecondaryButtonEnabled) throw new InvalidOperationException("保存后没有读取当前设置或不能再次核查。");
            }
        }
        if (state.StartsWith("vmsettings-priority-", StringComparison.Ordinal))
        { Control<CheckBox>("RiskAcknowledgement").StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false, VerticalAlignmentRatio = 1 }); await Task.Delay(100); }
        await WriteSnapshotAsync(dialog); dialog.Hide(); await showing;
        static string VmSettingsScenario() => Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "vmsettings-save";
    }

    private static async Task SaveVirtualMachinePowerBatchAsync(FrameworkElement root, bool deletion = false, bool images = false)
    {
        static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
        {
            for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); index++)
            {
                var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, index); yield return child;
                foreach (var nested in Descendants(child)) yield return nested;
            }
        }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
            .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "vmbatch-on";
        if (images) state = state.Replace("vmimage-", "vmbatch-", StringComparison.Ordinal);
        else if (deletion) state = state.Replace("vmdelete-", "vmbatch-", StringComparison.Ordinal);
        var repository = new SmokeVmPowerBatchRepository(state, deletion, images);
        int Count() => images ? repository.ImageDeletes.Count : deletion ? repository.Deletes.Count : repository.Calls.Count;
        if (state == "vmbatch-review")
        { if (images) repository.ImagePending.Add(new(repository.Images[0].Id, repository.Images[0].Name));
          else if (deletion) repository.DeletionPending.Add(new(repository.Machines[0].Id, repository.Machines[0].Name));
          else repository.Pending.Add(new(repository.Machines[0].Id, repository.Machines[0].Name, VirtualMachinePowerAction.PowerOff)); }
        using var parent = new VirtualMachineManagerViewModel(); using var page = new VirtualMachineManagerPage(repository, parent);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(250);
        if (images) { ((Pivot)page.FindName("ResourcePivot")).SelectedItem = page.FindName("ImagesTab"); await Task.Delay(60); }
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var showing = (Task)typeof(VirtualMachineManagerPage).GetMethod("ShowMachineBatchAsync", flags)!.Invoke(page, [deletion, images])!;
        await Task.Delay(200); if (showing.IsCompleted) await showing;
        var dialog = (ContentDialog)typeof(VirtualMachineManagerPage).GetField("_machineBatchDialog", flags)!.GetValue(page)!;
        var model = (VirtualMachineBatchViewModel)typeof(VirtualMachineManagerPage).GetField("_machineBatchModel", flags)!.GetValue(page)!;
        T Control<T>(string name) where T : FrameworkElement => Descendants(dialog).OfType<T>().Single(item => item.Name == name);
        if (dialog.ActualTheme != root.ActualTheme || dialog.DefaultButton != ContentDialogButton.Close) throw new InvalidOperationException("批次窗口主题/默认按钮错误。");
        var action = state.Contains("shutdown", StringComparison.Ordinal) ? VirtualMachinePowerAction.Shutdown : state.Contains("off", StringComparison.Ordinal) ? VirtualMachinePowerAction.PowerOff : VirtualMachinePowerAction.PowerOn;
        if (!deletion) Control<ComboBox>("VmBatchAction").SelectedIndex = (int)action; await Task.Delay(60);
        if (state == "vmbatch-review")
        {
            repository.Resolve = true; Invoke(Control<Button>("SecondaryButton")); await Task.Delay(120);
            if (repository.Reads != 1 || Count() != 0 || model.Reviews.Single().Target.Action != (images ? VirtualMachineBatchAction.DeleteImage : deletion ? VirtualMachineBatchAction.Delete : VirtualMachineBatchAction.PowerOff))
                throw new InvalidOperationException("已有待核对项被改成新动作或被重发。");
        }
        else if (state == "vmbatch-running")
        { if (Control<ListView>("VmBatchSelection").Items.Count != 0 || model.CanConfirm) throw new InvalidOperationException("运行中虚拟机可被选择删除。"); }
        else if (state == "vmbatch-empty")
        {
            if (model.CanConfirm || model.MessageKey != (images ? "VmImageDeleteEmpty" : deletion ? "VmDeleteNoEligible" : "VmBatchEmpty")) throw new InvalidOperationException("空状态可提交。");
        }
        else
        {
            var list = Control<ListView>("VmBatchSelection"); list.SelectAll(); await Task.Delay(60);
            if (model.SelectedCount != 205) throw new InvalidOperationException("批次选择被截断。");
            await model.SubmitAsync(); if (Count() != 0) throw new InvalidOperationException("没有确认就执行了电源操作。");
            if (state == "vmbatch-readonly")
            { model.Confirm(true); await model.SubmitAsync(); if (model.CanSubmit || Count() != 0) throw new InvalidOperationException("只读条件仍发送写入。"); }
            else
            {
                var confirm = Control<CheckBox>("VmBatchConfirmation");
                ((Microsoft.UI.Xaml.Automation.Provider.IToggleProvider)new Microsoft.UI.Xaml.Automation.Peers.CheckBoxAutomationPeer(confirm)
                    .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Toggle)).Toggle();
                if (!model.CanSubmit || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("确认后无法提交。");
                if (state == "vmbatch-selection-change")
                {
                    list.SelectedItems.RemoveAt(list.SelectedItems.Count - 1); await model.SubmitAsync();
                    if (model.CanSubmit || Count() != 0) throw new InvalidOperationException("选择变化未撤销确认。");
                }
                else if (state is not ("vmbatch-form" or "vmbatch-off-form"))
                {
                    if (state == "vmbatch-tail-change")
                    { if (images) repository.Images[^1] = repository.Images[^1] with { Name = "changed" }; else repository.Machines[^1] = repository.Machines[^1] with { Name = "changed" }; }
                    Invoke(Control<Button>("PrimaryButton")); await Task.Delay(60);
                    if (state == "vmbatch-close-busy")
                    {
                        if (!model.IsBusy || Count() != 1) throw new InvalidOperationException("关闭场景未进入提交。");
                        await WriteSnapshotAsync(dialog, markComplete: false); dialog.Hide(); await showing;
                        repository.Release.SetResult(SmokeVmPowerBatchRepository.Success()); await Task.Delay(100);
                        if (!repository.Token.IsCancellationRequested || model.ConfirmedCount != 0 || Count() != 1) throw new InvalidOperationException("关闭后仍应用成功或执行下一项。");
                        MarkSnapshotComplete(); return;
                    }
                    if (state == "vmbatch-cancel")
                    { for (var index = 0; index < 500 && Count() < 23; index++) await Task.Delay(10); Invoke(Control<Button>("VmBatchCancelButton")); }
                    for (var index = 0; index < 1000 && model.IsBusy; index++) await Task.Delay(10);
                    if (model.IsBusy) throw new InvalidOperationException("批次未完成。"); await Task.Delay(80);
                    if (state == "vmbatch-tail-change")
                    { if (Count() != 0 || model.MessageKey != "VmBatchChanged") throw new InvalidOperationException("尾项变化时仍写入。"); }
                    else
                    {
                        var stopped = state is "vmbatch-unknown" or "vmbatch-auth" or "vmbatch-cancel" or "vmbatch-review-after" or "vmbatch-rejected";
                        if (Count() != (stopped ? 23 : 205) || model.NotStartedCount != (stopped ? 182 : 0) || model.ConfirmedCount != (stopped ? 22 : 205))
                            throw new InvalidOperationException("批次执行或结果数量错误。");
                        if (images ? repository.ImageDeletes.Any(item => !item.RiskConfirmed || !VirtualMachineImageDeletionRules.CanRequest(item.Baseline)) || repository.ImageDeletes.Select(item => item.RequestId).Distinct().Count() != Count()
                            : deletion ? repository.Deletes.Any(item => !item.RiskConfirmed || item.Baseline.State != VirtualMachineOperationalState.Stopped) || repository.Deletes.Select(item => item.RequestId).Distinct().Count() != Count()
                            : repository.Calls.Any(item => item.Action != action || !item.RiskConfirmed) || repository.Calls.Select(item => item.RequestId).Distinct().Count() != Count())
                            throw new InvalidOperationException("已确认动作漂移或重复提交。");
                        await model.SubmitAsync(); if (Count() != (stopped ? 23 : 205)) throw new InvalidOperationException("完成批次被重发。");
                        if (state == "vmbatch-review-after")
                        {
                            repository.Resolve = true; Invoke(Control<Button>("SecondaryButton")); await Task.Delay(140);
                            if (Count() != 23 || model.ConfirmedCount != 23 || model.NotStartedCount != 182) throw new InvalidOperationException("核对后自动继续了未开始项目。");
                        }
                    }
                }
            }
        }
        if (images && repository.Deletes.Count != 0) throw new InvalidOperationException("映像流程删除了虚拟机。");
        if (deletion && repository.Calls.Count != 0) throw new InvalidOperationException("删除流程调用了电源接口。");
        // 等待原生勾选/按钮视觉状态过渡结束，并确认勾选没有被异步重置。
        await Task.Delay(160);
        if (state is "vmbatch-form" or "vmbatch-off-form" &&
            (Control<CheckBox>("VmBatchConfirmation").IsChecked != true || !dialog.IsPrimaryButtonEnabled || !model.CanSubmit))
            throw new InvalidOperationException("稳定后的确认状态不可提交。");
        dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
        dialog.Hide(); await showing.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();
    }

    private static async Task SaveVirtualMachinePowerAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "vmpower-on";
        var repository = new SmokeRepository(); var model = new LanStash.App.Features.VirtualMachines.VirtualMachineManagerViewModel();
        using var page = new VirtualMachineManagerPage(repository, model);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300); model.SelectMachine(model.Machines[0]);
        var action = state switch { "vmpower-shutdown" => VirtualMachinePowerAction.Shutdown, "vmpower-off" => VirtualMachinePowerAction.PowerOff, _ => VirtualMachinePowerAction.PowerOn };
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var showing = (Task)typeof(VirtualMachineManagerPage).GetMethod("ShowPowerAsync", flags)!.Invoke(page, [action])!; await Task.Delay(300);
        if (showing.IsCompleted) await showing;
        var dialog = (ContentDialog)typeof(VirtualMachineManagerPage).GetField("_powerDialog", flags)!.GetValue(page)!;
        var content = (VirtualMachinePowerDialogContent)dialog.Content;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("电源确认主题或默认按钮不正确。");
        await content.SubmitAsync(); if (repository.VmPowerCalls != 0) throw new InvalidOperationException("未经确认发送了电源命令。");
        if (state == "vmpower-loading" && !Control<ProgressRing>("BusyIndicator").IsActive) throw new InvalidOperationException("电源核查加载状态缺失。");
        if (state == "vmpower-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("电源核查错误状态缺失。");
        if (state is not ("vmpower-loading" or "vmpower-error"))
        {
            Control<CheckBox>("RiskAcknowledgement").IsChecked = true;
            if (state is "vmpower-readonly" or "vmpower-pending")
            { if (content.CanSubmit || dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("不允许的电源操作已启用。"); }
            else if (state != "vmpower-recovered")
            {
                if (!content.CanSubmit) throw new InvalidOperationException("有效电源确认没有启用。");
                var sending = content.SubmitAsync();
                if (state == "vmpower-close-busy")
                {
                    await Task.Delay(60); await content.SubmitAsync(); if (repository.VmPowerCalls != 1) throw new InvalidOperationException("并发电源命令重复提交。");
                    await WriteSnapshotAsync(dialog); page.Dispose(); await showing; await sending;
                    if (!repository.VmPowerCancelled) throw new InvalidOperationException("关闭未取消电源等待。"); return;
                }
                await sending; await content.SubmitAsync(); if (repository.VmPowerCalls != 1) throw new InvalidOperationException("电源命令可重复提交。");
                if (!Control<InfoBar>("FeedbackNotice").IsOpen) throw new InvalidOperationException("缺少电源结果反馈。");
                if (state == "vmpower-unknown")
                { await content.ReloadAsync(); if (repository.VmPowerCalls != 1 || content.CanSubmit || Control<InfoBar>("FeedbackNotice").Severity == InfoBarSeverity.Success) throw new InvalidOperationException("未知结果重放或被误报成功。"); }
            }
        }
        await WriteSnapshotAsync(dialog); dialog.Hide(); await showing;
        if (state is "vmpower-on" or "vmpower-recovered" && model.Machines[0].Machine.State != VirtualMachineOperationalState.Running) throw new InvalidOperationException("电源操作后父列表没有刷新。");
    }

    private static async Task SaveFileExtractionAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "extract-form";
        var files = new SmokeDragMoveRepository(); files.Files.Clear();
        files.Files.Add(new("/share/Sample.zip", "Sample.zip", false, 100, DateTimeOffset.UnixEpoch, null, true, true));
        var model = new FileBrowserViewModel(files); var repository = new SmokeExtractionRepository(state);
        var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
        using var coordinator = new ForegroundTransferCoordinator(); var profile = repository.ProfileId.ToString(); coordinator.ActivateProfile(profile);
        var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator, new WindowsTransferSavePicker(() => null), new WindowsTransferOpenPicker(() => null));
        using var page = new FilesPage(model, preview, profile, picker, archiveExtractionRepository: repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(200); await model.OpenLocationAsync("/share"); await Task.Delay(100);
        model.SelectedItem = model.Items.First(item => !item.Item.IsDirectory);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var showing = (Task)typeof(FilesPage).GetMethod("ShowArchiveExtractionAsync", flags)!.Invoke(page, null)!;
        await Task.Delay(300);
        var dialog = (ContentDialog?)typeof(FilesPage).GetField("_archiveExtractionDialog", flags)!.GetValue(page)
            ?? throw new InvalidOperationException("解压窗口未打开。");
        var panel = (StackPanel)((ScrollViewer)dialog.Content).Content;
        var password = panel.Children.OfType<PasswordBox>().Single();
        var encoding = panel.Children.OfType<ComboBox>().Single();
        if (encoding.Items.Count != 6 || repository.Calls != 0 || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("解压编码、主题或未确认状态错误。");
        password.Password = " synthetic "; encoding.SelectedIndex = 1;
        CheckBox Check(string name) => panel.Children.OfType<CheckBox>().Single(item => item.Name == name);
        if (Check("KeepArchiveFolders").IsChecked != true || Check("CreateArchiveFolder").IsChecked != true || Check("OverwriteArchiveFiles").IsChecked == true)
            throw new InvalidOperationException("解压默认目录选项错误。");
        if (state is "extract-overwrite" or "extract-confirm" or "extract-confirm-reset" or "extract-flatten")
        {
            Check("OverwriteArchiveFiles").IsChecked = true;
            if (dialog.IsPrimaryButtonEnabled || dialog.DefaultButton != ContentDialogButton.Close || repository.Calls != 0)
                throw new InvalidOperationException("覆盖未确认便可提交。");
            if (state != "extract-confirm") Check("ConfirmArchiveOverwrite").IsChecked = true;
            if (state is "extract-confirm-reset" or "extract-flatten")
            {
                Check("KeepArchiveFolders").IsChecked = false;
                if (Check("ConfirmArchiveOverwrite").IsChecked == true || dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("修改选项未清除确认。");
                if (state == "extract-flatten") { Check("CreateArchiveFolder").IsChecked = false; Check("ConfirmArchiveOverwrite").IsChecked = true; }
            }
        }
        static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
        {
            for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
            { var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i); yield return child; foreach (var nested in Descendants(child)) yield return nested; }
        }
        void Confirm()
        {
            var button = Descendants(dialog).OfType<Button>().Single(item => item.Name == "PrimaryButton");
            var peer = new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button);
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)peer.GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        }
        if (state is not ("extract-form" or "extract-confirm" or "extract-confirm-reset"))
        {
            Confirm(); await Task.Delay(200);
            if (repository.Calls != 1 || password.Password.Length != 0) throw new InvalidOperationException("解压调用或密码清理错误。");
            if (state is "extract-password" or "extract-retry")
            {
                if (dialog.Content is not ScrollViewer || !panel.Children.OfType<InfoBar>().Single().IsOpen || string.IsNullOrEmpty(dialog.PrimaryButtonText))
                    throw new InvalidOperationException("密码错误无法原地重试。");
                if (state == "extract-retry")
                {
                    password.Password = " synthetic "; Confirm(); await Task.Delay(200);
                    if (repository.Calls != 2 || password.Password.Length != 0 || Descendants(dialog).OfType<InfoBar>().Single().Severity != InfoBarSeverity.Success)
                        throw new InvalidOperationException("密码纠正后解压流程未完成。");
                }
            }
            else if (state != "extract-working" && ((Descendants(dialog).OfType<InfoBar>().Single().Severity == InfoBarSeverity.Success) != (state is "extract-success" or "extract-overwrite" or "extract-flatten")))
                throw new InvalidOperationException("解压结果反馈错误。");
        }
        if (state is "extract-confirm" or "extract-confirm-reset")
        { dialog.UpdateLayout(); var scroll = (ScrollViewer)dialog.Content; scroll.ChangeView(null, scroll.ScrollableHeight, null, true); await Task.Delay(100); }
        await WriteSnapshotAsync(dialog, markComplete: false);
        if (state == "extract-working") page.Dispose(); else dialog.Hide();
        await showing;
        if (password.Password.Length != 0) throw new InvalidOperationException("解压关闭后仍保留密码。");
        MarkSnapshotComplete();
    }

    private static async Task SaveFileFavoritesAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "favorite-add";
        var repository = new SmokeFavoriteRepository(state); var files = new SmokeDragMoveRepository(); var model = new FileBrowserViewModel(files);
        var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
        using var coordinator = new ForegroundTransferCoordinator(); var profile = repository.ProfileId.ToString(); coordinator.ActivateProfile(profile);
        var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator, new WindowsTransferSavePicker(() => null), new WindowsTransferOpenPicker(() => null));
        using var page = new FilesPage(model, preview, profile, picker, locationsRepository: repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(250); await model.OpenLocationAsync("/share"); await Task.Delay(100);
        model.SelectedItem = state == "favorite-current-folder" ? null : model.Items.First(item => !item.Item.IsDirectory);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var locations = (LanStash.App.Features.Files.Locations.FileLocationsViewModel)typeof(FilesPage).GetField("_locationsViewModel", flags)!.GetValue(page)!;
        if (state == "favorite-profile-change")
        { var other = new SmokeFavoriteRepository("favorite-add", Guid.NewGuid()); locations.Activate(other.ProfileId, other, model); }
        typeof(FilesPage).GetMethod("UpdateState", flags)!.Invoke(page, null);
        var button = (AppBarButton)page.FindName("ToggleFavoriteButton"); var notice = (InfoBar)page.FindName("FileFavoriteStatus");
        Task Change() => (Task)typeof(FilesPage).GetMethod("ChangeFavoriteAsync", flags)!.Invoke(page, null)!;
        if (state is "favorite-readonly" or "favorite-profile-change")
        { await Change(); if (button.IsEnabled || repository.Writes != 0) throw new InvalidOperationException("收藏权限或 profile 边界失效。"); }
        else
        {
            if (!button.IsEnabled) throw new InvalidOperationException("收藏正式入口仍被关闭。");
            var change = Change();
            if (state == "favorite-close-busy")
            {
                await Task.Delay(60); await Change(); if (repository.Writes != 1) throw new InvalidOperationException("收藏重复提交。");
                await WriteSnapshotAsync(page, markComplete: false); page.Dispose(); await change;
                if (!repository.Cancelled) throw new InvalidOperationException("关闭未取消收藏等待。"); MarkSnapshotComplete(); return;
            }
            await change; if (!notice.IsOpen || repository.Writes != 1) throw new InvalidOperationException("收藏操作缺少反馈。");
            if (state is "favorite-unknown" or "favorite-review")
            {
                if (button.Label != LanStash.App.Localization.LocalizationService.Current.Get("FileFavoriteReview")) throw new InvalidOperationException("未知收藏未切换只读核查。");
                repository.Resolve = state == "favorite-review"; await Change();
                if (repository.Writes != 1 || repository.Reviews != 1) throw new InvalidOperationException("核查重发了收藏请求。");
            }
            var success = state is not ("favorite-unknown" or "favorite-permission");
            if ((notice.Severity == InfoBarSeverity.Success) != success) throw new InvalidOperationException("收藏结果被错误提升。");
            if (success)
            {
                var expectedPath = state == "favorite-current-folder" ? "/share" : "/share/one.txt";
                if (locations.Favorites.Items.Any(item => item.Path == expectedPath) == (state == "favorite-remove")) throw new InvalidOperationException("收藏侧栏未同步更新。");
            }
        }
        await Task.Delay(100); page.UpdateLayout(); await WriteSnapshotAsync(page, markComplete: false); MarkSnapshotComplete();
    }

    private static async Task SaveCopyRecoveryAsync(FrameworkElement root, bool recycle = false)
    {
        static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
        {
            for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); index++)
            {
                var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, index); yield return child;
                foreach (var nested in Descendants(child)) yield return nested;
            }
        }
        static void InvokePrimary(ContentDialog dialog)
        {
            var button = Descendants(dialog).OfType<Button>().Single(item => item.Name == "PrimaryButton");
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
                .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        }
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "review-success";
        var restore = state.StartsWith("restore-", StringComparison.Ordinal);
        if (restore || state.StartsWith("recycle-", StringComparison.Ordinal)) state = state[8..];
        var repository = new SmokeCopyMoveRecoveryRepository(state, recycle, restore); var blocker = new FileCopyMoveReviewBlocker();
        var recycleBlocker = new FileRecycleReviewBlocker();
        var recycleOperation = restore ? FileRecycleOperation.Restore : FileRecycleOperation.MoveToRecycle;
        if (recycle) recycleBlocker.Block(new(repository.ProfileId, recycleOperation, repository.Pending.SourcePath, repository.Pending.DestinationPath));
        else blocker.Block(new(repository.ProfileId, FileCopyMoveOperation.Move, repository.Pending.SourcePath, "/destination"));
        bool Blocked() => recycle ? recycleBlocker.Find(repository.ProfileId, recycleOperation, repository.Pending.SourcePath, repository.Pending.DestinationPath) is not null
            : blocker.Find(repository.ProfileId, FileCopyMoveOperation.Move, repository.Pending.SourcePath, "/destination") is not null;
        using var browser = new FileBrowserViewModel(new SmokeDragMoveRepository());
        var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
        using var coordinator = new ForegroundTransferCoordinator(); var profile = repository.ProfileId.ToString(); coordinator.ActivateProfile(profile);
        using var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator, new WindowsTransferSavePicker(() => null), new WindowsTransferOpenPicker(() => null));
        using var page = new FilesPage(browser, preview, profile, picker, copyMoveRepository: recycle ? null : repository, copyMoveReviewBlocker: blocker,
            recycleRepository: recycle ? repository : null, recycleReviewBlocker: recycleBlocker);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(180); await browser.OpenLocationAsync("/share"); await Task.Delay(100);
        if (!((AppBarButton)page.FindName(recycle ? "RecycleRecoveryButton" : "CopyMoveRecoveryButton")).IsEnabled) throw new InvalidOperationException("核对入口未开放。");
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        Task Open() => (Task)typeof(FilesPage).GetMethod("ShowFileOperationRecoveryAsync", flags)!.Invoke(page, [recycle])!;
        ContentDialog Dialog() => (ContentDialog)typeof(FilesPage).GetField("_fileOperationRecoveryDialog", flags)!.GetValue(page)!;
        FileOperationRecoveryViewModel Model() => (FileOperationRecoveryViewModel)typeof(FilesPage).GetField("_fileOperationRecoveryModel", flags)!.GetValue(page)!;
        var showing = Open(); await Task.Delay(200); var dialog = Dialog(); var model = Model();
        if (dialog.ActualTheme != root.ActualTheme || dialog.DefaultButton != ContentDialogButton.Close) throw new InvalidOperationException("核对窗口主题或默认关闭不正确。");
        if (state is "review-empty" or "review-load-error")
        {
            if (model.CanReview || model.MessageKey != (state == "review-empty" ? "FileOperationReviewEmpty" : "FileOperationReviewFailed")) throw new InvalidOperationException("空或失败状态错误。");
        }
        else if (state != "review-form")
        {
            InvokePrimary(dialog); await Task.Delay(100);
            if (state is "review-close-busy" or "review-reopen")
            {
                if (!model.IsBusy || repository.Reviews != 1) throw new InvalidOperationException("核对未进入运行态。");
                dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
                dialog.Hide(); await showing.WaitAsync(TimeSpan.FromSeconds(3));
                repository.Complete(); await Task.Delay(150);
                if (!repository.ReviewToken.IsCancellationRequested || repository.Acknowledgements != 0 ||
                    !Blocked())
                    throw new InvalidOperationException("关闭后迟到结果被应用。");
                if (state == "review-close-busy") { if (repository.Writes != 0) throw new InvalidOperationException("核对误发写操作。"); MarkSnapshotComplete(); return; }
                showing = Open(); await Task.Delay(200); dialog = Dialog(); model = Model(); InvokePrimary(dialog); await Task.Delay(150);
            }
            if (state is "review-success" or "review-reopen")
            {
                if (model.ConfirmedCount != 1 || repository.Acknowledgements != 1 || model.Items.Count != 0 ||
                    Blocked())
                    throw new InvalidOperationException("确认结果未解除正确记录。");
            }
            if (state == "review-pending" && (model.MessageKey != "FileOperationReviewPending" || repository.Acknowledgements != 0)) throw new InvalidOperationException("未知核对被误确认。");
            if (state == "review-auth" && model.MessageKey != "FileOperationReviewSignIn") throw new InvalidOperationException("登录失效缺少恢复提示。");
        }
        if (repository.Writes != 0) throw new InvalidOperationException("核对误发写操作。");
        dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
        dialog.Hide(); await showing.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();
    }

    private static async Task SaveCopyConflictsAsync(FrameworkElement root)
    {
        static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
        {
            for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); index++)
            {
                var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, index); yield return child;
                foreach (var nested in Descendants(child)) yield return nested;
            }
        }
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "conflict-copy-skip";
        var single = state.Contains("single", StringComparison.Ordinal);
        var operation = state.Contains("move", StringComparison.Ordinal) ? FileCopyMoveOperation.Move : FileCopyMoveOperation.Copy;
        var overwrite = state.Contains("overwrite", StringComparison.Ordinal);
        var repository = new SmokeLargeCopyMoveRepository(state);
        using var browser = new FileBrowserViewModel(new SmokeDragMoveRepository());
        var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
        using var coordinator = new ForegroundTransferCoordinator(); var profile = repository.ProfileId.ToString(); coordinator.ActivateProfile(profile);
        using var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator, new WindowsTransferSavePicker(() => null), new WindowsTransferOpenPicker(() => null));
        using var page = new FilesPage(browser, preview, profile, picker, copyMoveRepository: repository, copyMoveFolderSource: repository,
            copyMoveReviewBlocker: new FileCopyMoveReviewBlocker());
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(150); await browser.OpenLocationAsync("/share"); await Task.Delay(100);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        typeof(FilesPage).GetMethod("ListLayout_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]);
        browser.SelectedItem = browser.Items.First(item => !item.Item.IsDirectory);
        if (!single)
        {
            typeof(FilesPage).GetMethod("EnterCopyMoveSelectionMode", flags)!.Invoke(page, [operation]);
            ((ListView)page.FindName("FileList")).SelectAll();
        }
        var showing = (Task)typeof(FilesPage).GetMethod(single ? "ShowCopyMoveAsync" : "ShowBatchCopyMoveAsync", flags)!.Invoke(page, [operation])!;
        await Task.Delay(200); if (showing.IsCompleted) await showing;
        var dialog = (ContentDialog?)typeof(FilesPage).GetField("_batchCopyMoveDialog", flags)!.GetValue(page) ?? throw new InvalidOperationException("同名窗口未打开。");
        var model = (FileCopyMoveBatchViewModel)typeof(FilesPage).GetField("_batchCopyMoveModel", flags)!.GetValue(page)!;
        var expectedCount = single ? 1 : 3;
        if (model.Sources.Count != expectedCount || model.ConflictPolicy != FileCopyMoveConflictPolicy.Skip || repository.Requests.Count != 0)
            throw new InvalidOperationException("初始选择、默认跳过或零提交约束错误。");
        // 通过正式目标树点击打开目标，不能绕过窗口的渲染与按钮状态。
        var folderList = Descendants(dialog).OfType<ListView>().Single();
        var container = folderList.ContainerFromIndex(0) as ListViewItem ?? throw new InvalidOperationException("目标树未加载。");
        ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ListViewItemAutomationPeer(container)
            .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        await Task.Delay(150);
        if (model.DestinationPath != "/destination" || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("目标选择没有生效。");
        if (overwrite)
        {
            var check = Descendants(dialog).OfType<CheckBox>().Single(item => item.Name == "CopyMoveOverwriteChoice");
            ((Microsoft.UI.Xaml.Automation.Provider.IToggleProvider)new Microsoft.UI.Xaml.Automation.Peers.CheckBoxAutomationPeer(check)
                .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Toggle)).Toggle();
            await Task.Delay(120);
            if (model.ConflictPolicy != FileCopyMoveConflictPolicy.Overwrite ||
                dialog.PrimaryButtonText != Localization.LocalizationService.Current.Format(operation == FileCopyMoveOperation.Copy
                    ? "FileCopyMoveCopyOverwriteAction" : "FileCopyMoveMoveOverwriteAction", expectedCount))
                throw new InvalidOperationException("覆盖选项未更新确认按钮。");
            if (state.EndsWith("toggle-back", StringComparison.Ordinal))
            {
                check = Descendants(dialog).OfType<CheckBox>().Single(item => item.Name == "CopyMoveOverwriteChoice");
                ((Microsoft.UI.Xaml.Automation.Provider.IToggleProvider)new Microsoft.UI.Xaml.Automation.Peers.CheckBoxAutomationPeer(check)
                    .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Toggle)).Toggle(); await Task.Delay(100); overwrite = false;
            }
        }
        if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme || repository.Requests.Count != 0)
            throw new InvalidOperationException("未确认提交、主题或默认取消错误。");
        if (!state.EndsWith("form", StringComparison.Ordinal))
        {
            var button = Descendants(dialog).OfType<Button>().Single(item => item.Name == "PrimaryButton");
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
                .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            if (state.EndsWith("cancel", StringComparison.Ordinal))
            {
                for (var index = 0; index < 100 && repository.Requests.Count == 0; index++) await Task.Delay(10);
                model.Cancel();
            }
            for (var index = 0; index < 300 && model.State != FileCopyMoveBatchState.Completed; index++) await Task.Delay(10);
            await Task.Delay(80); await model.SubmitAsync();
            var stopped = state.EndsWith("unknown", StringComparison.Ordinal) || state.EndsWith("cancel", StringComparison.Ordinal);
            var skipped = overwrite || stopped ? 0 : state.Contains("all-skip", StringComparison.Ordinal) ? expectedCount : 1;
            if (model.State != FileCopyMoveBatchState.Completed || repository.Requests.Count != (stopped ? 1 : expectedCount) ||
                model.Summary.SkippedCount != skipped || model.Summary.ConfirmedCount != (stopped ? 0 : expectedCount - skipped) ||
                model.ConfirmedItems.Count != model.Summary.ConfirmedCount || model.Summary.NotStartedCount != (stopped ? expectedCount - 1 : 0))
                throw new InvalidOperationException("同名处理计数、未知中止或重复提交错误。");
            if (repository.Requests.Any(request => request.ConflictPolicy != (overwrite ? FileCopyMoveConflictPolicy.Overwrite : FileCopyMoveConflictPolicy.Skip)))
                throw new InvalidOperationException("确认策略与请求不符。");
        }
        dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
        dialog.Hide(); await showing.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();
    }

    private static async Task SaveLargeRecycleAsync(FrameworkElement root)
    {
        static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
        {
            for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); index++)
            {
                var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, index); yield return child;
                foreach (var nested in Descendants(child)) yield return nested;
            }
        }
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "recycle-run";
        var restore = state.StartsWith("restore-", StringComparison.Ordinal);
        var operation = restore ? FileRecycleOperation.Restore : FileRecycleOperation.MoveToRecycle;
        var parent = restore ? "/share/#recycle" : "/share";
        var source = new SmokeDragMoveRepository(); source.Files.Clear();
        source.Files.AddRange(Enumerable.Range(0, 205).Select(index => new FileItem($"{parent}/f{index:D4}.txt", $"f{index:D4}.txt", false, 7, DateTimeOffset.UnixEpoch, null, true, true)));
        if (restore) source.Files.Add(new(parent + "/target", "target", true, 0, null, null, true, true));
        using var browser = new FileBrowserViewModel(source); var repository = new SmokeLargeRecycleRepository(state);
        var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
        var locationsRepository = System.Reflection.DispatchProxy.Create<IFileLocationsRepository, SmokeRecycleLocations>();
        using var coordinator = new ForegroundTransferCoordinator(); var profile = repository.ProfileId.ToString(); coordinator.ActivateProfile(profile);
        using var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator, new WindowsTransferSavePicker(() => null), new WindowsTransferOpenPicker(() => null));
        using var page = new FilesPage(browser, preview, profile, picker, locationsRepository: locationsRepository,
            recycleRepository: repository, recycleReviewBlocker: new FileRecycleReviewBlocker());
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(180);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var locations = (FileLocationsViewModel)typeof(FilesPage).GetField("_locationsViewModel", flags)!.GetValue(page)!;
        await locations.RefreshAsync(); await locations.OpenLocationAsync(parent, restore ? FileLocationSource.Recycle : FileLocationSource.Browser);
        while (browser.CanLoadMore) await browser.LoadMoreAsync(); await Task.Delay(100);
        typeof(FilesPage).GetMethod("ListLayout_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]);
        browser.SelectedItem = browser.Items[0];
        typeof(FilesPage).GetMethod("EnterBatchRecycleSelectionMode", flags)!.Invoke(page, [operation]);
        var list = (ListView)page.FindName("FileList"); list.SelectAll(); await Task.Delay(80);
        if (list.SelectedItems.Count != 206) throw new InvalidOperationException("回收/恢复仍截断选择。");
        if (state.EndsWith("grid", StringComparison.Ordinal))
        {
            typeof(FilesPage).GetMethod("GridLayout_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]); await Task.Delay(80);
            if (((GridView)page.FindName("FileGrid")).SelectedItems.Count != 206) throw new InvalidOperationException("布局切换丢失选择。");
        }
        var showing = (Task)typeof(FilesPage).GetMethod("ShowBatchRecycleAsync", flags)!.Invoke(page, [operation])!;
        await Task.Delay(200); if (showing.IsCompleted) await showing;
        var dialog = (ContentDialog?)typeof(FilesPage).GetField("_batchRecycleDialog", flags)!.GetValue(page) ?? throw new InvalidOperationException("批量窗口未打开。");
        var model = (FileRecycleBatchViewModel)typeof(FilesPage).GetField("_batchRecycleModel", flags)!.GetValue(page)!;
        if (dialog.ActualTheme != root.ActualTheme || model.Sources.Count != 206 || dialog.DefaultButton != ContentDialogButton.Close || repository.Paths.Count != 0)
            throw new InvalidOperationException("主题、完整快照或默认取消不符合预期。");
        if (!state.EndsWith("form", StringComparison.Ordinal) && !state.EndsWith("grid", StringComparison.Ordinal))
        {
            if (state.EndsWith("change-tail", StringComparison.Ordinal)) list.SelectedItems.Remove(browser.Items[^1]);
            if (state.EndsWith("metadata", StringComparison.Ordinal)) { source.Files[^1] = source.Files[^1] with { Size = 99 }; await browser.RefreshAsync(); }
            var button = Descendants(dialog).OfType<Button>().Single(item => item.Name == "PrimaryButton");
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
                .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            if (state.EndsWith("change-tail", StringComparison.Ordinal) || state.EndsWith("metadata", StringComparison.Ordinal))
            {
                await Task.Delay(150);
                if (repository.Paths.Count != 0 || dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("选择变化仍可提交旧快照。");
            }
            else
            {
                if (state.EndsWith("cancel", StringComparison.Ordinal))
                {
                    for (var index = 0; index < 300 && repository.Paths.Count < 23; index++) await Task.Delay(10);
                    await Task.Delay(80);
                    var panel = (StackPanel)dialog.Content;
                    if (panel.Children.OfType<ProgressBar>().Single().Value != 22 ||
                        panel.Children.OfType<TextBlock>().Single(item => item.Name == "BatchRecycleWorking").Text !=
                        Localization.LocalizationService.Current.Format(restore ? "FileRestoreBatchWorking" : "FileRecycleBatchWorking", 23, 206))
                        throw new InvalidOperationException("运行进度没有更新。");
                    model.Cancel();
                }
                for (var index = 0; index < 500 && model.State != FileRecycleBatchState.Completed; index++) await Task.Delay(10);
                if (model.State != FileRecycleBatchState.Completed) throw new InvalidOperationException("回收/恢复批次未完成。");
                await model.SubmitAsync(); await Task.Delay(80);
                var stopped = state.EndsWith("unknown", StringComparison.Ordinal) || state.EndsWith("cancel", StringComparison.Ordinal) || state.EndsWith("auth", StringComparison.Ordinal);
                if (repository.Paths.Count != (stopped ? 23 : 206) || repository.Paths.Distinct().Count() != repository.Paths.Count ||
                    model.Summary.ConfirmedCount != (stopped ? 22 : 206) || model.Summary.NotStartedCount != (stopped ? 183 : 0))
                    throw new InvalidOperationException("执行缺失、重复或停止后计数不守恒。");
                if (state.EndsWith("cancel", StringComparison.Ordinal) && (!repository.Cancelled || model.Summary.NeedsReviewCount != 1)) throw new InvalidOperationException("取消未保留未知结果。");
                if (state.EndsWith("auth", StringComparison.Ordinal) && (!model.RequiresSignIn || !((StackPanel)dialog.Content).Children.OfType<TextBlock>().Any(item => item.Text == Localization.LocalizationService.Current.Get("FileRecycleBatchSignIn"))))
                    throw new InvalidOperationException("登录失效缺少提示。");
            }
        }
        await Task.Delay(100); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
        dialog.Hide(); await showing.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();
    }

    private static async Task SaveLargeCopyMoveAsync(FrameworkElement root)
    {
        static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
        {
            for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); index++)
            {
                var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, index);
                yield return child;
                foreach (var nested in Descendants(child)) yield return nested;
            }
        }
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "copy-large-run";
        var operation = state.StartsWith("move-", StringComparison.Ordinal) ? FileCopyMoveOperation.Move : FileCopyMoveOperation.Copy;
        var source = new SmokeDragMoveRepository(); source.Files.Clear();
        source.Files.AddRange(Enumerable.Range(0, 205).Select(index => new FileItem($"/share/f{index:D4}.txt", $"f{index:D4}.txt", false, 7, DateTimeOffset.UnixEpoch, null, true, true)));
        using var browser = new FileBrowserViewModel(source); var repository = new SmokeLargeCopyMoveRepository(state);
        var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
        using var coordinator = new ForegroundTransferCoordinator(); var profile = repository.ProfileId.ToString(); coordinator.ActivateProfile(profile);
        using var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator, new WindowsTransferSavePicker(() => null), new WindowsTransferOpenPicker(() => null));
        using var page = new FilesPage(browser, preview, profile, picker, copyMoveRepository: repository, copyMoveFolderSource: repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(150); await browser.OpenLocationAsync("/share");
        while (browser.CanLoadMore) await browser.LoadMoreAsync(); await Task.Delay(100);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        typeof(FilesPage).GetMethod("ListLayout_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]);
        browser.SelectedItem = browser.Items[0];
        typeof(FilesPage).GetMethod("EnterCopyMoveSelectionMode", flags)!.Invoke(page, [operation]);
        var list = (ListView)page.FindName("FileList"); list.SelectAll(); await Task.Delay(80);
        if (list.SelectedItems.Count != 206) throw new InvalidOperationException("复制/移动仍截断选择。");
        if (state == "copy-large-grid")
        {
            typeof(FilesPage).GetMethod("GridLayout_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]); await Task.Delay(80);
            if (((GridView)page.FindName("FileGrid")).SelectedItems.Count != 206) throw new InvalidOperationException("复制/移动布局切换丢失选择。");
        }
        var showing = (Task)typeof(FilesPage).GetMethod("ShowBatchCopyMoveAsync", flags)!.Invoke(page, [operation])!;
        await Task.Delay(200); if (showing.IsCompleted) await showing;
        var dialog = (ContentDialog?)typeof(FilesPage).GetField("_batchCopyMoveDialog", flags)!.GetValue(page) ?? throw new InvalidOperationException("批量窗口未打开。");
        if (dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("批量复制/移动窗口没有跟随主题。");
        var model = (FileCopyMoveBatchViewModel)typeof(FilesPage).GetField("_batchCopyMoveModel", flags)!.GetValue(page)!;
        await model.LoadFoldersAsync("/destination", repository.Writable);
        dialog.Content = FilesPage.BuildBatchCopyMoveContent(model, Localization.LocalizationService.Current, () => Task.CompletedTask);
        dialog.IsPrimaryButtonEnabled = model.CanSubmit;
        if (repository.Requests.Count != 0 || model.Sources.Count != 206 || dialog.DefaultButton != ContentDialogButton.Close) throw new InvalidOperationException("未确认已提交或选择不完整。");
        if (state == "copy-large-readonly")
        {
            if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("无权限目标可提交。");
            await model.SubmitAsync(); if (repository.Requests.Count != 0) throw new InvalidOperationException("只读目标仍发送请求。");
        }
        else if (state is not ("copy-large-form" or "copy-large-grid"))
        {
            if (state == "copy-large-change-tail") list.SelectedItems.Remove(browser.Items[^1]);
            if (state == "copy-large-metadata")
            {
                source.Files[^1] = source.Files[^1] with { Size = 99 }; await browser.RefreshAsync();
            }
            var button = Descendants(dialog).OfType<Button>().Single(item => item.Name == "PrimaryButton");
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
                .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            if (state is "copy-large-change-tail" or "copy-large-metadata")
            {
                await Task.Delay(150);
                if (repository.Requests.Count != 0 || dialog.PrimaryButtonText.Length != 0) throw new InvalidOperationException("选择或末项变化仍沿用旧确认。");
            }
            else
            {
                if (state == "copy-large-cancel")
                {
                    for (var index = 0; index < 300 && repository.Requests.Count < 23; index++) await Task.Delay(10);
                    await Task.Delay(80);
                    var progress = ((StackPanel)dialog.Content).Children.OfType<TextBlock>().Single(item => item.Name == "BatchCopyMoveProgress");
                    var expected = Localization.LocalizationService.Current.Format("FileCopyMoveBatchCopying", 23, 206);
                    if (progress.Text != expected) throw new InvalidOperationException("大批次进度停留在旧项目。");
                    model.Cancel();
                }
                for (var index = 0; index < 500 && model.State != FileCopyMoveBatchState.Completed; index++) await Task.Delay(10);
                if (model.State != FileCopyMoveBatchState.Completed) throw new InvalidOperationException("批次未结束。");
                await model.SubmitAsync();
                var stopped = state is "copy-large-unknown" or "move-large-unknown" or "copy-large-cancel" or "copy-large-auth";
                if (repository.Requests.Count != (stopped ? 23 : 206) || repository.Requests.Select(request => request.Target.Path).Distinct().Count() != repository.Requests.Count)
                    throw new InvalidOperationException("执行缺失或重复提交。");
                if (stopped && (model.Summary.ConfirmedCount != 22 || model.Summary.NotStartedCount != 183)) throw new InvalidOperationException("停止后的计数不守恒。");
                if (state == "copy-large-cancel" && !repository.Cancelled) throw new InvalidOperationException("取消未到达提交。");
                if (state == "copy-large-auth" && (!model.RequiresSignIn || !((StackPanel)dialog.Content).Children.OfType<TextBlock>().Any(item => item.Name == "BatchCopyMoveSignIn")))
                    throw new InvalidOperationException("认证失效缺少重新登录提示。");
                if (!stopped && model.Summary.ConfirmedCount != 206) throw new InvalidOperationException("完整选择未全部确认。");
                if (repository.Requests.Any(request => request.Operation != operation || request.DestinationDirectoryPath != "/destination")) throw new InvalidOperationException("操作或目标漂移。");
            }
        }
        await Task.Delay(100); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
        dialog.Hide(); await showing.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();
    }

    private sealed class SmokeNetworkRepository(string state) : IVirtualMachineManagerRepository
    {
        public Guid ProfileId => SmokeActivityProbe.Profile;
        public bool CanReadNetworkManagement => true;
        public bool CanManageNetworks => state != "network-readonly";
        public VirtualMachineManagerAvailability Availability => new(VirtualMachineManagerAvailabilityStatus.Available, new HashSet<VirtualMachineManagerReadFeature> { VirtualMachineManagerReadFeature.Networks });
        public List<VirtualMachineNetwork> Networks { get; } = Enumerable.Range(0, state == "network-empty" ? 0 : state == "network-large" ? 205 : 3)
            .Select(index => new VirtualMachineNetwork($"net-{index:D3}", $"Network {index:D3}", "external", "", 0,
                [new("host", "nic")], [new($"vm-{index:D3}", $"VM {index:D3}", false, false, false)])).ToList();
        public List<VirtualMachineNetworkRequest> Writes { get; } = [];
        public List<VirtualMachineNetworkRecovery> Pending { get; } = [];
        public bool Resolve, Cancelled;
        public int Reviews;
        public CancellationToken Token;
        public Task<VirtualMachineNetworkInventory> LoadNetworkManagementAsync(CancellationToken token = default)
        {
            if (state == "network-error") throw new InvalidOperationException("synthetic");
            if (state == "network-loading") return WaitForCancellation(token);
            return Task.FromResult(new VirtualMachineNetworkInventory(state == "network-frozen", Networks.ToArray()));
        }
        private async Task<VirtualMachineNetworkInventory> WaitForCancellation(CancellationToken token)
        {
            try { await Task.Delay(Timeout.Infinite, token); }
            catch (OperationCanceledException) { Cancelled = true; throw; }
            throw new InvalidOperationException("合成加载等待不应正常完成。");
        }
        public async Task<MutationResult> MutateNetworkAsync(VirtualMachineNetworkRequest request, CancellationToken token = default)
        {
            if (!request.RiskConfirmed || request.ProfileId != ProfileId) throw new InvalidOperationException("网络写入缺少确认或身份。");
            Writes.Add(request); Token = token;
            if (state == "network-close-busy")
            {
                Pending.Add(new(request.Baseline.Id, request.Baseline.Name, request.Action));
                try { await Task.Delay(Timeout.Infinite, token); }
                catch (OperationCanceledException) { Cancelled = true; throw; }
            }
            if (state is "network-unknown" or "network-review" && Writes.Count == 2)
            {
                Pending.Add(new(request.Baseline.Id, request.Baseline.Name, request.Action));
                return new(1, MutationResultStatus.SubmittedButUnverified, "virtualMachineNetwork", true, true, new(0, 0, 1));
            }
            if (state == "network-auth") return new(1, MutationResultStatus.ConfirmedFailure, "virtualMachineNetwork", true, true, new(0, 1, 0), MutationErrorCategory.Authentication);
            var index = Networks.FindIndex(item => item.Id == request.Baseline.Id);
            if (request.Action == VirtualMachineNetworkAction.Delete) Networks.RemoveAt(index);
            else Networks[index] = Networks[index] with { Name = request.NewName! };
            return Success();
        }
        public Task<IReadOnlyList<VirtualMachineNetworkRecovery>> GetNetworkRecoveriesAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<VirtualMachineNetworkRecovery>>(Pending.ToArray());
        public Task<MutationResult?> ReviewNetworkAsync(string id, CancellationToken token = default)
        {
            Reviews++;
            if (Resolve) { Pending.RemoveAll(item => item.Id == id); Networks.RemoveAll(item => item.Id == id); }
            return Task.FromResult<MutationResult?>(Resolve ? Success() : new(1, MutationResultStatus.SubmittedButUnverified, "virtualMachineNetwork", true, true, new(0, 0, 1)));
        }
        private static MutationResult Success() => new(1, MutationResultStatus.ConfirmedSuccess, "virtualMachineNetwork", true, false, new(1, 0, 0));
        public Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(CancellationToken token = default) => Task.FromResult(new VirtualMachineManagerSnapshot(ProfileId,
            VirtualMachineManagerSection<VirtualMachineSummary>.Available([]), VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available(Networks.Select(item => new VirtualizationResourceSummary(item.Id, item.Name, VirtualizationResourceKind.Network, VirtualizationResourceHealth.Healthy)).ToArray()),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable, VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<ServiceEventSummary>.Unavailable));
    }

    private static async Task SaveVirtualMachineNetworksAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少 VMM 测试 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "network-form";
        var repository = new SmokeNetworkRepository(state);
        using var page = new VirtualMachineManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(150);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var showing = (Task)typeof(VirtualMachineManagerPage).GetMethod("ShowNetworksAsync", flags)!.Invoke(page, null)!;
        await Task.Delay(150);
        var dialog = (ContentDialog?)typeof(VirtualMachineManagerPage).GetField("_networksDialog", flags)!.GetValue(page);
        if (dialog?.Content is not VirtualMachineNetworksDialogContent content) throw new InvalidOperationException("网络管理入口没有打开。");
        var model = (VirtualMachineNetworksViewModel)typeof(VirtualMachineNetworksDialogContent).GetField("_model", flags)!.GetValue(content)!;
        try
        {
            for (var index = 0; index < 250 && model.IsBusy && state != "network-loading"; index++) await Task.Delay(20);
            var list = (ListView)content.FindName("NetworkList");
            if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != page.ActualTheme) throw new InvalidOperationException("网络确认默认按钮或主题错误。");
            if (state is "network-empty" or "network-error" or "network-frozen" or "network-readonly" or "network-loading")
            {
                if (content.CanSubmit) throw new InvalidOperationException("空、错误或只读状态仍可写。");
                if (state == "network-error" && model.MessageKey != "VmNetworkLoadFailed") throw new InvalidOperationException("读取失败被当成空网络。");
                if (state == "network-loading" && !model.IsBusy) throw new InvalidOperationException("缺少加载状态。");
                await WriteSnapshotAsync(dialog, markComplete: false);
            }
            else
            {
                var rename = state.StartsWith("network-rename", StringComparison.Ordinal);
                ((ComboBox)content.FindName("ActionSelector")).SelectedIndex = rename ? 0 : 1;
                if (rename) list.SelectedItem = list.Items[0]; else list.SelectAll();
                await Task.Delay(80);
                if (rename) ((TextBox)content.FindName("NewNameBox")).Text = state == "network-rename-invalid" ? " " : state == "network-rename-duplicate" ? "Network 001" : "Renamed network";
                await Task.Delay(80);
                ((CheckBox)content.FindName("ConfirmBox")).IsChecked = true; await Task.Delay(80);
                var invalid = state is "network-rename-invalid" or "network-rename-duplicate";
                if (invalid) { if (content.CanSubmit || model.ValidationKey is null) throw new InvalidOperationException("无效名称仍可保存或没有修正提示。"); }
                else if (!content.CanSubmit || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("明确确认后网络操作未开启。");
                if (state is "network-form" or "network-rename-form" || invalid)
                {
                    await Task.Delay(150);
                    await WriteSnapshotAsync(dialog, markComplete: false);
                }
                else if (state == "network-selection-change")
                {
                    list.SelectedItems.Remove(list.Items[^1]); await Task.Delay(80);
                    if (content.CanSubmit || model.HasConfirmation) throw new InvalidOperationException("选择改变未清除确认。");
                    await content.SubmitAsync(); if (repository.Writes.Count != 0) throw new InvalidOperationException("失效确认仍写入。");
                    await WriteSnapshotAsync(dialog, markComplete: false);
                }
                else
                {
                    if (state == "network-tail-change") repository.Networks[^1] = repository.Networks[^1] with { Name = "Changed" };
                    var submitting = content.SubmitAsync();
                    if (state == "network-close-busy")
                    {
                        for (var index = 0; index < 250 && repository.Writes.Count == 0; index++) await Task.Delay(20);
                        await WriteSnapshotAsync(dialog, markComplete: false);
                        typeof(VirtualMachineManagerPage).GetMethod("CloseNetworksDialog", flags)!.Invoke(page, null);
                        await submitting.WaitAsync(TimeSpan.FromSeconds(5)); await showing.WaitAsync(TimeSpan.FromSeconds(5));
                        if (!repository.Token.IsCancellationRequested || !repository.Cancelled || repository.Writes.Count != 1) throw new InvalidOperationException("关闭没有停止后续网络操作。");
                        MarkSnapshotComplete(); return;
                    }
                    await submitting.WaitAsync(TimeSpan.FromSeconds(10));
                    var expected = state == "network-tail-change" ? 0 : state is "network-unknown" or "network-review" ? 2 : state == "network-auth" || rename ? 1 : repository.Networks.Count + repository.Writes.Count;
                    if (repository.Writes.Count != expected) throw new InvalidOperationException("网络批次数量错误。");
                    if (state == "network-large" && repository.Writes.Count != 205) throw new InvalidOperationException("网络选择被截断。");
                    if (state == "network-review")
                    {
                        repository.Resolve = true; await content.ReviewAsync();
                        if (repository.Writes.Count != 2 || repository.Reviews != 1 || model.Pending.Count != 0 || model.Results.Count != 2) throw new InvalidOperationException("核查重放写入或丢失已有结果。");
                    }
                    await Task.Delay(80); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog, markComplete: false);
                }
            }
        }
        finally { dialog.Hide(); await showing.WaitAsync(TimeSpan.FromSeconds(5)); }
        if (state == "network-loading")
        {
            for (var index = 0; index < 250 && !repository.Cancelled; index++) await Task.Delay(20);
            if (!repository.Cancelled) throw new InvalidOperationException("关闭没有取消加载。");
        }
        MarkSnapshotComplete();
    }

    private sealed class SmokeNotificationBackend : IForegroundTransferNotificationBackend
    {
        public bool IsSupported => true;
        public event Action<IReadOnlyDictionary<string, string>>? Invoked;
        public int Registers, Unregisters, Shows;
        public string Context = "";
        public void Register() => Registers++;
        public void Unregister() => Unregisters++;
        public void Show(ForegroundTransferNotification notification, string context) { Shows++; Context = context; }
        public Dictionary<string, string> Arguments => new() { ["route"] = "activity", ["context"] = Context };
        public void Emit(IReadOnlyDictionary<string, string> arguments) => Invoked?.Invoke(arguments);
    }

    private static async Task SaveNotificationLifecycleAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少通知测试 Shell。");
        var main = (Application.Current as App)?.MainWindow ?? throw new InvalidOperationException("缺少测试窗口。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "notification-open";
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var serviceField = typeof(MainWindow).GetField("_transferNotifications", flags)!;
        var generationField = typeof(MainWindow).GetField("_notificationGeneration", flags)!;
        var generation = (int)generationField.GetValue(main)!;
        var route = typeof(MainWindow).GetMethod("ShowTransfersFromNotification", flags)!;
        var backend = new SmokeNotificationBackend();
        var notice = new ForegroundTransferNotification(ForegroundTransferNotificationKind.Completed,
            ForegroundTransferDirection.Download, "Synthetic completed", "Synthetic summary");
        Platform.Notifications.WindowsTransferNotificationService? service = null;
        service = new(() => route.Invoke(main, [service!, generation]), Dispatch, backend);
        serviceField.SetValue(main, service);
        Platform.Notifications.WindowsTransferNotificationService? replacement = null;
        var frame = (Frame)shell.FindName("ContentFrame"); var initial = frame.Content;
        try
        {
            service.Show(notice);
            if (backend.Registers != 1 || backend.Shows != 1) throw new InvalidOperationException("通知没有使用串行注册路径。");
            var xml = System.Xml.Linq.XDocument.Parse(Platform.Notifications.WindowsTransferNotificationService.BuildNotification(notice, backend.Context).Payload);
            var launch = (string?)xml.Root?.Attribute("launch") ?? "";
            if (!launch.Contains("route=activity", StringComparison.Ordinal) || !launch.Contains(backend.Context, StringComparison.Ordinal)) throw new InvalidOperationException("SDK 未生成完整的通知路由参数。");
            var arguments = backend.Arguments;
            if (state == "notification-invalid") arguments["route"] = "activity-extra";
            if (state == "notification-old-context") arguments["context"] = "old";
            backend.Emit(arguments);
            if (state == "notification-dispose") service.Dispose();
            if (state == "notification-generation") generationField.SetValue(main, generation + 1);
            if (state == "notification-replaced")
            {
                replacement = new(() => { }, Dispatch, new SmokeNotificationBackend()); serviceField.SetValue(main, replacement);
            }
            if (state == "notification-exit") typeof(MainWindow).GetField("_isExplicitExit", flags)!.SetValue(main, true);
            var drained = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            main.DispatcherQueue.TryEnqueue(() => drained.TrySetResult()); await drained.Task;
            if (state == "notification-open")
            {
                for (var index = 0; index < 250 && frame.Content is not TransferActivityPage; index++) await Task.Delay(20);
                if (frame.Content is not TransferActivityPage) throw new InvalidOperationException("点击通知没有进入传输中心。");
            }
            else if (!ReferenceEquals(initial, frame.Content)) throw new InvalidOperationException("旧连接、失效通知或退出后仍发生导航。");
            await Task.Delay(100); await WriteSnapshotAsync((FrameworkElement)frame.Content, markComplete: false);
        }
        finally
        {
            service.Dispose(); replacement?.Dispose();
            if (backend.Unregisters != 1) throw new InvalidOperationException("通知注册未被完整清理。");
            serviceField.SetValue(main, null); generationField.SetValue(main, generation);
            typeof(MainWindow).GetField("_isExplicitExit", flags)!.SetValue(main, false);
        }
        MarkSnapshotComplete();
        bool Dispatch(Action action)
        {
            if (main.DispatcherQueue.HasThreadAccess) { action(); return true; }
            return main.DispatcherQueue.TryEnqueue(() => action());
        }
    }

    private static async Task SaveCloudSettingsAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少设置 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "cloud-empty";
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var app = (AppViewModel)typeof(ShellPage).GetField("_app", flags)!.GetValue(shell)!;
        if (CloudDrive.DesktopCloudDriveCapabilityGate.IsRegistrationEnabled) throw new InvalidOperationException("未确认就启用了系统注册。");
        ((NavigationView)shell.FindName("Navigation")).SelectedItem = shell.FindName("SettingsItem");
        await Task.Delay(100);
        var frame = (Frame)shell.FindName("ContentFrame");
        if (frame.Content is not AppSettingsPage settings) throw new InvalidOperationException("设置入口没有显示。");
        Invoke((Button)settings.FindName("CloudDriveButton")); await Task.Delay(100);
        if (frame.Content is not CloudDriveSettingsPage page) throw new InvalidOperationException("云盘入口断开。");
        if (((CheckBox)page.FindName("LaunchAtLoginChoice")).IsChecked != false) throw new InvalidOperationException("未选择就开启登录启动。");
        if (((Button)page.FindName("AddNasButton")).IsEnabled || !((Button)page.FindName("EnableTestButton")).IsEnabled) throw new InvalidOperationException("云盘默认能力门错误。");
        if (state.StartsWith("cloud-writeback", StringComparison.Ordinal))
        {
            var enabled = state is not ("cloud-writeback-form" or "cloud-writeback-enable" or "cloud-writeback-close-busy" or "cloud-writeback-all-shares" or "cloud-writeback-invalid-scope");
            var current = true; var configured = 0; var recovered = 0; var exported = 0; var cancelled = false;
            var cancellationObserved = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var unknown = new CloudDrive.CloudDrivePendingChange(Guid.NewGuid(), "/synthetic/unknown.txt", "\"old\"", new string('A', 64), 10,
                CloudDrive.CloudDriveChangePhase.Submitted, DateTimeOffset.UnixEpoch);
            if (state == "cloud-writeback-directory") unknown = unknown with
            {
                RemotePath = "/synthetic/new-folder", BaseVersion = null, ContentLength = 0,
                ContentHash = "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855",
                Kind = CloudDrive.CloudDriveChangeKind.CreateDirectory,
            };
            var conflict = unknown with { Id = Guid.NewGuid(), RemotePath = "/synthetic/conflict.txt", Phase = CloudDrive.CloudDriveChangePhase.Conflict };
            var records = state is "cloud-writeback-form" or "cloud-writeback-enable" or "cloud-writeback-close-busy" or "cloud-writeback-all-shares" or "cloud-writeback-invalid-scope" ?
                new List<CloudDrive.CloudDrivePendingChange>() : new List<CloudDrive.CloudDrivePendingChange> { unknown, conflict };
            if (state == "cloud-writeback-released")
            {
                records.Clear(); records.Add(unknown with { Phase = CloudDrive.CloudDriveChangePhase.Verified, ContentReleased = true });
            }
            var localization = LanStash.App.Localization.LocalizationService.Current;
            var relocationRows = new List<CloudDrive.CloudDriveRelocationOperation>();
            var relocationCalls = 0;
            var deletionRows = new List<CloudDrive.CloudDriveDeletionOperation>();
            var deletionCalls = 0; var deletionConfigured = 0; var deletionEnabled = false;
            if (state.StartsWith("cloud-writeback-delete-", StringComparison.Ordinal))
            {
                records.Clear();
                deletionEnabled = state != "cloud-writeback-delete-enable";
                if (deletionEnabled)
                {
                    var phase = state.EndsWith("unknown", StringComparison.Ordinal) ? CloudDrive.CloudDriveDeletionPhase.Submitted :
                        state.EndsWith("local", StringComparison.Ordinal) ? CloudDrive.CloudDriveDeletionPhase.ServerVerified : CloudDrive.CloudDriveDeletionPhase.Prepared;
                    deletionRows.Add(new(Guid.NewGuid(), "synthetic-delete", "/synthetic/delete-folder", true, 0, DateTimeOffset.UnixEpoch,
                        null, phase, DateTimeOffset.UnixEpoch));
                }
            }
            if (state.StartsWith("cloud-writeback-move-", StringComparison.Ordinal))
            {
                records.Clear();
                var phase = state.EndsWith("unknown", StringComparison.Ordinal) ? CloudDrive.CloudDriveRelocationPhase.Submitted :
                    state.EndsWith("local", StringComparison.Ordinal) ? CloudDrive.CloudDriveRelocationPhase.ServerVerified :
                    state.EndsWith("rejected", StringComparison.Ordinal) ? CloudDrive.CloudDriveRelocationPhase.Rejected : CloudDrive.CloudDriveRelocationPhase.ReadyForNextStep;
                relocationRows.Add(new(Guid.NewGuid(), "synthetic-item", "/synthetic/old.txt", "/synthetic/folder/new.txt", "new.txt", false, 3,
                    DateTimeOffset.UnixEpoch, [new("/synthetic/old.txt", "/synthetic/folder/old.txt", true), new("/synthetic/folder/old.txt", "/synthetic/folder/new.txt", false)],
                    phase == CloudDrive.CloudDriveRelocationPhase.ServerVerified ? 2 : phase == CloudDrive.CloudDriveRelocationPhase.Submitted ? 0 : 1, phase, DateTimeOffset.UnixEpoch));
            }
            var dialog = new CloudDriveWritebackDialog(
                token => state == "cloud-writeback-error" ? throw new IOException("合成读取失败") : Task.FromResult(new CloudDrive.CloudDriveWritebackOverview(enabled, records.ToArray(), relocationRows, deletionEnabled, deletionRows)),
                async (value, confirmed, token) =>
                {
                    if (!confirmed || !current) throw new InvalidOperationException("缺少绑定确认。");
                    configured++;
                    if (state == "cloud-writeback-close-busy")
                    {
                        try { await Task.Delay(Timeout.Infinite, token); }
                        catch (OperationCanceledException) { cancelled = true; cancellationObserved.TrySetResult(); throw; }
                    }
                    enabled = value; return new(2, 1);
                },
                (change, action, confirmed, token) =>
                {
                    if (!records.Contains(change) || !current || action == CloudDrive.CloudDriveRecoveryAction.Retry && !confirmed)
                        throw new InvalidOperationException("恢复目标或确认漂移。");
                    if (change.Id == unknown.Id && action != CloudDrive.CloudDriveRecoveryAction.Review)
                        throw new InvalidOperationException("未知结果不能重发。");
                    if (change.Kind == CloudDrive.CloudDriveChangeKind.CreateDirectory && !confirmed)
                        throw new InvalidOperationException("目录结果缺少归属确认。");
                    recovered++; return Task.CompletedTask;
                },
                (change, token) => { exported++; return Task.FromResult(true); }, () => current, state != "cloud-writeback-invalid-scope",
                (operation, action, confirmed, token) =>
                {
                    if (!confirmed || !current || !relocationRows.Contains(operation)) throw new InvalidOperationException("迁移恢复缺少绑定确认。");
                    if (operation.Phase == CloudDrive.CloudDriveRelocationPhase.Submitted && action != CloudDrive.CloudDriveRelocationRecoveryAction.Review)
                        throw new InvalidOperationException("未知迁移不允许写入。");
                    relocationCalls++; return Task.CompletedTask;
                }, (value, confirmed, token) =>
                {
                    if (!confirmed || !current) throw new InvalidOperationException("删除设置缺少确认。");
                    deletionConfigured++; deletionEnabled = value; return Task.CompletedTask;
                }, (operation, action, confirmed, token) =>
                {
                    if (!confirmed || !current || !deletionRows.Contains(operation)) throw new InvalidOperationException("删除恢复缺少对象确认。");
                    if (operation.Phase == CloudDrive.CloudDriveDeletionPhase.Submitted && action != CloudDrive.CloudDriveDeletionRecoveryAction.Review)
                        throw new InvalidOperationException("未知删除不能重发。");
                    deletionCalls++; return Task.CompletedTask;
                })
                { XamlRoot = page.XamlRoot, RequestedTheme = page.ActualTheme };
            var showing = dialog.ShowAsync().AsTask();
            try
            {
                await Task.Delay(200);
                var mode = Descendants(dialog).OfType<Button>().Single(button => button.Name == "WritebackModeButton");
                if (mode.IsEnabled || configured != 0 || recovered != 0 || exported != 0) throw new InvalidOperationException("打开同步管理不能自动写入或跳过确认。");
                if (state == "cloud-writeback-released" && (Descendants(dialog).OfType<Button>().Any(button => Equals(button.Tag, unknown.Id)) ||
                    !Descendants(dialog).OfType<TextBlock>().Any(text => text.Text == localization.Get("CloudDriveWritebackCopyReleased"))))
                    throw new InvalidOperationException("已释放的临时副本仍提供导出或没有说明。");
                var deletionMode = Descendants(dialog).OfType<Button>().Single(button => button.Name == "DeletionModeButton");
                if (deletionMode.IsEnabled || deletionConfigured != 0 || deletionCalls != 0) throw new InvalidOperationException("删除没有独立确认。");
                if (state == "cloud-writeback-delete-enable")
                {
                    Descendants(dialog).OfType<CheckBox>().Single(box => box.Name == "DeletionModeConfirmation").IsChecked = true;
                    Invoke(deletionMode); await Task.Delay(100);
                    if (!deletionEnabled || deletionConfigured != 1) throw new InvalidOperationException("删除设置未接入或重复执行。");
                }
                if (deletionRows.Count != 0)
                {
                    var operation = deletionRows[0];
                    var buttons = Descendants(dialog).OfType<Button>().Where(button => Equals(button.Tag, operation.Id)).ToArray();
                    if (buttons.Any(button => button.IsEnabled)) throw new InvalidOperationException("未确认即允许删除。");
                    var key = operation.Phase == CloudDrive.CloudDriveDeletionPhase.Submitted ? "CloudDriveWritebackReview" :
                        operation.Phase == CloudDrive.CloudDriveDeletionPhase.ServerVerified ? "CloudDriveDeletionCompleteLocal" : "CloudDriveDeletionConfirm";
                    if (operation.Phase != CloudDrive.CloudDriveDeletionPhase.Prepared && buttons.Any(button => Equals(button.Content, localization.Get("CloudDriveDeletionConfirm"))))
                        throw new InvalidOperationException("已提交的删除再次提供删除按钮。");
                    Descendants(dialog).OfType<CheckBox>().Single(box => Equals(box.Tag, operation.Id)).IsChecked = true;
                    Invoke(buttons.Single(button => Equals(button.Content, localization.Get(key)))); await Task.Delay(100);
                    if (deletionCalls != 1) throw new InvalidOperationException("删除动作未接入或重复执行。");
                }
                if (state == "cloud-writeback-invalid-scope" && Descendants(dialog).OfType<CheckBox>().Single(box => box.Name == "WritebackModeConfirmation").IsEnabled)
                    throw new InvalidOperationException("无效挂载范围仍可启用写入。");
                if (state is "cloud-writeback-enable" or "cloud-writeback-close-busy" or "cloud-writeback-all-shares")
                {
                    Descendants(dialog).OfType<CheckBox>().Single(box => box.Name == "WritebackModeConfirmation").IsChecked = true;
                    Invoke(mode); await Task.Delay(100);
                    if (configured != 1) throw new InvalidOperationException("确认后编辑入口仍不可用或重复提交。");
                }
                if (state is "cloud-writeback-review" or "cloud-writeback-retry" or "cloud-writeback-export" or "cloud-writeback-directory")
                {
                    if (Descendants(dialog).OfType<Button>().Any(button => Equals(button.Tag, unknown.Id) && Equals(button.Content, localization.Get("CloudDriveWritebackRetry"))))
                        throw new InvalidOperationException("未知结果暴露重试上传。");
                    if (state == "cloud-writeback-retry") Descendants(dialog).OfType<CheckBox>().Single(box => Equals(box.Tag, conflict.Id)).IsChecked = true;
                    if (state == "cloud-writeback-directory")
                    {
                        var review = Descendants(dialog).OfType<Button>().Single(button => Equals(button.Tag, unknown.Id) && Equals(button.Content, localization.Get("CloudDriveWritebackReview")));
                        if (review.IsEnabled || Descendants(dialog).OfType<Button>().Any(button => Equals(button.Tag, unknown.Id) && Equals(button.Content, localization.Get("CloudDriveWritebackExport"))))
                            throw new InvalidOperationException("目录未确认即可接纳，或伪装成单文件导出。");
                        Descendants(dialog).OfType<CheckBox>().Single(box => Equals(box.Tag, unknown.Id)).IsChecked = true;
                    }
                    var key = state is "cloud-writeback-review" or "cloud-writeback-directory" ? "CloudDriveWritebackReview" : state == "cloud-writeback-retry" ? "CloudDriveWritebackRetry" : "CloudDriveWritebackExport";
                    var target = state == "cloud-writeback-retry" ? conflict.Id : unknown.Id;
                    Invoke(Descendants(dialog).OfType<Button>().Single(button => Equals(button.Tag, target) && Equals(button.Content, localization.Get(key))));
                    await Task.Delay(100);
                    if (state == "cloud-writeback-export" ? exported != 1 : recovered != 1) throw new InvalidOperationException("恢复按钮没有使用目标操作。");
                }
                if (state == "cloud-writeback-error" && !Descendants(dialog).OfType<TextBlock>().Any(text => text.Text == localization.Get("CloudDriveWritebackError")))
                    throw new InvalidOperationException("读取失败没有恢复提示。");
                if (relocationRows.Count != 0)
                {
                    var operation = relocationRows[0];
                    var buttons = Descendants(dialog).OfType<Button>().Where(button => Equals(button.Tag, operation.Id)).ToArray();
                    if (buttons.Any(button => button.IsEnabled) || relocationCalls != 0) throw new InvalidOperationException("未确认就能恢复迁移。");
                    if (operation.Step > 0 && buttons.Any(button => Equals(button.Content, localization.Get("CloudDriveRelocationAbandon"))))
                        throw new InvalidOperationException("已部分完成仍可直接放弃。");
                    var key = operation.Phase == CloudDrive.CloudDriveRelocationPhase.Submitted ? "CloudDriveWritebackReview" :
                        operation.Phase == CloudDrive.CloudDriveRelocationPhase.ServerVerified ? "CloudDriveRelocationCompleteLocal" : "CloudDriveRelocationContinue";
                    Descendants(dialog).OfType<CheckBox>().Single(box => Equals(box.Tag, operation.Id)).IsChecked = true;
                    Invoke(buttons.Single(button => Equals(button.Content, localization.Get(key))));
                    await Task.Delay(100);
                    if (relocationCalls != 1) throw new InvalidOperationException("迁移恢复重复或未执行。");
                }
                await WriteSnapshotAsync(dialog, markComplete: false);
            }
            finally { current = false; dialog.Hide(); await showing; }
            if (state == "cloud-writeback-close-busy") await cancellationObserved.Task.WaitAsync(TimeSpan.FromSeconds(5));
            if (state == "cloud-writeback-close-busy" && !cancelled) throw new InvalidOperationException("关闭后未取消同步操作。");
            if (CloudDrive.DesktopCloudDriveCapabilityGate.IsRegistrationEnabled || app.DesktopDriveMappings.Count != 0)
                throw new InvalidOperationException("合成恢复操作触碰真实注册或配置。");
            MarkSnapshotComplete(); return;
        }
        if (state.StartsWith("cloud-refresh", StringComparison.Ordinal))
        {
            CloudDrive.DesktopCloudDriveCapabilityGate.EnableForCurrentProcess();
            var mapping = new DesktopDriveMapping(Guid.NewGuid(), app.ActiveProfile!.Id, "Synthetic Drive",
                DesktopDriveScope.Folder("/synthetic"), DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
            app.DesktopDriveMappings.Add(mapping);
            if (state == "cloud-refresh-disconnected")
            {
                var service = typeof(AppViewModel).GetField("_cloudDrives", flags)!.GetValue(app)!;
                var states = (Dictionary<Guid, DesktopDriveMappingRuntime>)service.GetType().GetField("_states", flags)!.GetValue(service)!;
                states[mapping.Id] = DesktopDriveMappingRuntime.Default with { State = DesktopDriveMappingState.Offline };
            }
            var calls = 0; var cancelled = false;
            var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var refreshPage = new CloudDriveSettingsPage(app, async (target, token) =>
            {
                if (target != mapping) throw new InvalidOperationException("刷新目标漂移。");
                calls++;
                if (state is "cloud-refresh-cancel" or "cloud-refresh-leave")
                {
                    try { await Task.Delay(Timeout.Infinite, token); }
                    catch (OperationCanceledException) { cancelled = true; throw; }
                }
                if (state == "cloud-refresh-duplicate") await release.Task;
                if (state == "cloud-refresh-error") throw new IOException("synthetic refresh failure");
                return state switch { "cloud-refresh-partial" => new(2, 1), "cloud-refresh-empty" => new(0, 0),
                    "cloud-refresh-removed" => new(2, 0, 3, 0), "cloud-refresh-retained" => new(1, 1, 2, 3), _ => new(3, 0) };
            });
            frame.Content = refreshPage; await Task.Delay(150);
            var localization = LanStash.App.Localization.LocalizationService.Current;
            var refresh = Descendants(refreshPage).OfType<Button>().Single(button => Equals(button.Content, localization.Get("CloudDriveRefresh")));
            if (refresh.IsEnabled == (state == "cloud-refresh-disconnected")) throw new InvalidOperationException("刷新连接状态门错误。");
            if (state == "cloud-refresh-disconnected" && !Descendants(refreshPage).OfType<Button>().Any(button =>
                Equals(button.Content, localization.Get("CloudDriveResume")) && button.IsEnabled)) throw new InvalidOperationException("断线云盘缺少恢复入口。");
            refresh.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false }); await Task.Delay(100);
            if (state is not ("cloud-refresh-form" or "cloud-refresh-disconnected"))
            {
                Invoke(refresh); await Task.Delay(100);
                if (state == "cloud-refresh-duplicate")
                {
                    typeof(CloudDriveSettingsPage).GetMethod("RefreshMapping_Click", flags)!.Invoke(refreshPage, [refresh, new RoutedEventArgs()]);
                    if (calls != 1) throw new InvalidOperationException("刷新重复提交。");
                    release.SetResult();
                }
                if (state == "cloud-refresh-cancel") Invoke((Button)refreshPage.FindName("CancelRefreshButton"));
                if (state == "cloud-refresh-leave") frame.Content = settings;
                for (var index = 0; index < 100 && typeof(CloudDriveSettingsPage).GetField("_refreshCancellation", flags)!.GetValue(refreshPage) is not null; index++) await Task.Delay(20);
                if (calls != 1 || typeof(CloudDriveSettingsPage).GetField("_refreshCancellation", flags)!.GetValue(refreshPage) is not null)
                    throw new InvalidOperationException("刷新没有结束或多次执行。");
                if (state is "cloud-refresh-cancel" or "cloud-refresh-leave" && !cancelled) throw new InvalidOperationException("未取消刷新。");
                if (state != "cloud-refresh-leave")
                {
                    var notice = (InfoBar)refreshPage.FindName("CloudDriveMessage");
                    var expected = state switch
                    {
                        "cloud-refresh-partial" => localization.Format("CloudDriveRefreshPartial", 2, 1),
                        "cloud-refresh-empty" => localization.Get("CloudDriveRefreshEmpty"),
                        "cloud-refresh-error" => localization.Get("CloudDriveGenericError"),
                        "cloud-refresh-cancel" => localization.Get("CloudDriveRefreshCancelled"),
                        "cloud-refresh-removed" => localization.Format("CloudDriveRefreshReconciled", 2, 3, 0, 0),
                        "cloud-refresh-retained" => localization.Format("CloudDriveRefreshReconciled", 1, 2, 3, 1),
                        _ => localization.Format("CloudDriveRefreshDone", 3)
                    };
                    if (notice.Message != expected) throw new InvalidOperationException("刷新结果文案不符。");
                }
            }
            if (state is not ("cloud-refresh-form" or "cloud-refresh-disconnected" or "cloud-refresh-leave"))
            {
                ((InfoBar)refreshPage.FindName("CloudDriveMessage")).StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
                await Task.Delay(100);
            }
            await WriteSnapshotAsync((FrameworkElement)frame.Content); return;
        }
        if (state == "cloud-back")
        {
            Invoke((Button)page.FindName("BackButton")); await Task.Delay(100);
            if (frame.Content is not AppSettingsPage returned) throw new InvalidOperationException("未返回设置。");
            typeof(CloudDriveSettingsPage).GetMethod("EnableTestButton_Click", flags)!.Invoke(page, [page, new RoutedEventArgs()]);
            if (typeof(CloudDriveSettingsPage).GetField("_confirmation", flags)!.GetValue(page) is not null) throw new InvalidOperationException("离页后旧页面仍接受操作。");
            Invoke((Button)returned.FindName("CloudDriveButton")); await Task.Delay(100);
            if (frame.Content is not CloudDriveSettingsPage) throw new InvalidOperationException("无法重新进入云盘。");
        }
        else if (state != "cloud-empty")
        {
            Invoke((Button)page.FindName("EnableTestButton")); await Task.Delay(100);
            var dialog = (ContentDialog?)typeof(CloudDriveSettingsPage).GetField("_confirmation", flags)!.GetValue(page);
            if (dialog is null || dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != page.ActualTheme) throw new InvalidOperationException("缺少安全确认或主题错误。");
            if (state is "cloud-confirm" or "cloud-leave-confirm") await WriteSnapshotAsync(dialog, markComplete: false);
            if (state == "cloud-leave-confirm") Invoke((Button)page.FindName("BackButton"));
            else if (state is "cloud-confirm" or "cloud-cancel") dialog.Hide();
            else
            {
                if (state == "cloud-stale-confirm") app.InitializeSmokeLogin();
                Invoke(Descendants(dialog).OfType<Button>().Single(button => button.Name == "PrimaryButton"));
            }
            for (var index = 0; index < 250 && typeof(CloudDriveSettingsPage).GetField("_confirmation", flags)!.GetValue(page) is not null; index++) await Task.Delay(20);
            if (typeof(CloudDriveSettingsPage).GetField("_confirmation", flags)!.GetValue(page) is not null) throw new InvalidOperationException("云盘确认没有结束。");
            var expected = state == "cloud-enable";
            if (CloudDrive.DesktopCloudDriveCapabilityGate.IsRegistrationEnabled != expected) throw new InvalidOperationException("取消或失效确认改变了注册能力。");
            if (expected && (!((Button)page.FindName("AddNasButton")).IsEnabled || ((Button)page.FindName("EnableTestButton")).Visibility != Visibility.Collapsed)) throw new InvalidOperationException("确认后入口仍被硬编码禁用。");
        }
        if (app.DesktopDriveMappings.Count != 0) throw new InvalidOperationException("打开管理页或确认测试自动添加了映射。");
        if (state is not ("cloud-confirm" or "cloud-leave-confirm")) await WriteSnapshotAsync((FrameworkElement)frame.Content, markComplete: false);
        MarkSnapshotComplete();
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
        {
            for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); index++)
            { var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, index); yield return child; foreach (var nested in Descendants(child)) yield return nested; }
        }
    }

    private static async Task SaveTrayLifecycleAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "tray-recover";
        var window = new Window { Content = new Grid() };
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
        var opened = 0; var toggled = 0; var issues = 0; var exited = 0; var mappings = 0; var issueCount = 0;
        var localization = Localization.LocalizationService.Current;
        var tooltip = localization.Get("TrayTooltip");
        using var tray = new TrayIcon(handle, Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"), tooltip,
            localization.Get("TrayOpenApp"), localization.Get("TrayPauseCloudDrives"), localization.Get("TrayResumeCloudDrives"),
            localization.Get("TrayCloudDriveIssues"), localization.Get("TrayExitApp"), () => mappings, () => false, () => issueCount,
            () => opened++, () => toggled++, () => issues++, () => exited++,
            notifyIcon: state == "tray-unavailable" ? new TrayIcon.NotifyIcon((uint message, ref TrayIcon.NotificationIconData data) => false) : null);
        var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance;
        var restart = (uint)typeof(TrayIcon).GetField("_taskbarCreatedMessage", flags)!.GetValue(tray)!;
        var versionFour = (bool)typeof(TrayIcon).GetField("_usesVersion4", flags)!.GetValue(tray)!;
        try
        {
            if (state != "tray-unavailable" && (!tray.EnsureRegistered() || !Notify(1) || !versionFour)) throw new InvalidOperationException("合成托盘未注册或协议版本错误。");
            if (state is "tray-recover" or "tray-locale")
            {
                if (state == "tray-locale")
                {
                    tooltip = localization.Get("TrayOpenApp");
                    tray.UpdateText(tooltip, tooltip, tooltip, tooltip, tooltip, tooltip);
                }
                if (!Notify(2) || Notify(1)) throw new InvalidOperationException("合成图标未被移除。");
                SendTrayMessage(handle, restart, 0, 0);
                if (!Notify(1) || opened != 0) throw new InvalidOperationException("Shell 重建后没有恢复图标。");
                SendTrayMessage(handle, restart, 0, 0);
                if (!Notify(1) || opened != 0) throw new InvalidOperationException("重复/DPI 广播使已有图标丢失。");
                if ((string)typeof(TrayIcon).GetField("_tooltip", flags)!.GetValue(tray)! != tooltip) throw new InvalidOperationException("恢复丢失当前语言文案。");
            }
            else if (state == "tray-keys")
            {
                foreach (var message in new[] { 0x0400, 0x0401, 0x0202, 0x0203 }) SendTrayMessage(handle, 0x8001, 0, (nint)((1 << 16) | message));
                if (opened != 4) throw new InvalidOperationException("鼠标或键盘没有打开主窗口。");
                SendTrayMessage(handle, 0x8001, 0, (nint)((2 << 16) | 0x0401));
                if (opened != 4) throw new InvalidOperationException("接收了其他图标的回调。");
            }
            else if (state == "tray-messages")
            {
                for (var command = 1; command <= 4; command++) SendTrayMessage(handle, 0x0111, command, 0);
                if (opened + toggled + issues + exited != 0) throw new InvalidOperationException("其他窗口命令触发了托盘操作。");
                var dispatch = typeof(TrayIcon).GetMethod("HandleCommand", flags)!;
                dispatch.Invoke(tray, [2]); dispatch.Invoke(tray, [3]);
                if (toggled + issues != 0) throw new InvalidOperationException("无映射或问题时仍触发操作。");
                mappings = 1; issueCount = 1;
                for (var command = 1; command <= 4; command++) dispatch.Invoke(tray, [command]);
                if (opened != 1 || toggled != 1 || issues != 1 || exited != 1) throw new InvalidOperationException("本菜单命令失效。");
            }
            else if (state == "tray-unavailable")
            {
                // 以可控原生调用失败覆盖启动、更新及重建；不停止 Shell 或更改系统设置。
                if (tray.EnsureRegistered() || opened != 0) throw new InvalidOperationException("注册失败阻止启动或被错误报告为可用。");
                tray.UpdateText(tooltip, tooltip, tooltip, tooltip, tooltip, tooltip);
                if (tray.EnsureRegistered() || opened != 1) throw new InvalidOperationException("恢复失败没有通知返回窗口。");
                SendTrayMessage(handle, restart, 0, 0);
                if (opened != 2) throw new InvalidOperationException("Shell 重建失败没有保留返回入口。");
            }
            else if (state == "tray-dispose")
            {
                tray.Dispose(); tray.Dispose();
                tray.UpdateText(tooltip, tooltip, tooltip, tooltip, tooltip, tooltip);
                SendTrayMessage(handle, restart, 0, 0);
                SendTrayMessage(handle, 0x8001, 0, (nint)((1 << 16) | 0x0401));
                if (tray.EnsureRegistered() || Notify(1) || opened != 0) throw new InvalidOperationException("销毁后重新注册或处理了旧事件。");
            }
            else if (state == "tray-close-fallback")
            {
                var main = (Application.Current as App)?.MainWindow ?? throw new InvalidOperationException("缺少测试主窗口。");
                var mainTray = (TrayIcon)typeof(MainWindow).GetField("_trayIcon", flags)!.GetValue(main)!;
                mainTray.Dispose();
                SendTrayMessage(WinRT.Interop.WindowNative.GetWindowHandle(main), 0x0010, 0, 0);
                await Task.Delay(100);
                var appWindow = (Microsoft.UI.Windowing.AppWindow)typeof(MainWindow).GetField("_appWindow", flags)!.GetValue(main)!;
                if (!appWindow.IsVisible || appWindow.Presenter is not Microsoft.UI.Windowing.OverlappedPresenter presenter ||
                    presenter.State != Microsoft.UI.Windowing.OverlappedPresenterState.Minimized) throw new InvalidOperationException("没有托盘时关闭仍隐藏了主窗口。");
                presenter.Restore(); main.Activate();
            }
            await WriteSnapshotAsync(root, markComplete: false);
        }
        finally { tray.Dispose(); window.Close(); }
        MarkSnapshotComplete();
        bool Notify(uint message)
        {
            var data = typeof(TrayIcon).GetMethod("CreateData", flags)!.Invoke(tray, [tooltip]);
            return (bool)typeof(TrayIcon).GetMethod("ShellNotifyIcon", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!.Invoke(null, [message, data])!;
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "SendMessageW")]
    private static extern nint SendTrayMessage(nint window, uint message, nint wordParameter, nint longParameter);

    private static async Task SaveFolderUploadAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "folder-run";
        var owner = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "lanstash-folder-upload-tests", Guid.NewGuid().ToString("N"))).FullName;
        var directory = Directory.CreateDirectory(Path.Combine(owner, "upload-root")).FullName;
        var complete = false;
        try
        {
            for (var index = 0; index < 205; index++) File.WriteAllText(Path.Combine(directory, $"f{index:D3}.txt"), "data");
            for (var index = 0; index < 35; index++) Directory.CreateDirectory(Path.Combine(directory, $"d{index:D2}"));
            var deep = directory;
            for (var index = 0; index < 15; index++) deep = Directory.CreateDirectory(Path.Combine(deep, "nested")).FullName;
            File.WriteAllText(Path.Combine(deep, "deep.txt"), "data");
            var repository = System.Reflection.DispatchProxy.Create<IDsmRepository, SmokeFileUploadRepository>();
            var fake = (SmokeFileUploadRepository)repository; fake.State = state;
            var open = new SmokeFileUploadPicker([]) { FolderPath = directory, Cancelled = state == "folder-picker-cancel" };
            using var coordinator = new ForegroundTransferCoordinator();
            var profile = SmokeActivityProbe.Profile.ToString(); coordinator.ActivateProfile(profile);
            using var picker = new WindowsTransferPickerService(repository, coordinator, new WindowsTransferSavePicker(() => null), open);
            var finished = new TaskCompletionSource<FolderUploadBatchFinished>(TaskCreationOptions.RunContinuationsAsynchronously);
            picker.FolderUploadBatchFinished += value => finished.TrySetResult(value);
            using var model = new FileBrowserViewModel(new SmokeDragMoveRepository());
            var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
            using var page = new FilesPage(model, preview, profile, picker, mutationRepository: fake);
            ((Frame)shell.FindName("ContentFrame")).Content = page;
            await Task.Delay(150); await model.OpenLocationAsync("/share"); await Task.Delay(100);
            var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
            var status = (InfoBar)page.FindName("FileUploadDropStatus");
            if (state == "folder-prep-cancel") open.OnPick = () => { Invoke((Button)status.ActionButton); return Task.CompletedTask; };
            var preparing = (Task)typeof(FilesPage).GetMethod("UploadFolderToCurrentFolderAsync", flags)!.Invoke(page, null)!;
            if (state is "folder-picker-cancel" or "folder-prep-cancel") await preparing.WaitAsync(TimeSpan.FromSeconds(5));
            else
            {
                ContentDialog? dialog = null;
                for (var index = 0; index < 300; index++)
                {
                    dialog = (ContentDialog?)typeof(FilesPage).GetField("_folderUploadDialog", flags)!.GetValue(page);
                    if (dialog is not null) break;
                    if (preparing.IsCompleted) throw new InvalidOperationException("上传确认未显示。");
                    await Task.Delay(20);
                }
                if (dialog is null) throw new InvalidOperationException("上传确认超时。");
                await Task.Delay(120); dialog.UpdateLayout();
                var message = Localization.LocalizationService.Current.Format("FolderUploadConfirmMessage", "upload-root", 206, 51);
                if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != page.ActualTheme || !Descendants(dialog).OfType<TextBlock>().Any(item => item.Text == message)) throw new InvalidOperationException("确认数量、主题或默认按钮错误。");
                if (fake.Directories.Count != 0 || fake.Names.Count != 0) throw new InvalidOperationException("确认前发生写入。");
                if (state is "folder-form" or "folder-close") await WriteSnapshotAsync(dialog, markComplete: false);
                if (state == "folder-close") await page.CloseAsync();
                else if (state == "folder-target-changed") await model.OpenLocationAsync("/share/target");
                else if (state is "folder-form" or "folder-dialog-cancel") dialog.Hide();
                else
                {
                    if (state == "folder-source-changed") File.AppendAllText(Path.Combine(directory, "f000.txt"), "changed");
                    Invoke(Descendants(dialog).OfType<Button>().Single(item => item.Name == "PrimaryButton"));
                }
                await preparing.WaitAsync(TimeSpan.FromSeconds(8));
            }
            if (state is "folder-run" or "folder-unknown" or "folder-file-cancel")
            {
                if (state == "folder-file-cancel")
                {
                    for (var index = 0; index < 300 && fake.Names.Count < 23; index++) await Task.Delay(20);
                    Invoke((Button)status.ActionButton);
                }
                var result = await finished.Task.WaitAsync(TimeSpan.FromSeconds(15));
                if (result.DirectoryCount != 51 || result.FileCount != 206) throw new InvalidOperationException("完整计划被截断。");
                if (state == "folder-run" && (result.Summary.ConfirmedCount != 257 || fake.Names.Count != 206)) throw new InvalidOperationException("未完成全部目录和文件。");
                if (state == "folder-unknown" && (fake.Directories.Count != 23 || fake.Names.Count != 0 || result.Summary.NeedsReviewCount != 1)) throw new InvalidOperationException("目录结果未知后仍继续上传。");
                if (state == "folder-file-cancel" && (fake.Names.Count != 23 || !fake.Cancelled || result.Summary.NotStartedCount != 183)) throw new InvalidOperationException("取消没有停止后续文件。");
            }
            else if (fake.Directories.Count != 0 || fake.Names.Count != 0 || coordinator.GetActivities(profile).Count != 0) throw new InvalidOperationException("取消或失效后仍有写入。");
            await Task.Delay(100);
            if (state is not ("folder-form" or "folder-close")) { page.UpdateLayout(); await WriteSnapshotAsync(page, markComplete: false); }
            complete = true;
        }
        finally
        {
            var allowed = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "lanstash-folder-upload-tests")) + Path.DirectorySeparatorChar;
            if (!Path.GetFullPath(owner).StartsWith(allowed, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("合成目录越界。");
            Directory.Delete(owner, recursive: true);
            if (complete) MarkSnapshotComplete();
        }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
        {
            for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); index++)
            {
                var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, index); yield return child;
                foreach (var nested in Descendants(child)) yield return nested;
            }
        }
    }

    private static async Task SaveFileUploadBatchAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "upload-large";
        var directory = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "lanstash-upload-batch-tests", Guid.NewGuid().ToString("N"))).FullName;
        var complete = false;
        try
        {
            var paths = Enumerable.Range(0, 205).Select(index => Path.Combine(directory, $"f{index:D4}.txt")).ToArray();
            foreach (var path in paths) File.WriteAllText(path, "data");
            var repository = System.Reflection.DispatchProxy.Create<IDsmRepository, SmokeFileUploadRepository>(); var fake = (SmokeFileUploadRepository)repository; fake.State = state;
            var open = new SmokeFileUploadPicker(state == "upload-duplicate" ? [paths[0], paths[0]] : paths) { Cancelled = state == "upload-picker-cancel" };
            using var coordinator = new ForegroundTransferCoordinator(); var profile = SmokeActivityProbe.Profile.ToString(); coordinator.ActivateProfile(profile);
            using var picker = new WindowsTransferPickerService(repository, coordinator, new WindowsTransferSavePicker(() => null), open);
            var finished = new TaskCompletionSource<ForegroundUploadBatchFinished>(TaskCreationOptions.RunContinuationsAsynchronously);
            picker.UploadBatchFinished += value => finished.TrySetResult(value);
            using var model = new FileBrowserViewModel(new SmokeDragMoveRepository());
            var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
            using var page = new FilesPage(model, preview, profile, picker);
            ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(150); await model.OpenLocationAsync("/share"); await Task.Delay(100);
            var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
            if (state == "upload-target-changed") open.OnPick = () => model.OpenLocationAsync("/share/target");
            if (state == "upload-overwrite-changed") open.OnPick = () => { ((AppBarToggleButton)page.FindName("UploadOverwriteToggle")).IsChecked = true; return Task.CompletedTask; };
            if (state == "upload-overwrite") ((AppBarToggleButton)page.FindName("UploadOverwriteToggle")).IsChecked = true;
            if (state == "upload-close-picker")
            { page.UpdateLayout(); await WriteSnapshotAsync(page, markComplete: false); open.OnPick = () => { page.Dispose(); return Task.CompletedTask; }; }
            if (state == "upload-drop")
            {
                var storage = new List<Windows.Storage.IStorageItem>();
                foreach (var path in paths) storage.Add(await Windows.Storage.StorageFile.GetFileFromPathAsync(path));
                var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetStorageItems(storage);
                var inspection = (Task)typeof(FilesPage).GetMethod("TryGetDroppedUploadAsync", flags | System.Reflection.BindingFlags.Static)!.Invoke(null, [data.GetView()])!;
                await inspection;
                var parsed = inspection.GetType().GetProperty("Result")!.GetValue(inspection) ?? throw new InvalidOperationException("大批量拖放被拒绝。");
                var selected = (IReadOnlyList<string>)parsed.GetType().GetProperty("FilePaths")!.GetValue(parsed)!;
                if (selected.Count != 205) throw new InvalidOperationException("拖放路径被截断。");
                var status = picker.StartUploadBatch(profile, model.CurrentPath, selected);
                typeof(FilesPage).GetMethod("ShowFileUploadBatchStart", flags)!.Invoke(page, [status, selected.Count]);
            }
            else await (Task)typeof(FilesPage).GetMethod("UploadToCurrentFolderAsync", flags)!.Invoke(page, null)!;
            if (state is "upload-target-changed" or "upload-overwrite-changed" or "upload-close-picker" or "upload-picker-cancel" or "upload-duplicate")
            {
                await Task.Delay(100);
                if (fake.Names.Count != 0 || coordinator.GetActivities(profile).Count != 0) throw new InvalidOperationException("无效、失效或取消选择仍上传了文件。");
                if (state != "upload-close-picker") { page.UpdateLayout(); await WriteSnapshotAsync(page, markComplete: false); }
                complete = true; return;
            }
            if (state == "upload-cancel")
            {
                for (var index = 0; index < 300 && fake.Names.Count < 23; index++) await Task.Delay(10);
                var running = coordinator.GetActivities(profile).Single(item => item.State == ForegroundTransferState.Running);
                picker.Cancel(profile, running.Id);
            }
            var result = await finished.Task.WaitAsync(TimeSpan.FromSeconds(10)); await Task.Delay(100);
            var summary = result.Summary;
            if (summary.SelectedCount != 205 || summary.SelectedCount != summary.ConfirmedCount + summary.NeedsReviewCount + summary.FailedCount + summary.CancelledCount + summary.NotStartedCount || fake.MaximumActive != 1)
                throw new InvalidOperationException("批次数量守恒或串行约束错误。");
            if (fake.Names.Count != (state == "upload-cancel" ? 23 : 205) || fake.Names.Distinct(StringComparer.Ordinal).Count() != fake.Names.Count)
                throw new InvalidOperationException("未执行完整选择或重复上传。");
            if (state == "upload-cancel" && (!fake.Cancelled || summary.CancelledCount != 1 || summary.NotStartedCount != 182)) throw new InvalidOperationException("取消没有停止后续文件。");
            if (state == "upload-unknown" && (summary.NeedsReviewCount != 1 || summary.ConfirmedCount != 204)) throw new InvalidOperationException("未知项计数不正确。");
            if (state is not ("upload-cancel" or "upload-unknown") && summary.ConfirmedCount != 205) throw new InvalidOperationException("上传没有全部确认。");
            if (fake.Overwrites.Any(value => value != (state == "upload-overwrite"))) throw new InvalidOperationException("覆盖选择被改变。");
            foreach (var path in paths) { using var stream = File.Open(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None); }
            page.UpdateLayout(); await WriteSnapshotAsync(page, markComplete: false); complete = true;
        }
        finally
        {
            var rootPath = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "lanstash-upload-batch-tests")) + Path.DirectorySeparatorChar;
            if (!Path.GetFullPath(directory).StartsWith(rootPath, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("合成上传临时目录越界。");
            Directory.Delete(directory, recursive: true);
            if (complete) MarkSnapshotComplete();
        }
    }

    private static async Task SaveSelectionDownloadAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "selection-download";
        var directory = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "lanstash-selection-download-tests", Guid.NewGuid().ToString("N"))).FullName;
        var complete = false;
        try
        {
            var target = Path.Combine(directory, state == "selection-single-file" ? "result.txt" : "result.zip");
            File.WriteAllText(target, "original");
            var source = new SmokeDragMoveRepository(); source.Files.Clear();
            source.Files.AddRange(Enumerable.Range(0, 205).Select(index => new FileItem($"/share/f{index:D4}.txt", $"f{index:D4}.txt", false, 7, DateTimeOffset.UnixEpoch, null, true, true)));
            using var model = new FileBrowserViewModel(source);
            var repository = System.Reflection.DispatchProxy.Create<IDsmRepository, SmokeSelectionDownloadRepository>();
            var fake = (SmokeSelectionDownloadRepository)repository; fake.State = state;
            var save = new SmokeSelectionSavePicker(target) { Cancelled = state == "selection-picker-cancel" };
            using var coordinator = new ForegroundTransferCoordinator(); var profile = SmokeActivityProbe.Profile.ToString(); coordinator.ActivateProfile(profile);
            using var picker = new WindowsTransferPickerService(repository, coordinator, save, new WindowsTransferOpenPicker(() => null));
            var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
            using var page = new FilesPage(model, preview, profile, picker);
            ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(150); await model.OpenLocationAsync("/share");
            while (model.CanLoadMore) await model.LoadMoreAsync(); await Task.Delay(100);
            var flags = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance;
            typeof(FilesPage).GetMethod("ListLayout_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]);
            model.SelectedItem = state == "selection-single-folder" ? model.Items.First(item => item.IsDirectory) : model.Items.First(item => !item.IsDirectory);
            typeof(FilesPage).GetMethod("EnterDownloadSelectionMode", flags)!.Invoke(page, null);
            var list = (ListView)page.FindName("FileList");
            var single = state is "selection-single-file" or "selection-single-folder";
            if (!single) list.SelectAll(); await Task.Delay(100);
            if (list.SelectedItems.Count != (single ? 1 : 206) || !((Button)page.FindName("DownloadSelectedFilesButton")).IsEnabled)
                throw new InvalidOperationException("下载选择被截断或不支持文件夹。");
            if (state == "selection-grid")
            {
                typeof(FilesPage).GetMethod("GridLayout_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]); await Task.Delay(100);
                if (((GridView)page.FindName("FileGrid")).SelectedItems.Count != 206) throw new InvalidOperationException("布局切换丢失选择。");
            }
            if (state is "selection-list" or "selection-grid") { page.UpdateLayout(); await WriteSnapshotAsync(page, markComplete: false); complete = true; return; }
            var expected = list.SelectedItems.Cast<FileBrowserEntry>().Select(item => item.Path).ToHashSet(StringComparer.Ordinal);
            if (state == "selection-changed") save.OnPick = () => list.SelectedItems.Remove(model.Items[^1]);
            if (state == "selection-close-picker")
            {
                page.UpdateLayout(); await WriteSnapshotAsync(page, markComplete: false); save.OnPick = page.Dispose;
            }
            await (Task)typeof(FilesPage).GetMethod("StartSelectedDownloadsAsync", flags)!.Invoke(page, null)!;
            if (state is "selection-changed" or "selection-close-picker" or "selection-picker-cancel")
            {
                await Task.Delay(100);
                if (fake.ArchiveCalls != 0 || fake.FileCalls != 0 || File.ReadAllText(target) != "original") throw new InvalidOperationException("失效或取消选择仍启动了下载。");
                if (state != "selection-close-picker") { page.UpdateLayout(); await WriteSnapshotAsync(page, markComplete: false); }
                complete = true; return;
            }
            for (var index = 0; index < 200 && fake.ArchiveCalls + fake.FileCalls == 0; index++) await Task.Delay(20);
            if (state == "selection-cancel")
            {
                var cancel = ((InfoBar)page.FindName("FileDownloadBatchStatus")).ActionButton as Button ?? throw new InvalidOperationException("缺少下载取消入口。");
                ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(cancel)
                    .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            }
            for (var index = 0; index < 300; index++)
            {
                var activity = coordinator.GetActivities(profile).FirstOrDefault();
                if (activity is not null && activity.State != ForegroundTransferState.Running &&
                    typeof(FilesPage).GetField("_downloadBatchId", flags)!.GetValue(page) is null) break;
                await Task.Delay(20);
            }
            var final = coordinator.GetActivities(profile).Single();
            if (state is "selection-invalid" or "selection-cancel")
            {
                if (final.State != (state == "selection-cancel" ? ForegroundTransferState.Cancelled : ForegroundTransferState.Failed) || File.ReadAllText(target) != "original")
                    throw new InvalidOperationException("失败或取消覆盖了已有文件。");
                if (state == "selection-cancel" && !fake.Cancelled) throw new InvalidOperationException("取消未到达下载来源。");
            }
            else
            {
                if (final.State != ForegroundTransferState.Completed) throw new InvalidOperationException("下载未完成。");
                if (state == "selection-single-file")
                {
                    if (save.UsedArchive || fake.ArchiveCalls != 0 || fake.FileCalls != 1 || File.ReadAllText(target) != "content") throw new InvalidOperationException("单文件没有保持原文件保存。");
                }
                else
                {
                    if (!save.UsedArchive || fake.ArchiveCalls != 1 || !expected.SetEquals(fake.Paths)) throw new InvalidOperationException("ZIP 请求没有包含完整选择。");
                    using var zip = System.IO.Compression.ZipFile.OpenRead(target);
                    if (zip.Entries.Count != expected.Count) throw new InvalidOperationException("保存的 ZIP 项目不完整。");
                }
            }
            page.UpdateLayout(); await WriteSnapshotAsync(page, markComplete: false); complete = true;
        }
        finally
        {
            var basePath = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "lanstash-selection-download-tests")) + Path.DirectorySeparatorChar;
            if (!Path.GetFullPath(directory).StartsWith(basePath, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("合成临时目录超出范围。");
            Directory.Delete(directory, recursive: true);
            if (complete) MarkSnapshotComplete();
        }
    }

    private static async Task SaveFileArchiveAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "archive-form";
        var files = new SmokeDragMoveRepository(); var model = new FileBrowserViewModel(files);
        var large = state.StartsWith("archive-large", StringComparison.Ordinal);
        var formOnly = state is "archive-form" or "archive-large-list" or "archive-large-grid";
        if (large)
        {
            files.Files.Clear();
            files.Files.AddRange(Enumerable.Range(0, 205).Select(index => new FileItem($"/share/f{index:D4}.txt", $"f{index:D4}.txt", false, 7,
                DateTimeOffset.UnixEpoch, null, true, true)));
        }
        var repository = new SmokeArchiveRepository(state);
        var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
        using var coordinator = new ForegroundTransferCoordinator(); var profile = repository.ProfileId.ToString(); coordinator.ActivateProfile(profile);
        var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator, new WindowsTransferSavePicker(() => null), new WindowsTransferOpenPicker(() => null));
        using var page = new FilesPage(model, preview, profile, picker, archiveCompressionRepository: repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(200); await model.OpenLocationAsync("/share"); await Task.Delay(100);
        if (large) { while (model.CanLoadMore) await model.LoadMoreAsync(); await Task.Delay(100); }
        model.SelectedItem = model.Items.First(item => !item.Item.IsDirectory);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        if (large)
        {
            typeof(FilesPage).GetMethod("ListLayout_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]);
            typeof(FilesPage).GetMethod("EnterDownloadSelectionMode", flags)!.Invoke(page, null);
            var downloads = (ListView)page.FindName("FileList"); downloads.SelectAll();
            if (downloads.SelectedItems.Count != 206) throw new InvalidOperationException("多选下载没有保留完整文件与文件夹。");
            typeof(FilesPage).GetMethod("ExitDownloadSelectionMode", flags)!.Invoke(page, null);
            model.SelectedItem = model.Items.First(item => !item.Item.IsDirectory);
        }
        typeof(FilesPage).GetMethod("EnterArchiveCompressionSelectionMode", flags)!.Invoke(page, null);
        if (large)
        {
            var list = (ListView)page.FindName("FileList"); list.SelectAll();
            if (list.SelectedItems.Count != 206 || !((Button)page.FindName("CreateArchiveSelectedButton")).IsEnabled)
                throw new InvalidOperationException("压缩选择仍截断为 20 项或按钮被禁用。");
            typeof(FilesPage).GetMethod("GridLayout_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]);
            if (((GridView)page.FindName("FileGrid")).SelectedItems.Count != 206) throw new InvalidOperationException("大批量选择切换网格后丢失。");
            if (state.EndsWith("list", StringComparison.Ordinal)) typeof(FilesPage).GetMethod("ListLayout_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]);
        }
        var showing = (Task)typeof(FilesPage).GetMethod("ShowArchiveCompressionAsync", flags)!.Invoke(page, null)!;
        await Task.Delay(300);
        var dialog = (ContentDialog?)typeof(FilesPage).GetField("_archiveCompressionDialog", flags)!.GetValue(page)
            ?? throw new InvalidOperationException("压缩窗口未打开。");
        var panel = (StackPanel)((ScrollViewer)dialog.Content).Content;
        var name = panel.Children.OfType<TextBox>().Single();
        var choices = panel.Children.OfType<ComboBox>().ToArray();
        var password = panel.Children.OfType<PasswordBox>().Single();
        if (choices.Length != 2 || choices[0].Items.Count != 2 || choices[1].Items.Count != 4 || repository.Writes != 0 || dialog.ActualTheme != root.ActualTheme)
            throw new InvalidOperationException("压缩格式、级别或主题错误，或未确认即提交。");
        name.Text = "Sample.zip"; choices[0].SelectedIndex = 1; choices[1].SelectedIndex = 3; password.Password = " synthetic ";
        static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
        {
            for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
            { var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i); yield return child; foreach (var nested in Descendants(child)) yield return nested; }
        }
        if (!formOnly)
        {
            if (state == "archive-invalid") name.Text = "../invalid";
            if (state == "archive-large-changed") model.Items[^1] = new FileBrowserEntry(model.Items[^1].Item with { Size = 999 });
            var button = Descendants(dialog).OfType<Button>().Single(item => item.Name == "PrimaryButton");
            var peer = new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button);
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)peer.GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            await Task.Delay(200);
            if (state is "archive-invalid" or "archive-large-changed")
            { if (repository.Writes != 0 || !panel.Children.OfType<InfoBar>().Single().IsOpen) throw new InvalidOperationException("无效名称仍提交或窗口内没有错误提示。"); }
            else
            {
                if (repository.Writes != 1 || password.Password.Length != 0 || !string.IsNullOrEmpty(dialog.PrimaryButtonText))
                    throw new InvalidOperationException("压缩重复提交或密码未清除。");
                if (state != "archive-working")
                {
                    var notice = Descendants(dialog).OfType<InfoBar>().Single();
                    if ((notice.Severity == InfoBarSeverity.Success) != (state == "archive-success" || state.StartsWith("archive-large-success", StringComparison.Ordinal))) throw new InvalidOperationException("压缩结果提示错误。");
                    if (large && (repository.Sources?.Count != 206 || !repository.Sources.Select(item => item.Item.Path).ToHashSet(StringComparer.Ordinal)
                        .SetEquals(files.Files.Select(item => item.Path).Append(files.Target.Path)))) throw new InvalidOperationException("大批量压缩遗漏或替换了所选项目。");
                }
            }
        }
        await WriteSnapshotAsync(dialog, markComplete: false);
        if (state == "archive-working") page.Dispose(); else dialog.Hide();
        await showing;
        if (password.Password.Length != 0) throw new InvalidOperationException("关闭后仍保留密码。");
        MarkSnapshotComplete();
    }

    private static async Task SaveFileDragMoveAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "drag-confirm";
        var repository = new SmokeDragMoveRepository(); var model = new FileBrowserViewModel(repository);
        var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
        using var coordinator = new ForegroundTransferCoordinator(); var profile = repository.ProfileId.ToString(); coordinator.ActivateProfile(profile);
        var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator, new WindowsTransferSavePicker(() => null), new WindowsTransferOpenPicker(() => null));
        using var page = new FilesPage(model, preview, profile, picker, copyMoveRepository: repository, copyMoveFolderSource: repository, copyMoveReviewBlocker: new FileCopyMoveReviewBlocker());
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(200); await model.OpenLocationAsync("/share"); await Task.Delay(100);
        var originals = repository.Files.ToArray(); var target = repository.Target;
        var ticket = page.BeginRemoteMoveDrag(originals) ?? throw new InvalidOperationException("有效拖动无法开始");
        var data = new Windows.ApplicationModel.DataTransfer.DataPackage();
        if (state == "drag-text") data.SetText(originals[0].Path);
        else data.SetData(FileDragMoveSession.DataFormat, state == "drag-forged" ? "forged" : ticket);
        if (state == "drag-stale") await model.RefreshAsync();
        var sources = await page.ResolveRemoteDropAsync(data.GetView(), state == "drag-readonly" ? target with { CanWrite = false } : target);
        if (state is "drag-text" or "drag-forged" or "drag-stale" or "drag-readonly")
        {
            if (sources is not null || repository.Writes.Count != 0) throw new InvalidOperationException("无效拖动仍被接受");
            await WriteSnapshotAsync(page); return;
        }
        if (sources is null || await page.ResolveRemoteDropAsync(data.GetView(), target) is not null) throw new InvalidOperationException("拖动票据不可用或可重放");
        repository.TargetWritable = state != "drag-revoked"; repository.Partial = state == "drag-partial";
        var showing = page.ConfirmRemoteDropAsync(sources, target); await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        ContentDialog Dialog() => (ContentDialog)typeof(FilesPage).GetField("_batchCopyMoveDialog", flags)!.GetValue(page)!;
        var dialog = Dialog();
        if (repository.Writes.Count != 0 || dialog.DefaultButton != ContentDialogButton.Close) throw new InvalidOperationException("拖动未确认就提交或默认按钮不安全");
        if (state == "drag-revoked" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("目标权限被固定为可写");
        static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
        {
            for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
            { var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i); yield return child; foreach (var nested in Descendants(child)) yield return nested; }
        }
        static void Confirm(ContentDialog dialog)
        {
            var button = Descendants(dialog).OfType<Button>().Single(item => item.Name == "PrimaryButton");
            var peer = new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button);
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)peer.GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        }
        if (state is "drag-undo" or "drag-partial")
        {
            Confirm(dialog); await Task.Delay(150);
            if (repository.Writes.Count != 2) throw new InvalidOperationException("确认没有执行恰好两项移动");
        }
        await WriteSnapshotAsync(dialog); dialog.Hide(); await showing;
        var undo = typeof(FilesPage).GetField("_dragMoveUndo", flags)!.GetValue(page);
        if (state == "drag-partial" && undo is not null) throw new InvalidOperationException("部分确认被当作全部可撤销");
        if (state == "drag-undo")
        {
            if (undo is null) throw new InvalidOperationException("成功移动未提供撤销");
            var undoTask = (Task)typeof(FilesPage).GetMethod("UndoDragMoveAsync", flags)!.Invoke(page, [undo])!; await Task.Delay(300);
            dialog = Dialog(); if (!dialog.IsPrimaryButtonEnabled || repository.Writes.Count != 2) throw new InvalidOperationException("撤销目标不可确认或未经确认就提交");
            Confirm(dialog); await Task.Delay(150); dialog.Hide(); await undoTask;
            if (repository.Writes.Count != 4 || repository.Writes.Skip(2).Any(request => !request.Target.Path.StartsWith("/share/target/", StringComparison.Ordinal)) ||
                repository.Files.Any(file => !originals.Any(original => original.Path == file.Path))) throw new InvalidOperationException("撤销未使用移动后路径或未返回原目录");
            await ((Task)typeof(FilesPage).GetMethod("UndoDragMoveAsync", flags)!.Invoke(page, [undo])!);
            if (repository.Writes.Count != 4) throw new InvalidOperationException("撤销票据可被重复提交");
        }
    }

    private static async Task SaveTransferPaginationAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "transfer-pages-initial";
        var downloads = System.Reflection.DispatchProxy.Create<IDownloadStationRepository, SmokeActivityProbe>(); var downloadProbe = (SmokeActivityProbe)downloads;
        var files = System.Reflection.DispatchProxy.Create<IFileBackgroundTaskRepository, SmokeActivityProbe>(); var fileProbe = (SmokeActivityProbe)files;
        downloadProbe.Hold = fileProbe.Hold = false;
        var fail = state is "transfer-pages-error" or "transfer-pages-retry";
        fileProbe.FilePage = (offset, limit) =>
        {
            if (offset > 0 && fail) throw new IOException("合成后页读取失败");
            var count = Math.Min(limit, 250 - offset);
            return new(Enumerable.Range(offset + 1, count).Select(i => new FileBackgroundTaskSummary($"synthetic-file-{i}", FileBackgroundTaskKind.CopyOrMove,
                FileBackgroundTaskState.Active, 0.5, null, null, null, 50, 100)).ToArray(), offset, offset + count, 250, offset + count < 250);
        };
        downloadProbe.DownloadPage = (offset, limit) =>
        {
            if (offset > 0 && fail) throw new IOException("合成后页读取失败");
            var count = Math.Min(limit, 250 - offset);
            return new(Enumerable.Range(offset + 1, count).Select(i => new DownloadTask($"synthetic-download-{i}", $"Synthetic download {i}", "downloading", 100, 50, 1, 0, null, null)).ToArray(),
                offset, count, 250, offset + count < 250 ? offset + count : null, offset + count < 250);
        };
        using var coordinator = new ForegroundTransferCoordinator(); var profile = SmokeActivityProbe.Profile.ToString(); coordinator.ActivateProfile(profile);
        var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator, new WindowsTransferSavePicker(() => null), new WindowsTransferOpenPicker(() => null));
        await using var page = new TransferActivityPage(coordinator, picker, profile, downloads, files);
        ((Frame)shell.FindName("ContentFrame")).Content = page;
        await Task.WhenAll(downloadProbe.Started.Task, fileProbe.Started.Task).WaitAsync(TimeSpan.FromSeconds(2));
        // 等待原生列表入场动画，避免把正常的淡入中间帧当作内容缺失。
        await Task.Delay(400);
        T Control<T>(string name) where T : FrameworkElement => (T)page.FindName(name);
        var list = Control<ListView>("ActivityList"); var firstRow = list.Items[0]; var resets = 0;
        ((System.Collections.Specialized.INotifyCollectionChanged)list.ItemsSource).CollectionChanged += (_, args) =>
        { if (args.Action == System.Collections.Specialized.NotifyCollectionChangedAction.Reset) resets++; };
        void VerifyStableRows()
        { if (resets != 0 || !ReferenceEquals(firstRow, list.Items[0])) throw new InvalidOperationException("活动刷新重建了未变化的列表行。"); }
        if (coordinator.GetActivities(profile).Count != 200) throw new InvalidOperationException("活动首页任务缺失。");
        if (!Control<Button>("DownloadLoadMoreButton").IsEnabled || !Control<Button>("FileLoadMoreButton").IsEnabled) throw new InvalidOperationException("活动加载更多按钮不可用。");
        if (state == "transfer-pages-busy")
        {
            fileProbe.Hold = true; var more = page.LoadMoreNasTasksAsync(false); await Task.Delay(80);
            if (Control<Button>("FileLoadMoreButton").IsEnabled) throw new InvalidOperationException("分页读取中未禁用按钮。");
            VerifyStableRows();
            await WriteSnapshotAsync(page); await page.SetWindowVisibleAsync(false).WaitAsync(TimeSpan.FromSeconds(2)); await more;
            if (coordinator.GetActivities(profile).Count != 200) throw new InvalidOperationException("隐藏后的后页被提交。"); return;
        }
        if (state != "transfer-pages-initial")
        {
            await page.LoadMoreNasTasksAsync(false); await page.LoadMoreNasTasksAsync(true);
            if (fail)
            {
                if (coordinator.GetActivities(profile).Count != 200 || !Control<InfoBar>("FileRefreshErrorNotice").IsOpen || !Control<InfoBar>("DownloadRefreshErrorNotice").IsOpen)
                    throw new InvalidOperationException("后页失败未保留旧任务或未显示错误。");
                if (state == "transfer-pages-retry") { fail = false; await page.LoadMoreNasTasksAsync(false); await page.LoadMoreNasTasksAsync(true); }
            }
            if (!fail && coordinator.GetActivities(profile).Count != 400) throw new InvalidOperationException("加载后页丢失了首页任务。");
            if (state == "transfer-pages-all")
            {
                await page.LoadMoreNasTasksAsync(false); await page.LoadMoreNasTasksAsync(true);
                if (coordinator.GetActivities(profile).Count != 500 || Control<InfoBar>("FileTruncatedNotice").IsOpen || Control<InfoBar>("DownloadTruncatedNotice").IsOpen)
                    throw new InvalidOperationException("末页没有正确收束。");
            }
            if (state == "transfer-pages-refresh")
            {
                await page.SetWindowVisibleAsync(false); await page.SetWindowVisibleAsync(true);
                if (coordinator.GetActivities(profile).Count != 400 || fileProbe.Reads != 4 || downloadProbe.Reads != 4)
                    throw new InvalidOperationException("自动刷新缩回首页或未刷新展开范围。");
            }
        }
        VerifyStableRows();
        if (list.Items.Count != coordinator.GetActivities(profile).Count) throw new InvalidOperationException("活动界面条目与已读任务不一致。");
        await WriteSnapshotAsync(page);
    }

    private static async Task SaveTransferLifecycleAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "transfer-hide";
        var downloads = System.Reflection.DispatchProxy.Create<IDownloadStationRepository, SmokeActivityProbe>(); var downloadProbe = (SmokeActivityProbe)downloads;
        var files = System.Reflection.DispatchProxy.Create<IFileBackgroundTaskRepository, SmokeActivityProbe>(); var fileProbe = (SmokeActivityProbe)files;
        downloadProbe.IgnoreCancellation = fileProbe.IgnoreCancellation = state == "transfer-dispose-drain";
        using var coordinator = new ForegroundTransferCoordinator(); var profile = SmokeActivityProbe.Profile.ToString(); coordinator.ActivateProfile(profile);
        var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator, new WindowsTransferSavePicker(() => null), new WindowsTransferOpenPicker(() => null));
        await using var page = new TransferActivityPage(coordinator, picker, profile, downloads, files);
        var frame = (Frame)shell.FindName("ContentFrame"); frame.Content = page;
        await Task.WhenAll(downloadProbe.Started.Task, fileProbe.Started.Task).WaitAsync(TimeSpan.FromSeconds(2));
        if (state is "transfer-dispose" or "transfer-dispose-drain")
        {
            var disposing = page.DisposeAsync().AsTask();
            var secondDispose = page.DisposeAsync().AsTask();
            try
            {
                await Task.WhenAll(downloadProbe.Cancelled.Task, fileProbe.Cancelled.Task).WaitAsync(TimeSpan.FromSeconds(2));
                if (state == "transfer-dispose-drain" && (disposing.IsCompleted || secondDispose.IsCompleted)) throw new InvalidOperationException("销毁没有等待未退出的读取。");
            }
            finally { downloadProbe.Release.TrySetResult(); fileProbe.Release.TrySetResult(); }
            await Task.WhenAll(disposing, secondDispose).WaitAsync(TimeSpan.FromSeconds(2));
        }
        else
        {
            var hiding = page.SetWindowVisibleAsync(false);
            try { await Task.WhenAll(downloadProbe.Cancelled.Task, fileProbe.Cancelled.Task).WaitAsync(TimeSpan.FromSeconds(2)); }
            catch (TimeoutException)
            {
                throw new InvalidOperationException($"隐藏后未取消读取：download={downloadProbe.LastToken.IsCancellationRequested}, file={fileProbe.LastToken.IsCancellationRequested}, hideCompleted={hiding.IsCompleted}");
            }
            await hiding.WaitAsync(TimeSpan.FromSeconds(2));
            if (state == "transfer-restart")
            {
                downloadProbe.Hold = fileProbe.Hold = false;
                await page.SetWindowVisibleAsync(true).WaitAsync(TimeSpan.FromSeconds(2));
                if (downloadProbe.Reads != 2 || fileProbe.Reads != 2) throw new InvalidOperationException("恢复可见性未启动新读取。");
            }
        }
        if (coordinator.GetActivities(profile).Count != 0) throw new InvalidOperationException("过期读取污染了活动。");
        await WriteSnapshotAsync(page);
    }

    private static async Task SaveContainerNetworksAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE"); var repository = new SmokeRepository();
        using var page = new ContainerManagerPage(repository);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(350);
        ((Pivot)page.FindName("SectionPivot")).SelectedIndex = 3; await Task.Delay(150);
        var list = (ListView)page.FindName("NetworksList");
        var expected = state switch { "network-loading" => "NetworksLoadingState", "network-error" => "NetworksErrorState",
            "network-empty" => "NetworksEmptyState", "network-unavailable" => "NetworksUnavailableState", _ => "NetworksList" };
        if (((FrameworkElement)page.FindName(expected)).Visibility != Visibility.Visible) throw new InvalidOperationException("网络分区状态错误。");
        if (expected == "NetworksList")
        {
            if (list.Items.Count != 1) throw new InvalidOperationException("网络条目缺失。");
            page.UpdateLayout();
            static IEnumerable<DependencyObject> Children(DependencyObject parent)
            {
                for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); index++)
                {
                    var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, index); yield return child;
                    foreach (var descendant in Children(child)) yield return descendant;
                }
            }
            var expander = Children(list).OfType<Expander>().Single(); expander.IsExpanded = true; await Task.Delay(250);
            var item = (LanStash.App.Features.Containers.ContainerResourceItem)list.Items[0];
            var texts = Children(expander).OfType<TextBlock>().Select(block => block.Text).ToArray();
            if (!texts.Contains(item.SubnetText) || !texts.Contains(item.ConnectionsText) || !texts.Contains(item.Ipv6Text)) throw new InvalidOperationException("展开网络缺少详情绑定。");
            if (state == "network-zero" && item.ConnectionsText != Localization.LocalizationService.Current.Get("ContainerNetworkNoConnections")) throw new InvalidOperationException("已知空关联未正确显示。");
            if (state is "network-unknown" or "network-legacy" && item.ConnectionsText != Localization.LocalizationService.Current.Get("ContainerNetworkNamesUnavailable")) throw new InvalidOperationException("未知关联被补成空。");
            if (state == "network-details" && (!texts.Contains("192.0.2.0/24") || !item.ConnectionsText.Contains("synthetic-db", StringComparison.Ordinal))) throw new InvalidOperationException("网络详情字段丢失。");
        }
        if (repository.ContainerReadCount != 1) throw new InvalidOperationException("展开网络触发额外读取。");
        if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_LANGUAGE") is { Length: > 0 } language && Localization.LocalizationService.Current.ResolvedLanguage != language)
            throw new InvalidOperationException("网络场景语言不符。");
        await WriteSnapshotAsync(root);
    }

    private static async Task SaveNasServiceSettingsAsync(FrameworkElement root)
    {
        // 用实际 PRI/MRT 验证旧文件、照片和设置调用方的点分属性键，不以 resw 静态扫描替代。
        foreach (var key in new[] { "FileMoveUndoButton.Text", "ActionDelete.Label", "PhotoTimelineLoading.Text",
                     "FileRecycleBatchMoveMultiple.Label", "FileRecycleBatchMoveSelected.Label",
                     "FileBrowserCancelDownloadSelection.Label", "ActionReload.Content" })
        {
            var value = Localization.LocalizationService.Current.Get(key);
            if (string.IsNullOrWhiteSpace(value) || value == key) throw new InvalidOperationException("运行时属性资源读取失败。");
        }
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "terminal";
        var repository = System.Reflection.DispatchProxy.Create<INasSettingsRepository, SmokeNasServiceSettingsRepository>();
        var fake = (SmokeNasServiceSettingsRepository)(object)repository;
        fake.State = state;
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var frame = (Frame)shell.FindName("ContentFrame");
        using var page = new NasDetailsPage(new SmokeRepository(), repository);
        frame.Content = page;
        await Task.Delay(200);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var fileServices = state.StartsWith("file-", StringComparison.Ordinal);
        var region = state.StartsWith("region-", StringComparison.Ordinal);
        var network = state.StartsWith("network-", StringComparison.Ordinal);
        var security = state.StartsWith("security-", StringComparison.Ordinal);
        var hardware = state.StartsWith("hardware-", StringComparison.Ordinal);
        var ddns = state.StartsWith("ddns-", StringComparison.Ordinal);
        var packages = state.StartsWith("pkg-", StringComparison.Ordinal);
        var directory = state.StartsWith("dir-", StringComparison.Ordinal);
        var power = state.StartsWith("power-", StringComparison.Ordinal);
        var connections = state.StartsWith("conn-", StringComparison.Ordinal);
        var tasks = state.StartsWith("task-", StringComparison.Ordinal);
        var disks = state.StartsWith("disk-", StringComparison.Ordinal);
        var remote = state.StartsWith("remote-", StringComparison.Ordinal);
        var powerSchedule = state.StartsWith("powsched-", StringComparison.Ordinal);
        var externalStorage = state.StartsWith("extstore-", StringComparison.Ordinal);
        var zram = state.StartsWith("zram-", StringComparison.Ordinal);
        if ((tasks || disks || remote || powerSchedule || externalStorage || zram) && Environment.GetEnvironmentVariable("LANSTASH_SMOKE_LANGUAGE") is { Length: > 0 } expectedLanguage &&
            Localization.LocalizationService.Current.ResolvedLanguage != expectedLanguage)
            throw new InvalidOperationException("合成任务窗口没有应用要求的语言。");
        var opened = (Task)typeof(NasDetailsPage).GetMethod(zram ? "ShowZramAsync" : externalStorage ? "ShowExternalStorageAsync" : powerSchedule ? "ShowPowerScheduleAsync" : remote ? "ShowRemoteAccessAsync" : disks ? "ShowDiskTestsAsync" : tasks ? "ShowTasksSettingsAsync" : connections ? "ShowConnectionsSettingsAsync" : power ? "ShowPowerSettingsAsync" : directory ? "ShowDirectorySettingsAsync" : packages ? "ShowPackageSettingsAsync" : ddns ? "ShowDdnsDialogAsync" : hardware ? "ShowHardwareSettingsAsync" : security ? "ShowSecuritySettingsAsync" : network ? "ShowNetworkSettingsAsync" : region ? "ShowRegionSettingsAsync" :
            fileServices ? "ShowFileServiceSettingsAsync" : "ShowServiceSettingsAsync", flags)!
            .Invoke(page, fileServices || region || network || security || hardware || ddns || packages || directory || power || connections || tasks || disks || remote || powerSchedule || externalStorage || zram ? null : [!state.StartsWith("proxy", StringComparison.Ordinal)])!;
        await Task.Delay(350);
        if (opened.IsCompleted) await opened;
        var dialog = (ContentDialog)typeof(NasDetailsPage).GetField("_serviceSettingsDialog", flags)!.GetValue(page)!;
        if (zram)
        {
            var zramContent = (NasZramDialogContent)dialog.Content;
            T Control<T>(string name) where T : FrameworkElement => (T)zramContent.FindName(name);
            if (!string.IsNullOrEmpty(dialog.PrimaryButtonText) || zramContent.CanSave || dialog.DefaultButton != ContentDialogButton.Close) throw new InvalidOperationException("内存压缩存在写入口。");
            if (state == "zram-loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("内存压缩加载状态缺失。");
            if (state == "zram-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("内存压缩错误状态缺失。");
            if (state == "zram-unavailable" && Control<TextBlock>("UnsupportedNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("内存压缩不支持状态缺失。");
            if (state == "zram-empty" && (Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible || Control<StackPanel>("ContentPanel").Visibility == Visibility.Visible)) throw new InvalidOperationException("空信息被补造成关闭状态。");
            if (state == "zram-partial" && Control<TextBlock>("StatusText").Text != Localization.LocalizationService.Current.Get("UnknownValue")) throw new InvalidOperationException("未知状态被当作关闭。");
            if (state == "zram-disabled" && Control<TextBlock>("StatusText").Text != Localization.LocalizationService.Current.Get("NasZramDisabled")) throw new InvalidOperationException("明确关闭状态丢失。");
            if (state == "zram-content" && Control<TextBlock>("AlgorithmText").Text != Localization.LocalizationService.Current.Get("NasZramLz4")) throw new InvalidOperationException("算法未显示。");
            if (state == "zram-refresh") { await zramContent.ReloadAsync(); if (fake.ZramReads != 2) throw new InvalidOperationException("内存压缩刷新次数错误。"); }
            await zramContent.SaveAsync(); if (fake.Writes != 0) throw new InvalidOperationException("内存压缩触发写入。");
            await Task.Delay(100); await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; return;
        }
        if (externalStorage)
        {
            var storageContent = (NasExternalStorageDialogContent)dialog.Content;
            T Control<T>(string name) where T : FrameworkElement => (T)storageContent.FindName(name);
            var filter = Control<ComboBox>("FilterChoice"); var list = Control<ListView>("DeviceList");
            if (!string.IsNullOrEmpty(dialog.PrimaryButtonText) || storageContent.CanSave || dialog.DefaultButton != ContentDialogButton.Close) throw new InvalidOperationException("外接存储存在写入口。");
            if (state == "extstore-usb") filter.SelectedIndex = 1;
            if (state is "extstore-esata" or "extstore-filtered" or "extstore-filtered-unavailable") filter.SelectedIndex = 2;
            if (state is "extstore-usb" or "extstore-esata" && list.Items.Count != 1) throw new InvalidOperationException("外接存储类型筛选错误。");
            if (state is "extstore-empty" or "extstore-filtered" or "extstore-partial-empty" or "extstore-filtered-unavailable" && Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("外接存储空状态缺失。");
            if (state.StartsWith("extstore-partial", StringComparison.Ordinal) || state == "extstore-filtered-unavailable")
                if (Control<TextBlock>("PartialNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("局部不可用提示缺失。");
            if (state == "extstore-loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("外接存储加载状态缺失。");
            if (state == "extstore-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("外接存储错误状态缺失。");
            if (state == "extstore-unavailable" && Control<TextBlock>("UnsupportedNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("外接存储不支持状态缺失。");
            if (state == "extstore-truncated" && Control<TextBlock>("IncompleteNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("外接存储截断未说明。");
            if (state == "extstore-refresh") { await storageContent.ReloadAsync(); if (fake.ExternalStorageReads != 2) throw new InvalidOperationException("外接存储刷新次数错误。"); }
            await storageContent.SaveAsync(); if (fake.Writes != 0) throw new InvalidOperationException("外接存储触发写入。");
            await Task.Delay(100); await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; return;
        }
        if (powerSchedule)
        {
            var scheduleContent = (NasPowerScheduleDialogContent)dialog.Content;
            T Control<T>(string name) where T : FrameworkElement => (T)scheduleContent.FindName(name);
            if (!string.IsNullOrEmpty(dialog.PrimaryButtonText) || scheduleContent.CanSave || dialog.DefaultButton != ContentDialogButton.Close) throw new InvalidOperationException("电源计划存在写入口。");
            var filter = Control<ComboBox>("FilterChoice"); var list = Control<ListView>("ScheduleList");
            if (state == "powsched-enabled") filter.SelectedIndex = 1;
            if (state == "powsched-disabled") filter.SelectedIndex = 2;
            if (state == "powsched-filtered") filter.SelectedIndex = 1;
            if (state is "powsched-enabled" or "powsched-disabled" && list.Items.Count != 1) throw new InvalidOperationException("电源计划筛选包含未知状态。");
            if (state is "powsched-filtered" or "powsched-empty" && Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("电源计划空状态缺失。");
            if (state == "powsched-loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("电源计划加载状态缺失。");
            if (state == "powsched-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("电源计划错误状态缺失。");
            if (state == "powsched-unavailable" && Control<TextBlock>("UnsupportedNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("电源计划不可用状态缺失。");
            if (state == "powsched-partial" && Control<TextBlock>("IncompleteNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("电源计划遗漏截断提示。");
            if (state == "powsched-unknown" && Control<TextBlock>("TimeZoneText").Text.Contains("Asia/Shanghai", StringComparison.Ordinal)) throw new InvalidOperationException("未知时区被补造。");
            if (state == "powsched-refresh") { await scheduleContent.ReloadAsync(); if (fake.PowerScheduleReads != 2) throw new InvalidOperationException("电源计划刷新次数错误。"); }
            await scheduleContent.SaveAsync(); if (fake.Writes != 0) throw new InvalidOperationException("电源计划触发写入。");
            await Task.Delay(100); await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; return;
        }
        if (remote)
        {
            var remoteContent = (NasRemoteAccessDialogContent)dialog.Content;
            T Control<T>(string name) where T : FrameworkElement => (T)remoteContent.FindName(name);
            var relay = Control<ToggleSwitch>("RelayToggle"); var router = Control<ToggleSwitch>("RouterToggle"); var risk = Control<CheckBox>("RiskAcknowledgement");
            if (dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("远程访问主题或默认操作错误。");
            if (state == "remote-loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("远程访问加载状态缺失。");
            if (state == "remote-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("远程访问错误状态缺失。");
            if (state == "remote-empty" && Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("远程访问空状态缺失。");
            if (state == "remote-readonly" && (relay.IsEnabled || router.IsEnabled || remoteContent.CanSave)) throw new InvalidOperationException("只读表单开放修改。");
            if (state is "remote-partial-read" or "remote-failed-fields" && relay.Visibility != Visibility.Collapsed) throw new InvalidOperationException("未知中继显示成关闭开关。");
            if (state is "remote-only-relay" or "remote-failed-fields" && router.Visibility != Visibility.Collapsed) throw new InvalidOperationException("未知路由器设置显示成关闭开关。");
            if (state == "remote-pending" && (!Control<InfoBar>("PendingNotice").IsOpen || relay.IsEnabled || router.IsEnabled)) throw new InvalidOperationException("待核查设置未锁定。");
            if (state == "remote-recovered" && (relay.IsOn || !router.IsOn || !Control<InfoBar>("FeedbackNotice").IsOpen)) throw new InvalidOperationException("恢复后未显示核对结果。");
            if (state is "remote-relay" or "remote-relay-save")
            {
                if (relay.IsEnabled || Control<TextBlock>("RelayProtection").Visibility != Visibility.Visible) throw new InvalidOperationException("当前中继连接没有保护。");
                relay.IsOn = false; await remoteContent.SaveAsync(); if (fake.Writes != 0) throw new InvalidOperationException("禁用的中继开关绕过保护。");
            }
            if (state is "remote-save" or "remote-confirm" or "remote-partial" or "remote-unknown" or "remote-rejected" or "remote-late-change" or
                "remote-relay-save" or "remote-partial-read" or "remote-only-relay" or "remote-close-busy" or "remote-save-read-error")
            {
                if (relay.IsEnabled) relay.IsOn = false;
                if (router.IsEnabled) router.IsOn = true;
                await remoteContent.SaveAsync(); if (fake.Writes != 0) throw new InvalidOperationException("远程访问保存缺少确认。");
                risk.IsChecked = true;
                if (!remoteContent.CanSave || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("确认后的远程访问表单不能保存。");
                if (state == "remote-late-change")
                {
                    router.IsOn = false; await remoteContent.SaveAsync(); if (fake.Writes != 0 || risk.IsChecked == true) throw new InvalidOperationException("修改后沿用旧确认。");
                }
                else if (state == "remote-confirm")
                {
                    if (!risk.Focus(FocusState.Keyboard)) throw new InvalidOperationException("确认框无法键盘聚焦。");
                    await Task.Delay(150);
                    if (!remoteContent.CanSave || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("控件事件完成后确认失效。");
                }
                else
                {
                    var saving = remoteContent.SaveAsync();
                    if (state == "remote-close-busy")
                    {
                        await Task.Delay(80); await remoteContent.SaveAsync(); if (fake.Writes != 1) throw new InvalidOperationException("保存期间重复发送。");
                        await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; await saving;
                        if (!fake.RemoteCancelled) throw new InvalidOperationException("关闭没有取消保存等待。"); return;
                    }
                    await saving; await remoteContent.SaveAsync(); if (fake.Writes != 1) throw new InvalidOperationException("远程访问保存重复提交。");
                    if (!Control<InfoBar>("FeedbackNotice").IsOpen) throw new InvalidOperationException("远程访问保存缺少反馈。");
                    if (state == "remote-relay-save" && fake.RemoteRequest?.Desired.RelayEnabled != true) throw new InvalidOperationException("当前中继被关闭。");
                    if (state == "remote-partial-read" && fake.RemoteRequest?.Desired.RelayEnabled is not null) throw new InvalidOperationException("未知字段被填入默认值。");
                    if (state == "remote-partial" && (relay.IsOn || router.IsOn)) throw new InvalidOperationException("部分成功未显示实际回读。");
                    if (state == "remote-unknown")
                    {
                        if (!Control<InfoBar>("PendingNotice").IsOpen || !relay.IsOn || router.IsOn) throw new InvalidOperationException("未知保存没有保持最后读取快照。");
                        await remoteContent.ReloadAsync(); await remoteContent.SaveAsync(); if (fake.Writes != 1 || remoteContent.CanSave) throw new InvalidOperationException("核查重放保存。");
                    }
                    if (state == "remote-save-read-error" && (Control<InfoBar>("FeedbackNotice").Severity != InfoBarSeverity.Success || !Control<InfoBar>("ErrorNotice").IsOpen)) throw new InvalidOperationException("读取失败覆盖了已核对保存结果。");
                }
            }
            await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; return;
        }
        if (disks)
        {
            var diskContent = (NasDiskTestsDialogContent)dialog.Content;
            T Control<T>(string name) where T : FrameworkElement => (T)diskContent.FindName(name);
            void Click(string name) => typeof(NasDiskTestsDialogContent).GetMethod(name, flags)!.Invoke(diskContent, [diskContent, new RoutedEventArgs()]);
            if (!string.IsNullOrEmpty(dialog.PrimaryButtonText) || dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme)
                throw new InvalidOperationException("硬盘检测默认按钮或主题错误。");
            var list = Control<ListView>("DiskList"); if (list.Items.Count > 0) list.SelectedIndex = 0;
            await Task.Delay(60);
            if (fake.DiskHistoryReads != 0) throw new InvalidOperationException("选择硬盘预读了历史。");
            if (state == "disk-loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("硬盘加载状态缺失。");
            if (state is "disk-error" or "disk-state-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("硬盘错误状态缺失。");
            if (state == "disk-empty" && Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("硬盘空状态缺失。");
            if (state == "disk-filter")
            {
                Control<TextBox>("SearchInput").Text = "no-match"; await Task.Delay(60);
                if (list.Items.Count != 0 || Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("硬盘筛选空状态缺失。");
            }
            if (state is "disk-readonly" or "disk-busy" or "disk-busy-unknown" or "disk-unsupported" or "disk-state-error")
                if (Control<Button>("QuickButton").IsEnabled || Control<Button>("ExtendedButton").IsEnabled) throw new InvalidOperationException("未知或只读硬盘开放启动。");
            if (state.StartsWith("disk-history", StringComparison.Ordinal))
            {
                Click("History_Click"); await Task.Delay(60);
                if (state == "disk-history-error") { if (!Control<InfoBar>("HistoryErrorNotice").IsOpen) throw new InvalidOperationException("硬盘历史错误未显示。"); }
                else if (Control<StackPanel>("HistoryPanel").Visibility != Visibility.Visible) throw new InvalidOperationException("硬盘历史未显示。");
                if (state == "disk-history-empty" && Control<TextBlock>("EmptyHistory").Visibility != Visibility.Visible) throw new InvalidOperationException("空历史未显示。");
                if (state == "disk-history-partial" && Control<TextBlock>("TruncatedHistory").Visibility != Visibility.Visible) throw new InvalidOperationException("历史截断未显示。");
            }
            if (state is "disk-quick" or "disk-extended" or "disk-stop" or "disk-unknown" or "disk-rejected" or "disk-switch" or "disk-late-filter" or "disk-close-busy" or "disk-confirm")
            {
                Click(state == "disk-stop" ? "Stop_Click" : state == "disk-extended" ? "Extended_Click" : "Quick_Click");
                Click("Execute_Click"); if (fake.Writes != 0) throw new InvalidOperationException("硬盘操作缺少确认。");
                Control<CheckBox>("RiskAcknowledgement").IsChecked = true; await Task.Delay(40);
                var execute = Control<Button>("ExecuteButton");
                if (!execute.IsEnabled) throw new InvalidOperationException("硬盘操作无法确认。");
                if (state == "disk-switch")
                {
                    list.SelectedIndex = 1; await Task.Delay(40); Click("Execute_Click");
                    if (fake.Writes != 0 || Control<CheckBox>("RiskAcknowledgement").IsChecked == true) throw new InvalidOperationException("切换硬盘沿用旧确认。");
                }
                else if (state == "disk-late-filter")
                {
                    Control<TextBox>("SearchInput").Text = "no-match"; Click("Execute_Click");
                    if (fake.Writes != 0) throw new InvalidOperationException("搜索隐藏硬盘后仍提交。");
                }
                else if (state == "disk-confirm")
                {
                    if (!execute.Focus(FocusState.Keyboard)) throw new InvalidOperationException("硬盘确认按钮无法键盘聚焦。");
                    execute.StartBringIntoView(); await Task.Delay(120);
                }
                else
                {
                    Click("Execute_Click"); await Task.Delay(80); Click("Execute_Click");
                    if (fake.Writes != 1) throw new InvalidOperationException("硬盘重复提交。");
                    if (state == "disk-close-busy")
                    {
                        await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; await Task.Delay(80);
                        if (!fake.DiskCancelled) throw new InvalidOperationException("关闭硬盘面板未取消等待。"); return;
                    }
                    if (!Control<InfoBar>("FeedbackNotice").IsOpen) throw new InvalidOperationException("硬盘结果无反馈。");
                    await diskContent.ReloadAsync(); if (fake.Writes != 1) throw new InvalidOperationException("硬盘核查重发写请求。");
                    if (state == "disk-unknown" && !Control<InfoBar>("PendingNotice").IsOpen) throw new InvalidOperationException("未确认硬盘操作未保留。");
                }
            }
            await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; return;
        }
        if (tasks)
        {
            var taskContent = (NasTasksSettingsDialogContent)dialog.Content;
            T Control<T>(string name) where T : FrameworkElement => (T)taskContent.FindName(name);
            void Click(string name) => typeof(NasTasksSettingsDialogContent).GetMethod(name, flags)!.Invoke(taskContent, [taskContent, new RoutedEventArgs()]);
            if (!string.IsNullOrEmpty(dialog.PrimaryButtonText) || dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme)
                throw new InvalidOperationException("任务管理默认按钮或主题错误。");
            var list = Control<ListView>("TaskList"); if (list.Items.Count > 0) list.SelectedIndex = 0;
            if (state == "task-loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("任务加载状态缺失。");
            if (state == "task-error" && !Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("任务错误状态缺失。");
            if (state == "task-empty" && Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("任务空状态缺失。");
            if (state == "task-filter")
            {
                Control<TextBox>("SearchInput").Text = "no-match"; await Task.Delay(60);
                if (list.Items.Count != 0 || Control<TextBlock>("EmptyNotice").Visibility != Visibility.Visible) throw new InvalidOperationException("任务筛选空状态缺失。");
            }
            if (state is "task-detail" or "task-readonly" or "task-detail-error")
            {
                Click("Detail_Click"); await Task.Delay(60);
                if (state == "task-detail-error") { if (!Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("详情错误未显示。"); }
                else if (Control<TextBox>("ScriptInput").Text != "synthetic-script" || !Control<TextBox>("ScriptInput").IsReadOnly) throw new InvalidOperationException("任务只读详情不完整。");
                if (state == "task-readonly" && Control<Button>("RunButton").IsEnabled) throw new InvalidOperationException("只读任务开放写入。");
            }
            if (state is "task-history" or "task-output" or "task-no-history")
            {
                Click("Results_Click"); await Task.Delay(60); if (fake.TaskOutputReads != 0) throw new InvalidOperationException("记录预读了输出。");
                var results = Control<ListView>("ResultList");
                if (state == "task-no-history" && Control<TextBlock>("EmptyHistory").Visibility != Visibility.Visible) throw new InvalidOperationException("记录空状态缺失。");
                if (state == "task-output")
                {
                    results.SelectedIndex = 0; await Task.Delay(60);
                    if (fake.TaskOutputReads != 1 || Control<TextBox>("ResultOutput").Text != "synthetic-output") throw new InvalidOperationException("输出未按选中记录读取。");
                }
            }
            if (state is "task-create" or "task-edit" or "task-edit-preview" or "task-late-edit" or "task-invalid")
            {
                Click(state == "task-create" ? "Create_Click" : "Edit_Click"); await Task.Delay(60);
                if (state == "task-create") Control<TextBox>("NameInput").Text = "new-synthetic-task";
                Control<TextBox>("ScriptInput").Text = "changed-script"; await Task.Delay(60);
                if (state == "task-invalid") Control<TextBox>("ScriptInput").Text = "";
                Click("Execute_Click"); if (fake.Writes != 0) throw new InvalidOperationException("任务保存缺少确认。");
                Control<CheckBox>("RiskAcknowledgement").IsChecked = true;
                if (state == "task-invalid") { if (Control<Button>("ExecuteButton").IsEnabled) throw new InvalidOperationException("空脚本可保存。"); }
                else
                {
                    if (!Control<Button>("ExecuteButton").IsEnabled) throw new InvalidOperationException("确认后不能保存任务。");
                    if (state == "task-late-edit")
                    {
                        Control<TextBox>("ScriptInput").Text = "late-change"; Click("Execute_Click");
                        if (fake.Writes != 0) throw new InvalidOperationException("修改后沿用了旧确认。");
                    }
                    else if (state != "task-edit-preview")
                    {
                        Click("Execute_Click"); await Task.Delay(80); Click("Execute_Click");
                        if (fake.Writes != 1 || fake.TaskSave?.Desired.Script != "changed-script" || Control<TextBox>("ScriptInput").Text.Length != 0)
                            throw new InvalidOperationException("保存任务未绑定草稿或未清除脚本。");
                    }
                }
            }
            if (state is "task-enable" or "task-disable" or "task-run" or "task-delete" or "task-unknown" or "task-rejected")
            {
                Click(state == "task-enable" ? "Enable_Click" : state == "task-disable" ? "Disable_Click" : state == "task-delete" ? "Delete_Click" : "Run_Click"); await Task.Delay(60);
                Click("Execute_Click"); if (fake.Writes != 0) throw new InvalidOperationException("任务命令缺少确认。");
                Control<CheckBox>("RiskAcknowledgement").IsChecked = true;
                if (!Control<Button>("ExecuteButton").IsEnabled) throw new InvalidOperationException("任务命令无法确认。");
                Click("Execute_Click"); await Task.Delay(80); Click("Execute_Click");
                if (fake.Writes != 1 || !Control<InfoBar>("FeedbackNotice").IsOpen) throw new InvalidOperationException("任务命令重复提交或无反馈。");
                await taskContent.ReloadAsync(); if (fake.Writes != 1) throw new InvalidOperationException("任务刷新重放命令。");
                if (state == "task-unknown" && !Control<InfoBar>("PendingNotice").IsOpen) throw new InvalidOperationException("未知任务操作没有保留核查状态。");
            }
            if (state == "task-edit-preview")
            {
                var execute = Control<Button>("ExecuteButton");
                if (!execute.Focus(FocusState.Keyboard)) throw new InvalidOperationException("任务确认按钮无法键盘聚焦。");
                execute.StartBringIntoView(); await Task.Delay(120);
            }
            await WriteSnapshotAsync(dialog); Click("CloseDetail_Click");
            if (Control<TextBox>("ScriptInput").Text.Length != 0 || Control<StackPanel>("OutputPanel").Visibility != Visibility.Collapsed) throw new InvalidOperationException("关闭后敏感详情残留。");
            page.Deactivate(); await opened; return;
        }
        if (connections)
        {
            var connectionContent = (NasConnectionsSettingsDialogContent)dialog.Content;
            if (!string.IsNullOrEmpty(dialog.PrimaryButtonText) || dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme)
                throw new InvalidOperationException("连接管理默认按钮或主题错误。");
            var list = (ListView)connectionContent.FindName("ConnectionList"); if (list.Items.Count > 0) list.SelectedIndex = 0;
            void Click() => typeof(NasConnectionsSettingsDialogContent).GetMethod("Disconnect_Click", flags)!.Invoke(connectionContent, [connectionContent, new RoutedEventArgs()]);
            var risk = (CheckBox)connectionContent.FindName("RiskAcknowledgement"); var current = (CheckBox)connectionContent.FindName("CurrentSessionAcknowledgement");
            var button = (Button)connectionContent.FindName("DisconnectButton");
            if (state == "conn-loading" && !((ProgressRing)connectionContent.FindName("LoadingIndicator")).IsActive) throw new InvalidOperationException("连接加载状态缺失。");
            if (state == "conn-error" && !((InfoBar)connectionContent.FindName("ErrorNotice")).IsOpen) throw new InvalidOperationException("连接读取错误缺失。");
            if (state == "conn-partial" && ((TextBlock)connectionContent.FindName("PartialNotice")).Visibility != Visibility.Visible) throw new InvalidOperationException("不完整连接列表没有提示。");
            if (state == "conn-search") { ((TextBox)connectionContent.FindName("SearchInput")).Text = "no-match"; await Task.Delay(80); }
            if (state is "conn-empty" or "conn-search" && ((TextBlock)connectionContent.FindName("EmptyNotice")).Visibility != Visibility.Visible) throw new InvalidOperationException("连接空状态缺失。");
            foreach (var row in list.Items.OfType<NasConnectionSettingsRow>())
                if (row.AutomationName.Contains("private-device", StringComparison.Ordinal) || row.AutomationName.Contains("private-process", StringComparison.Ordinal)) throw new InvalidOperationException("连接显示泄露原始标识。");
            if (state is "conn-readonly" or "conn-partial" or "conn-missing" or "conn-ambiguous" or "conn-pending")
            {
                risk.IsChecked = true; current.IsChecked = true; Click();
                if (fake.Writes != 0 || button.IsEnabled) throw new InvalidOperationException("只读/未知/不完整连接可以断开。");
            }
            if (state == "conn-recovered" && (!((InfoBar)connectionContent.FindName("FeedbackNotice")).IsOpen || list.Items.Count != 0)) throw new InvalidOperationException("消失连接恢复反馈缺失。");
            if (state is "conn-web" or "conn-service" or "conn-current" or "conn-current-reversed" or "conn-unknown-current" or "conn-unknown" or "conn-rejected" or "conn-conflict" or "conn-switch-target" or "conn-late-search" or "conn-close-busy")
            {
                Click(); if (fake.Writes != 0) throw new InvalidOperationException("连接未经确认即断开。");
                if (state == "conn-current-reversed") { current.IsChecked = true; if (button.IsEnabled) throw new InvalidOperationException("只确认当前会话即可断开。"); }
                risk.IsChecked = true;
                if (state is "conn-current" or "conn-unknown-current")
                {
                    if (button.IsEnabled || current.Visibility != Visibility.Visible) throw new InvalidOperationException("当前或未知连接未要求额外确认。");
                    current.IsChecked = true;
                }
                if (!button.IsEnabled) throw new InvalidOperationException("完成确认后无法断开连接。");
                if (state == "conn-switch-target")
                {
                    list.SelectedIndex = 1; Click(); if (fake.Writes != 0 || risk.IsChecked == true) throw new InvalidOperationException("切换连接沿用旧确认。"); risk.IsChecked = true;
                }
                if (state == "conn-late-search")
                {
                    ((TextBox)connectionContent.FindName("SearchInput")).Text = "no-match"; Click();
                    if (fake.Writes != 0) throw new InvalidOperationException("搜索隐藏连接后仍可断开。");
                    await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; return;
                }
                Click(); await Task.Delay(80); Click(); if (fake.Writes != 1) throw new InvalidOperationException("连接断开重复提交。");
                if (state == "conn-close-busy")
                {
                    if (!connectionContent.IsBusy || dialog.IsSecondaryButtonEnabled) throw new InvalidOperationException("断开中可并发刷新。");
                    await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; await Task.Delay(80);
                    if (!fake.ConnectionCancelled) throw new InvalidOperationException("关闭连接管理未取消旧请求。"); return;
                }
                var feedback = (InfoBar)connectionContent.FindName("FeedbackNotice");
                if (!feedback.IsOpen || state is "conn-unknown" or "conn-rejected" or "conn-conflict" && feedback.Severity == InfoBarSeverity.Success) throw new InvalidOperationException("连接结果缺失或误报。");
                await WriteSnapshotAsync(dialog); await connectionContent.ReloadAsync(); if (fake.Writes != 1) throw new InvalidOperationException("核对连接重发断开。");
                page.Deactivate(); await opened; return;
            }
            await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; return;
        }
        if (power)
        {
            var powerContent = (NasPowerSettingsDialogContent)dialog.Content;
            if (!string.IsNullOrEmpty(dialog.PrimaryButtonText) || dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme)
                throw new InvalidOperationException("电源弹窗默认按钮或主题错误。");
            void Click(string name) => typeof(NasPowerSettingsDialogContent).GetMethod(name, flags)!.Invoke(powerContent, [powerContent, new RoutedEventArgs()]);
            var execute = (Button)powerContent.FindName("ExecuteButton"); var risk = (CheckBox)powerContent.FindName("RiskAcknowledgement");
            if (state == "power-loading" && !((ProgressRing)powerContent.FindName("LoadingIndicator")).IsActive) throw new InvalidOperationException("电源加载状态缺失。");
            if (state == "power-load-error" && !((InfoBar)powerContent.FindName("ErrorNotice")).IsOpen) throw new InvalidOperationException("电源错误未显示。");
            if (state is "power-readonly" or "power-pending" && ((Button)powerContent.FindName("ShutdownButton")).IsEnabled) throw new InvalidOperationException("关闭或待核对状态仍可关机。");
            if (state == "power-fresh")
            {
                Click("Acknowledge_Click"); if (fake.PowerAcknowledgements != 0) throw new InvalidOperationException("未检查设备即可解除阻止。");
                ((CheckBox)powerContent.FindName("DeviceChecked")).IsChecked = true; Click("Acknowledge_Click"); await Task.Delay(80);
                if (fake.PowerAcknowledgements != 1 || fake.Writes != 0 || ((StackPanel)powerContent.FindName("RecoveryPanel")).Visibility != Visibility.Collapsed)
                    throw new InvalidOperationException("电源核对产生写入或未完成本地恢复。");
            }
            if (state is "power-shutdown" or "power-reboot" or "power-unknown" or "power-rejected" or "power-switch-action" or "power-close-busy")
            {
                Click(state == "power-reboot" ? "Reboot_Click" : "Shutdown_Click"); Click("Execute_Click");
                if (fake.Writes != 0) throw new InvalidOperationException("电源操作缺少二次确认。");
                risk.IsChecked = true;
                if (state == "power-switch-action")
                {
                    Click("Reboot_Click"); Click("Execute_Click"); if (fake.Writes != 0) throw new InvalidOperationException("改变电源动作沿用旧确认。");
                    risk.IsChecked = true;
                }
                if (!execute.IsEnabled) throw new InvalidOperationException("电源确认后不可执行。");
                Click("Execute_Click"); await Task.Delay(80); Click("Execute_Click");
                if (fake.Writes != 1) throw new InvalidOperationException("电源请求被重复发送。");
                if (state == "power-close-busy")
                {
                    if (!powerContent.IsBusy || dialog.IsSecondaryButtonEnabled) throw new InvalidOperationException("电源操作期间可并发刷新。");
                    await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; await Task.Delay(80);
                    if (!fake.PowerCancelled) throw new InvalidOperationException("电源页面关闭未取消旧任务。");
                    return;
                }
                var feedback = (InfoBar)powerContent.FindName("FeedbackNotice");
                if (!feedback.IsOpen || feedback.Severity == InfoBarSeverity.Success) throw new InvalidOperationException("电源请求误报设备已完成。");
                if (state != "power-rejected")
                {
                    if (((Button)powerContent.FindName("RebootButton")).IsEnabled) throw new InvalidOperationException("未核对即可再次发电源命令。");
                    ((CheckBox)powerContent.FindName("DeviceChecked")).IsChecked = true; Click("Acknowledge_Click");
                    if (fake.PowerAcknowledgements != 0) throw new InvalidOperationException("旧会话解除电源阻止。");
                }
                await powerContent.ReloadAsync(); if (fake.Writes != 1) throw new InvalidOperationException("电源重读重发命令。");
            }
            await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; return;
        }
        if (directory)
        {
            var directoryContent = (NasDirectorySettingsDialogContent)dialog.Content;
            if (dialog.IsPrimaryButtonEnabled || dialog.DefaultButton != ContentDialogButton.Close || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("目录确认默认状态错误。");
            var list = (ListView)directoryContent.FindName("EntryList"); var kindChoice = (ComboBox)directoryContent.FindName("KindChoice");
            var password = (PasswordBox)directoryContent.FindName("PasswordInput"); var repeated = (PasswordBox)directoryContent.FindName("PasswordConfirmationInput");
            var risk = (CheckBox)directoryContent.FindName("RiskAcknowledgement");
            void Click(string handler) => typeof(NasDirectorySettingsDialogContent).GetMethod(handler, flags)!.Invoke(directoryContent, [directoryContent, new RoutedEventArgs()]);
            if (state is "dir-group-content" or "dir-create-group" or "dir-edit-group" or "dir-delete-group" or "dir-recovered") kindChoice.SelectedIndex = 1;
            if (list.Items.Count > 0) list.SelectedIndex = 0;
            if (state == "dir-loading" && !((ProgressRing)directoryContent.FindName("LoadingIndicator")).IsActive) throw new InvalidOperationException("目录加载状态缺失。");
            if (state == "dir-content" && (!((NasDirectorySettingsRow)list.Items[0]).Detail.Contains("synthetic-group", StringComparison.Ordinal) ||
                !((NasDirectorySettingsRow)list.Items[0]).Detail.Contains("100", StringComparison.Ordinal))) throw new InvalidOperationException("只读目录遗漏组关系或数字标识。");
            if (state == "dir-user-error")
            {
                if (!((InfoBar)directoryContent.FindName("ErrorNotice")).IsOpen) throw new InvalidOperationException("账号失败未显示。");
                kindChoice.SelectedIndex = 1;
                if (list.Items.Count == 0 || ((InfoBar)directoryContent.FindName("ErrorNotice")).IsOpen) throw new InvalidOperationException("账号失败遮蔽了可读群组。");
            }
            if (state == "dir-filter") { ((TextBox)directoryContent.FindName("SearchInput")).Text = "no-match"; await Task.Delay(80); }
            if (state is "dir-empty" or "dir-filter" && ((TextBlock)directoryContent.FindName("EmptyNotice")).Visibility != Visibility.Visible) throw new InvalidOperationException("目录空状态缺失。");
            if (state is "dir-content" or "dir-group-content" or "dir-pending" or "dir-missing-fields")
                if (((Button)directoryContent.FindName("EditButton")).IsEnabled) throw new InvalidOperationException("只读/未知/缺字段条目可编辑。");
            if (state == "dir-recovered" && (!((InfoBar)directoryContent.FindName("FeedbackNotice")).IsOpen || list.Items.Count != 0)) throw new InvalidOperationException("目录消失目标没有恢复反馈。");
            var editing = state is "dir-create-user" or "dir-create-group" or "dir-edit-user" or "dir-edit-group" or "dir-membership" or
                "dir-current" or "dir-group-error" or "dir-unknown" or "dir-rejected" or "dir-conflict" or "dir-mismatch" or "dir-late-password" or "dir-close-busy" or "dir-switch-secret";
            if (editing || state is "dir-delete-user" or "dir-delete-group")
            {
                var create = state is "dir-create-user" or "dir-create-group";
                Click(editing ? create ? "Create_Click" : "Edit_Click" : "Delete_Click");
                if (editing)
                {
                    if (create) ((TextBox)directoryContent.FindName("NameInput")).Text = "new-synthetic";
                    ((TextBox)directoryContent.FindName("DescriptionInput")).Text = "Changed description";
                    if (kindChoice.SelectedIndex == 0)
                    {
                        password.Password = " synthetic-secret "; repeated.Password = state == "dir-mismatch" ? "wrong" : " synthetic-secret ";
                        if (state == "dir-switch-secret")
                        {
                            kindChoice.SelectedIndex = 1;
                            if (password.Password.Length != 0 || repeated.Password.Length != 0) throw new InvalidOperationException("切换目录没有清除密码。");
                            await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; return;
                        }
                        if (state is "dir-current" or "dir-group-error")
                        {
                            if (((CheckBox)directoryContent.FindName("ModifyGroupsInput")).IsEnabled) throw new InvalidOperationException("无法安全修改组关系时未禁用。");
                            if (state == "dir-current") ((CheckBox)directoryContent.FindName("ExpiredInput")).IsChecked = true;
                        }
                        if (state == "dir-membership")
                        {
                            ((CheckBox)directoryContent.FindName("ModifyGroupsInput")).IsChecked = true;
                            var choices = (ListView)directoryContent.FindName("GroupChoices"); choices.SelectedItems.Clear(); choices.SelectedItems.Add(choices.Items[1]);
                        }
                    }
                }
                if (directoryContent.CanSave) throw new InvalidOperationException("目录无需确认即可保存。");
                risk.IsChecked = true;
                if (state is "dir-current" or "dir-mismatch")
                {
                    await directoryContent.SaveAsync();
                    if (fake.Writes != 0 || directoryContent.CanSave || ((TextBlock)directoryContent.FindName("ValidationNotice")).Visibility != Visibility.Visible) throw new InvalidOperationException("无效目录草稿被提交。");
                }
                else
                {
                    if (editing)
                    {
                        if (!directoryContent.CanSave) throw new InvalidOperationException("有效目录草稿不能保存。");
                        if (state == "dir-late-password")
                        {
                            password.Password = "changed-secret"; await directoryContent.SaveAsync(); if (fake.Writes != 0) throw new InvalidOperationException("密码变化沿用旧确认。");
                            repeated.Password = "changed-secret"; risk.IsChecked = true;
                        }
                        if (state == "dir-close-busy")
                        {
                            var active = directoryContent.SaveAsync(); await Task.Delay(80);
                            if (!directoryContent.IsBusy || dialog.IsSecondaryButtonEnabled) throw new InvalidOperationException("目录保存期间可并发刷新。");
                            await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; await active;
                            if (!fake.DirectoryCancelled || password.Password.Length != 0 || repeated.Password.Length != 0) throw new InvalidOperationException("关闭目录没有取消和清理。");
                            return;
                        }
                        await directoryContent.SaveAsync(); await directoryContent.SaveAsync();
                    }
                    else { Click("DeleteConfirmed_Click"); await Task.Delay(80); Click("DeleteConfirmed_Click"); }
                    if (fake.Writes != 1 || password.Password.Length != 0 || repeated.Password.Length != 0 || directoryContent.IsBusy) throw new InvalidOperationException("目录重复提交、密码残留或状态挂起。");
                    if (editing && (fake.DirectorySave is null || state != "dir-membership" && fake.DirectorySave.Desired.Groups is not null)) throw new InvalidOperationException("未明确修改却覆盖组关系。");
                    if (state == "dir-membership" && fake.DirectorySave!.Desired.Groups?.Single() != "second-group") throw new InvalidOperationException("组选择未进入确认快照。");
                    var feedback = (InfoBar)directoryContent.FindName("FeedbackNotice");
                    if (!feedback.IsOpen || state is "dir-unknown" or "dir-rejected" or "dir-conflict" && feedback.Severity == InfoBarSeverity.Success) throw new InvalidOperationException("目录结果缺失或误报成功。");
                    await WriteSnapshotAsync(dialog); await directoryContent.ReloadAsync(); if (fake.Writes != 1) throw new InvalidOperationException("目录恢复重放写请求。");
                    page.Deactivate(); await opened; return;
                }
            }
            if (fake.Writes != 0) throw new InvalidOperationException("目录只读状态产生写入。");
            await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; return;
        }
        if (packages)
        {
            var packageContent = (NasPackageSettingsDialogContent)dialog.Content;
            if (!string.IsNullOrEmpty(dialog.PrimaryButtonText) || dialog.ActualTheme != root.ActualTheme)
                throw new InvalidOperationException("套件管理出现无意义保存按钮或错误主题。");
            var list = (ListView)packageContent.FindName("PackageList");
            void Click(string name) => typeof(NasPackageSettingsDialogContent).GetMethod(name, flags)!.Invoke(packageContent, [packageContent, new RoutedEventArgs()]);
            if (list.Items.Count > 0) list.SelectedIndex = 0;
            if (state == "pkg-loading" && !((ProgressRing)packageContent.FindName("LoadingIndicator")).IsActive) throw new InvalidOperationException("套件加载状态缺失。");
            if (state == "pkg-error" && (!((InfoBar)packageContent.FindName("ErrorNotice")).IsOpen || ((TextBlock)packageContent.FindName("EmptyNotice")).Visibility == Visibility.Visible))
                throw new InvalidOperationException("套件错误变成空目录。");
            if (state == "pkg-empty" && ((TextBlock)packageContent.FindName("EmptyNotice")).Visibility != Visibility.Visible) throw new InvalidOperationException("套件空状态缺失。");
            if (state == "pkg-filter")
            {
                ((TextBox)packageContent.FindName("SearchInput")).Text = "no-match"; await Task.Delay(100);
                if (list.Items.Count != 0 || ((TextBlock)packageContent.FindName("EmptyNotice")).Visibility != Visibility.Visible) throw new InvalidOperationException("套件本地筛选错误。");
            }
            if (state is "pkg-packageContent" or "pkg-pending" or "pkg-missing-permission")
                if (((Button)packageContent.FindName("StartButton")).IsEnabled || ((Button)packageContent.FindName("UninstallButton")).IsEnabled)
                    throw new InvalidOperationException("只读/未知/缺失许可套件允许控制。");
            if (state == "pkg-recovered" && (!((InfoBar)packageContent.FindName("FeedbackNotice")).IsOpen || list.Items.Count != 0))
                throw new InvalidOperationException("消失套件的卸载恢复结果缺失。");
            if (state == "pkg-control-only" && (!((Button)packageContent.FindName("StartButton")).IsEnabled || ((Button)packageContent.FindName("UninstallButton")).IsEnabled))
                throw new InvalidOperationException("启停与卸载能力混淆。");
            if (state is "pkg-start" or "pkg-stop" or "pkg-uninstall" or "pkg-unknown" or "pkg-rejected" or "pkg-conflict" or "pkg-changed-target" or "pkg-close-busy" or "pkg-search-change")
            {
                var action = state == "pkg-stop" ? NasPackageAction.Stop : state == "pkg-uninstall" ? NasPackageAction.Uninstall : NasPackageAction.Start;
                Click(action == NasPackageAction.Stop ? "Stop_Click" : action == NasPackageAction.Uninstall ? "Uninstall_Click" : "Start_Click");
                Click("Execute_Click"); if (fake.Writes != 0) throw new InvalidOperationException("套件无确认即发送。");
                var risk = (CheckBox)packageContent.FindName("RiskAcknowledgement"); risk.IsChecked = true;
                if (!((Button)packageContent.FindName("ExecuteButton")).IsEnabled) throw new InvalidOperationException("套件确认后不可执行。");
                if (state == "pkg-search-change")
                {
                    ((TextBox)packageContent.FindName("SearchInput")).Text = "no-match"; Click("Execute_Click");
                    if (fake.Writes != 0 || list.Items.Count != 0) throw new InvalidOperationException("搜索隐藏目标后沿用旧确认。");
                    await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; return;
                }
                if (state == "pkg-changed-target")
                {
                    list.SelectedIndex = 1; Click("Execute_Click"); if (fake.Writes != 0) throw new InvalidOperationException("切换目标沿用旧确认。");
                    Click("Start_Click"); risk.IsChecked = true;
                }
                Click("Execute_Click"); await Task.Delay(100); Click("Execute_Click");
                if (fake.Writes != 1 || fake.PackageRequest?.Action != action) throw new InvalidOperationException("套件重复提交或动作混淆。");
                if (state == "pkg-close-busy")
                {
                    if (!packageContent.IsBusy || dialog.IsSecondaryButtonEnabled) throw new InvalidOperationException("套件进行中允许并发刷新。");
                    await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; await Task.Delay(100);
                    if (!fake.PackageWriteCancelled) throw new InvalidOperationException("关闭套件页面未取消旧操作。");
                    return;
                }
                var feedback = (InfoBar)packageContent.FindName("FeedbackNotice");
                if (!feedback.IsOpen || packageContent.IsBusy || state is "pkg-unknown" or "pkg-rejected" or "pkg-conflict" && feedback.Severity == InfoBarSeverity.Success)
                    throw new InvalidOperationException("套件反馈缺失或误报成功。");
                if (state == "pkg-uninstall" && list.Items.Count != 0) throw new InvalidOperationException("卸载后仍保留旧记录。");
                await WriteSnapshotAsync(dialog); await packageContent.ReloadAsync();
                if (fake.Writes != 1) throw new InvalidOperationException("套件恢复重放写操作。");
                page.Deactivate(); await opened; return;
            }
            if (fake.Writes != 0) throw new InvalidOperationException("只读套件操作产生写请求。");
            await WriteSnapshotAsync(dialog); page.Deactivate(); await opened; return;
        }
        if (ddns)
        {
            var ddnsContent = (NasDdnsSettingsDialogContent)dialog.Content;
            if (dialog.IsPrimaryButtonEnabled || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("DDNS 只读门或主题错误。");
            var records = (ListView)ddnsContent.FindName("RecordList");
            if (state == "ddns-loading" && !((ProgressRing)ddnsContent.FindName("LoadingIndicator")).IsActive)
                throw new InvalidOperationException("DDNS 加载状态缺失。");
            if (state is "ddns-error" or "ddns-unavailable")
            {
                if (!((InfoBar)ddnsContent.FindName("StatusNotice")).IsOpen ||
                    ((TextBlock)ddnsContent.FindName("EmptyNotice")).Visibility == Visibility.Visible)
                    throw new InvalidOperationException("DDNS 错误被显示为空列表。");
            }
            if (state == "ddns-empty" && ((TextBlock)ddnsContent.FindName("EmptyNotice")).Visibility != Visibility.Visible)
                throw new InvalidOperationException("DDNS 空状态缺失。");
            if (state is "ddns-content" or "ddns-no-address")
            {
                if (records.Items.Count != 1 || !((NasDdnsSettingsRow)records.Items[0]).Title.Contains("Synthetic provider", StringComparison.Ordinal))
                    throw new InvalidOperationException("只读 DDNS 记录或服务商显示名缺失。");
                if (state == "ddns-no-address" && ((NasDdnsSettingsRow)records.Items[0]).Details.Contains("192.0.2.10", StringComparison.Ordinal))
                    throw new InvalidOperationException("缺失地址被伪造。");
            }
            var editing = state is "ddns-create" or "ddns-save" or "ddns-test" or "ddns-unknown" or "ddns-rejected" or "ddns-invalid" or "ddns-late-change";
            var risk = (CheckBox)ddnsContent.FindName("RiskAcknowledgement");
            var password = (PasswordBox)ddnsContent.FindName("PasswordInput");
            void Click(string handler) => typeof(NasDdnsSettingsDialogContent).GetMethod(handler, flags)!.Invoke(ddnsContent, [ddnsContent, new RoutedEventArgs()]);
            if (editing || state is "ddns-delete" or "ddns-update")
            {
                if (records.Items.Count > 0) records.SelectedIndex = 0;
                Click(editing ? state == "ddns-create" ? "Create_Click" : "Edit_Click" : state == "ddns-delete" ? "Delete_Click" : "Update_Click");
                if (editing)
                {
                    ((TextBox)ddnsContent.FindName("HostnameInput")).Text = state == "ddns-invalid" ? "https://bad.invalid/path" : "edited.example.invalid";
                    ((TextBox)ddnsContent.FindName("UsernameInput")).Text = "synthetic-user";
                    password.Password = " synthetic-secret ";
                    if (state == "ddns-test") Click("TestChoice_Click");
                }
                if (ddnsContent.CanSave || ((Button)ddnsContent.FindName("ActionButton")).IsEnabled) throw new InvalidOperationException("DDNS 无确认可执行。");
                risk.IsChecked = true;
                if (state == "ddns-invalid")
                {
                    if (ddnsContent.CanSave || ((TextBlock)ddnsContent.FindName("ValidationNotice")).Visibility != Visibility.Visible)
                        throw new InvalidOperationException("无效 DDNS 主机名可提交。");
                }
                else
                {
                    if (state is "ddns-test" or "ddns-delete" or "ddns-update")
                    {
                        if (!((Button)ddnsContent.FindName("ActionButton")).IsEnabled) throw new InvalidOperationException("DDNS 已确认操作不可执行。");
                        Click("Execute_Click"); await Task.Delay(100);
                    }
                    else
                    {
                        if (!ddnsContent.CanSave) throw new InvalidOperationException("已确认 DDNS 不可保存。");
                        if (state == "ddns-late-change")
                        {
                            password.Password = "changed-after-confirmation"; await ddnsContent.SaveAsync();
                            if (fake.Writes != 0) throw new InvalidOperationException("确认后改密码仍使用旧确认。");
                            risk.IsChecked = true;
                        }
                        await ddnsContent.SaveAsync();
                    }
                    await ddnsContent.SaveAsync();
                    if (fake.Writes != 1 || password.Password.Length != 0 || ddnsContent.IsBusy) throw new InvalidOperationException("DDNS 重复写/密码残留/忙碌状态未结束。");
                    var feedback = (InfoBar)ddnsContent.FindName("FeedbackNotice");
                    if (!feedback.IsOpen || state is "ddns-unknown" or "ddns-rejected" && feedback.Severity == InfoBarSeverity.Success)
                        throw new InvalidOperationException("DDNS 结果反馈缺失或误报成功。");
                    if (state == "ddns-unknown" && ((Button)ddnsContent.FindName("UpdateButton")).IsEnabled)
                        throw new InvalidOperationException("未知保存仍允许更新地址。");
                    var expected = state == "ddns-test" ? NasDdnsAction.Test : state == "ddns-delete" ? NasDdnsAction.Delete :
                        state == "ddns-update" ? NasDdnsAction.UpdateAddress : NasDdnsAction.Save;
                    if (fake.DdnsRequest?.Action != expected) throw new InvalidOperationException("DDNS 四操作边界混淆。");
                    await WriteSnapshotAsync(dialog); await ddnsContent.ReloadAsync();
                    if (fake.Writes != 1) throw new InvalidOperationException("DDNS 重读重放写操作。");
                    page.Deactivate(); await opened;
                    if (password.Password.Length != 0) throw new InvalidOperationException("DDNS 关闭未清密码。");
                    return;
                }
            }
            if (state == "ddns-pending" && (!((InfoBar)ddnsContent.FindName("FeedbackNotice")).IsOpen || ((Button)ddnsContent.FindName("EditButton")).IsEnabled))
                throw new InvalidOperationException("未知 DDNS 结果未阻断新操作。");
            await ddnsContent.SaveAsync();
            if (fake.Writes != 0) throw new InvalidOperationException("DDNS 查看产生副作用。");
            await Task.Delay(100); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog);
            page.Deactivate(); await opened; return;
        }
        if (hardware)
        {
            var hardwareContent = (NasHardwareSettingsDialogContent)dialog.Content;
            if (dialog.IsPrimaryButtonEnabled || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("硬件只读门或主题错误。");
            var list = (ListView)hardwareContent.FindName("SettingsList");
            if (state == "hardware-loading" && !((ProgressRing)hardwareContent.FindName("LoadingIndicator")).IsActive)
                throw new InvalidOperationException("硬件加载状态缺失。");
            if (state is "hardware-error" or "hardware-empty" or "hardware-unavailable" or "hardware-partial" or "hardware-recovered")
            {
                if (!((InfoBar)hardwareContent.FindName("StatusNotice")).IsOpen) throw new InvalidOperationException("硬件失败或未知状态未显示。");
                if (state == "hardware-recovered")
                {
                    await hardwareContent.ReloadAsync();
                    if (((InfoBar)hardwareContent.FindName("StatusNotice")).IsOpen) throw new InvalidOperationException("硬件重读未恢复。");
                }
            }
            if (state == "hardware-content" && list.Items.Count < 15) throw new InvalidOperationException("硬件字段丢失。");
            if (state == "hardware-ups-empty" && !list.Items.OfType<NasHardwareSettingsRow>().Any(item =>
                item.Title == Localization.LocalizationService.Current.Get("NasHardwareUpsServer") &&
                item.Value == Localization.LocalizationService.Current.Get("NasHardwareNotConfigured")))
                throw new InvalidOperationException("UPS 可信空地址被当作缺失。");
            if (state == "hardware-pending" && ((ScrollViewer)hardwareContent.FindName("Editor")).Visibility != Visibility.Collapsed)
                throw new InvalidOperationException("待核对硬件仍可编辑。");
            if (state.StartsWith("hardware-save", StringComparison.Ordinal) || state is "hardware-invalid" or "hardware-ups-edit")
            {
                var editors = ((StackPanel)hardwareContent.FindName("EditorFields")).Children.OfType<Control>().ToArray();
                Control Find(string key) => editors.Single(control => (string)control.Tag == key);
                ((TextBox)Find("led_brightness")).Text = state == "hardware-invalid" ? "11" : "6";
                if (state == "hardware-save-partial") ((CheckBox)Find("rc_power_config")).IsChecked = false;
                if (state == "hardware-ups-edit")
                {
                    ((CheckBox)Find("enable")).IsChecked = true;
                    ((TextBox)Find("net_server_ip")).Text = "192.0.2.51";
                    if (editors.Any(control => (string)control.Tag == "snmp_server_ip")) throw new InvalidOperationException("缺失 UPS 字段被添加为可写。");
                }
                await Task.Delay(120);
                if (hardwareContent.CanSave) throw new InvalidOperationException("硬件未确认风险即可保存。");
                if (!((CheckBox)hardwareContent.FindName("RiskAcknowledgement")).IsEnabled && state != "hardware-invalid")
                    throw new InvalidOperationException("用户无法确认有效硬件表单。");
                ((CheckBox)hardwareContent.FindName("RiskAcknowledgement")).IsChecked = true;
                if (state == "hardware-invalid")
                {
                    if (hardwareContent.CanSave || ((TextBlock)hardwareContent.FindName("ValidationNotice")).Visibility != Visibility.Visible)
                        throw new InvalidOperationException("越界 LED 可提交。");
                }
                else
                {
                    if (!hardwareContent.CanSave) throw new InvalidOperationException("有效硬件更改不可保存。");
                    if (state == "hardware-save")
                    {
                        ((TextBox)Find("led_brightness")).Text = "7";
                        await hardwareContent.SaveAsync();
                        if (fake.Writes != 0) throw new InvalidOperationException("确认后修改值却沿用旧确认。");
                        ((CheckBox)hardwareContent.FindName("RiskAcknowledgement")).IsChecked = true;
                    }
                    await hardwareContent.SaveAsync(); await hardwareContent.SaveAsync();
                    if (fake.Writes != 1 || hardwareContent.CanSave) throw new InvalidOperationException("硬件写入被重复提交。");
                    if (state is "hardware-save-partial" or "hardware-save-unknown")
                    {
                        if (((InfoBar)hardwareContent.FindName("StatusNotice")).Severity == InfoBarSeverity.Success)
                            throw new InvalidOperationException("硬件部分/未知结果误报成功。");
                        await WriteSnapshotAsync(dialog);
                        await hardwareContent.ReloadAsync();
                        if (fake.Writes != 1) throw new InvalidOperationException("硬件重读产生新写入。");
                        page.Deactivate(); await opened; return;
                    }
                }
            }
            await hardwareContent.SaveAsync();
            if (fake.Writes != (state is "hardware-save" or "hardware-ups-edit" ? 1 : 0)) throw new InvalidOperationException("硬件写入次数错误。");
            await Task.Delay(100); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog);
            page.Deactivate(); await opened; return;
        }
        if (security)
        {
            var securityContent = (NasSecuritySettingsDialogContent)dialog.Content;
            if (dialog.IsPrimaryButtonEnabled || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("安全设置只读门或主题错误。");
            if (state is "security-partial" or "security-recovered")
            {
                if (((StackPanel)securityContent.FindName("FirewallSection")).Visibility != Visibility.Collapsed ||
                    !((InfoBar)securityContent.FindName("StatusNotice")).IsOpen) throw new InvalidOperationException("缺失防火墙状态被猜测。");
                if (state == "security-recovered")
                {
                    await securityContent.ReloadAsync();
                    if (((InfoBar)securityContent.FindName("StatusNotice")).IsOpen ||
                        ((StackPanel)securityContent.FindName("FirewallSection")).Visibility != Visibility.Visible)
                        throw new InvalidOperationException("安全设置重新读取未恢复。");
                }
            }
            if (state is "security-error" or "security-unavailable" or "security-empty")
            {
                if (!((InfoBar)securityContent.FindName("StatusNotice")).IsOpen) throw new InvalidOperationException("安全设置错误/不可用未显示。");
            }
            if (state == "security-loading" && !((ProgressRing)securityContent.FindName("LoadingIndicator")).IsActive)
                throw new InvalidOperationException("安全设置加载状态缺失。");
            if (state == "security-content" && ((ItemsControl)securityContent.FindName("DosItems")).Items.Count != 2)
                throw new InvalidOperationException("网卡防护混合状态丢失。");
            if (state == "security-no-expiry" && ((TextBlock)securityContent.FindName("ExpirationValue")).Text != Localization.LocalizationService.Current.Get("NasSecurityNoExpiration"))
                throw new InvalidOperationException("封锁不过期被当作缺失。");
            if (state == "security-pending" && ((StackPanel)securityContent.FindName("ConfirmationPanel")).Visibility != Visibility.Collapsed)
                throw new InvalidOperationException("安全待核对状态允许继续写入。");
            if (state.StartsWith("security-save", StringComparison.Ordinal) || state is "security-invalid" or "security-missing-profile")
            {
                ((TextBox)securityContent.FindName("AttemptsInput")).Text = state == "security-invalid" ? "0" : "6";
                if (state == "security-save-partial") ((ToggleSwitch)securityContent.FindName("PortScanToggle")).IsOn = false;
                if (state == "security-missing-profile") ((ToggleSwitch)securityContent.FindName("FirewallToggle")).IsOn = true;
                await Task.Delay(120);
                if (securityContent.CanSave) throw new InvalidOperationException("安全设置没有风险确认即可保存。");
                ((CheckBox)securityContent.FindName("RiskAcknowledgement")).IsChecked = true;
                if (state is "security-invalid" or "security-missing-profile")
                {
                    if (securityContent.CanSave || ((TextBlock)securityContent.FindName("ValidationNotice")).Visibility != Visibility.Visible)
                        throw new InvalidOperationException("非法规则或缺配置档仍可保存。");
                }
                else
                {
                    if (!securityContent.CanSave) throw new InvalidOperationException("有效安全更改不可保存。");
                    await securityContent.SaveAsync(); await securityContent.SaveAsync();
                    if (fake.Writes != 1 || securityContent.CanSave) throw new InvalidOperationException("安全保存重复提交。");
                    if (state is "security-save-partial" or "security-save-unknown")
                    {
                        if (((InfoBar)securityContent.FindName("StatusNotice")).Severity == InfoBarSeverity.Success)
                            throw new InvalidOperationException("安全部分/未知结果显示成功。");
                        if (state == "security-save-partial" && !((ToggleSwitch)securityContent.FindName("PortScanToggle")).IsOn)
                            throw new InvalidOperationException("未生效草稿被显示为实际值。");
                        await WriteSnapshotAsync(dialog);
                        await securityContent.ReloadAsync();
                        if (fake.Writes != 1) throw new InvalidOperationException("安全重读触发写入。");
                        page.Deactivate(); await opened; return;
                    }
                }
            }
            await securityContent.SaveAsync();
            if (fake.Writes != (state == "security-save" ? 1 : 0)) throw new InvalidOperationException("安全设置写入次数错误。");
            await Task.Delay(100); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog);
            page.Deactivate(); await opened; return;
        }
        if (network)
        {
            var networkContent = (NasNetworkSettingsDialogContent)dialog.Content;
            if (dialog.IsPrimaryButtonEnabled || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("网卡只读门或主题错误。");
            var list = (ListView)networkContent.FindName("Interfaces");
            if (state is "network-save" or "network-save-unknown" or "network-invalid" or "network-edit-unknown")
            {
                list.SelectedIndex = 0; await Task.Delay(100);
                if (state == "network-edit-unknown")
                {
                    if (((ScrollViewer)networkContent.FindName("Editor")).Visibility != Visibility.Collapsed ||
                        !((InfoBar)networkContent.FindName("StatusNotice")).IsOpen) throw new InvalidOperationException("不完整网卡被允许编辑。");
                }
                else
                {
                    ((TextBox)networkContent.FindName("Mtu")).Text = state == "network-invalid" ? "1" : "1600";
                    await Task.Delay(100);
                    if (networkContent.CanSave) throw new InvalidOperationException("网络更改未确认即允许保存。");
                    ((CheckBox)networkContent.FindName("RiskAcknowledgement")).IsChecked = true;
                    if (state == "network-invalid")
                    {
                        if (networkContent.CanSave || ((TextBlock)networkContent.FindName("ValidationNotice")).Visibility != Visibility.Visible)
                            throw new InvalidOperationException("非法 MTU 可提交。");
                    }
                    else
                    {
                        if (!networkContent.CanSave) throw new InvalidOperationException("有效网卡更改不可保存。");
                        await networkContent.SaveAsync(); await networkContent.SaveAsync();
                        if (fake.Writes != 1 || networkContent.CanSave) throw new InvalidOperationException("网卡更改重复提交。");
                        if (state == "network-save-unknown")
                        {
                            if (((InfoBar)networkContent.FindName("StatusNotice")).Severity == InfoBarSeverity.Success)
                                throw new InvalidOperationException("网络未知结果被显示为成功。");
                            await WriteSnapshotAsync(dialog); await networkContent.ReloadAsync();
                            if (fake.Writes != 1) throw new InvalidOperationException("网卡重读重发设置。");
                            page.Deactivate(); await opened; return;
                        }
                    }
                }
            }
            if (state is "network-reconnect" or "network-fresh-login")
            {
                if (networkContent.CanSave || !((InfoBar)networkContent.FindName("StatusNotice")).IsOpen)
                    throw new InvalidOperationException("网卡重连保护缺失。");
                if (state == "network-reconnect")
                {
                    if (((StackPanel)networkContent.FindName("RecoveryPanel")).Visibility != Visibility.Visible)
                        throw new InvalidOperationException("缺少同一 NAS 确认。");
                    ((CheckBox)networkContent.FindName("SameNasConfirmation")).IsChecked = true;
                    typeof(NasNetworkSettingsDialogContent).GetMethod("Review_Click", flags)!.Invoke(networkContent, [networkContent, new RoutedEventArgs()]);
                    await Task.Delay(150);
                    if (((StackPanel)networkContent.FindName("RecoveryPanel")).Visibility != Visibility.Collapsed)
                        throw new InvalidOperationException("网卡确认恢复未完成。");
                }
            }
            if (state == "network-loading" && !((ProgressRing)networkContent.FindName("LoadingIndicator")).IsActive)
                throw new InvalidOperationException("网卡加载提示缺失。");
            if (state == "network-empty" && ((TextBlock)networkContent.FindName("EmptyNotice")).Visibility != Visibility.Visible)
                throw new InvalidOperationException("网卡空状态未显示。");
            if (state is "network-error" or "network-unavailable" or "network-partial" or "network-recovered")
            {
                if (!((InfoBar)networkContent.FindName("StatusNotice")).IsOpen) throw new InvalidOperationException("网卡失败被隐藏。");
                if (state == "network-recovered")
                {
                    await networkContent.ReloadAsync();
                    if (((InfoBar)networkContent.FindName("StatusNotice")).IsOpen || list.Items.Count != 1)
                        throw new InvalidOperationException("网卡重读没有恢复。");
                }
            }
            if (state == "network-unknown")
            {
                var row = (NasNetworkSettingsRow)list.Items[0];
                if (row.Advanced.Contains("1500", StringComparison.Ordinal) || row.StaticVisibility != Visibility.Collapsed)
                    throw new InvalidOperationException("未知 MTU 或动态地址被猜测。");
            }
            if (state == "network-content" && list.Items.Count != 1) throw new InvalidOperationException("网卡内容缺失。");
            await networkContent.SaveAsync();
            if (fake.Writes != (state == "network-save" ? 1 : 0)) throw new InvalidOperationException("网卡写入次数错误。");
            await Task.Delay(100); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog);
            page.Deactivate(); await opened; return;
        }
        if (region)
        {
            var regionContent = (NasRegionSettingsDialogContent)dialog.Content;
            if (dialog.IsPrimaryButtonEnabled || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("区域设置只读门或主题错误。");
            var fields = (StackPanel)regionContent.FindName("Fields");
            if (state.StartsWith("region-save", StringComparison.Ordinal) || state is "region-invalid" or "region-manual-edit")
            {
                var dateChoices = (ComboBox)regionContent.FindName("DatePatternChoice");
                dateChoices.SelectedItem = dateChoices.Items.OfType<ComboBoxItem>().Single(item => (string)item.Tag == "Y/m/d");
                if (state.Contains("sync", StringComparison.Ordinal)) ((TextBox)regionContent.FindName("ServersInput")).Text = "pool.example.invalid";
                if (state == "region-invalid") ((TextBox)regionContent.FindName("ServersInput")).Text = "https://bad.example.invalid";
                if (state == "region-manual-edit")
                {
                    ((CheckBox)regionContent.FindName("EditClock")).IsChecked = true;
                    if (regionContent.CanSave || ((DatePicker)regionContent.FindName("NewDate")).SelectedDate is not null ||
                        ((TimePicker)regionContent.FindName("NewTime")).SelectedTime is not null)
                        throw new InvalidOperationException("手动改时默认采用本机或旧时间。");
                    ((DatePicker)regionContent.FindName("NewDate")).SelectedDate = new DateTimeOffset(2026, 8, 1, 0, 0, 0, TimeSpan.Zero);
                    ((TimePicker)regionContent.FindName("NewTime")).SelectedTime = new TimeSpan(2, 3, 0);
                }
                await Task.Delay(150);
                if (regionContent.CanSave) throw new InvalidOperationException("区域更改未确认即可保存。");
                ((CheckBox)regionContent.FindName("RiskAcknowledgement")).IsChecked = true;
                if (state == "region-invalid")
                {
                    if (regionContent.CanSave || ((TextBlock)regionContent.FindName("ValidationNotice")).Visibility != Visibility.Visible)
                        throw new InvalidOperationException("无效时间服务器可提交。");
                }
                else
                {
                    if (!regionContent.CanSave) throw new InvalidOperationException("有效区域更改不可保存。");
                    await regionContent.SaveAsync(); await regionContent.SaveAsync();
                    if (fake.Writes != 1 || regionContent.CanSave) throw new InvalidOperationException("区域保存被重发。");
                    if (state == "region-manual-edit" && fake.RegionRequest?.EditedNasTime != new DateTime(2026, 8, 1, 2, 3, 0))
                        throw new InvalidOperationException("明确选择的 NAS 时间丢失。");
                    if (state == "region-manual-edit" && (((TextBox)regionContent.FindName("ClockValue")).Visibility != Visibility.Visible ||
                        ((TextBox)regionContent.FindName("ClockValue")).Text != new DateTime(2026, 8, 1, 2, 3, 0).ToString("G", System.Globalization.CultureInfo.CurrentCulture)))
                        throw new InvalidOperationException("保存后没有显示回读的 NAS 时间。");
                    if (state != "region-manual-edit" && fake.RegionRequest?.EditedNasTime is not null)
                        throw new InvalidOperationException("没有编辑手动时间却回写旧时钟。");
                    var notice = (InfoBar)regionContent.FindName("StatusNotice");
                    if (state is "region-save-sync-failed" or "region-save-unverified")
                    {
                        if (notice.Severity == InfoBarSeverity.Success) throw new InvalidOperationException("校时未知或配置未知显示成功。");
                    }
                    if (state == "region-save-sync" && notice.Message != Localization.LocalizationService.Current.Get("NasRegionSyncAccepted"))
                        throw new InvalidOperationException("校时请求接受被误称为精度验证。");
                }
                await regionContent.SaveAsync();
                if (state == "region-invalid" && fake.Writes != 0) throw new InvalidOperationException("无效区域更改产生写入。");
                await Task.Delay(100); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog);
                page.Deactivate(); await opened; return;
            }
            if (state is "region-error" or "region-unavailable" or "region-unknown")
            {
                if (fields.Visibility != Visibility.Collapsed || !((InfoBar)regionContent.FindName("StatusNotice")).IsOpen)
                    throw new InvalidOperationException("区域未知/错误状态被当作有效设置。");
            }
            else if (state == "region-loading")
            {
                if (!((ProgressRing)regionContent.FindName("LoadingIndicator")).IsActive) throw new InvalidOperationException("区域加载提示缺失。");
            }
            else
            {
                var clock = ((TextBox)regionContent.FindName("ClockValue")).Text;
                var expected = state == "region-no-clock" ? Localization.LocalizationService.Current.Get("NasRegionClockUnavailable")
                    : new DateTime(2026, 7, 26, 18, 30, 10).ToString("G", System.Globalization.CultureInfo.CurrentCulture);
                if (clock != expected || fields.Visibility != Visibility.Visible) throw new InvalidOperationException("NAS 时间被本机时间或默认值替代。");
                if (((TextBox)regionContent.FindName("DateFormatValue")).Text != "2001-02-03" ||
                    ((TextBox)regionContent.FindName("TimeFormatValue")).Text != "13:45")
                    throw new InvalidOperationException("格式示例未与真实 NAS 时间分开。");
                if (state == "region-manual" && ((TextBox)regionContent.FindName("ModeValue")).Text != Localization.LocalizationService.Current.Get("NasRegionManualTime"))
                    throw new InvalidOperationException("区域校时模式错误。");
            }
            await regionContent.SaveAsync();
            if (fake.Writes != 0) throw new InvalidOperationException("查看区域设置触发了改时。");
            await Task.Delay(100); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog);
            page.Deactivate(); await opened; return;
        }
        if (fileServices)
        {
            var fileContent = (NasFileServiceSettingsDialogContent)dialog.Content;
            if (dialog.ActualTheme != root.ActualTheme || dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("文件服务主题或只读门错误。");
            if (state is "file-partial" or "file-recovered")
            {
                if (((ToggleSwitch)fileContent.FindName("Ftp")).Visibility != Visibility.Collapsed ||
                    !((ToggleSwitch)fileContent.FindName("Ftps")).IsOn || !((InfoBar)fileContent.FindName("StatusNotice")).IsOpen)
                    throw new InvalidOperationException("缺失状态被当作关闭或 FTPS 未独立显示。");
                if (state == "file-recovered")
                {
                    await fileContent.ReloadAsync();
                    if (((ToggleSwitch)fileContent.FindName("Ftp")).Visibility != Visibility.Visible ||
                        ((InfoBar)fileContent.FindName("StatusNotice")).IsOpen) throw new InvalidOperationException("文件服务重新读取未恢复。");
                }
            }
            if (state is "file-error" or "file-unavailable" or "file-empty")
            {
                if (((Grid)fileContent.FindName("Fields")).Visibility != Visibility.Collapsed ||
                    !((InfoBar)fileContent.FindName("StatusNotice")).IsOpen) throw new InvalidOperationException("文件服务错误/不可用被当作关闭。");
            }
            if (state == "file-loading" && !((ProgressRing)fileContent.FindName("LoadingIndicator")).IsActive)
                throw new InvalidOperationException("文件服务加载状态缺失。");
            if (state == "file-services" && (!((ToggleSwitch)fileContent.FindName("Smb")).IsOn ||
                ((ToggleSwitch)fileContent.FindName("Smb")).IsEnabled || ((TextBox)fileContent.FindName("SftpPort")).Text != "2222"))
                throw new InvalidOperationException("文件服务实际状态或只读门错误。");
            if (state == "file-services" && ((TextBox)fileContent.FindName("FtpPort")).ActualHeight > 70)
                throw new InvalidOperationException("FTP 端口输入框被同排内容拉伸。");
            if (state == "file-pending" && (((ToggleSwitch)fileContent.FindName("Nfs")).IsEnabled ||
                !((InfoBar)fileContent.FindName("StatusNotice")).IsOpen)) throw new InvalidOperationException("文件服务待核对状态未保护。");
            if (state.StartsWith("file-save", StringComparison.Ordinal) || state == "file-invalid")
            {
                ((ToggleSwitch)fileContent.FindName("Nfs")).IsOn = true;
                if (state == "file-save-partial") ((TextBox)fileContent.FindName("SftpPort")).Text = "2223";
                if (state == "file-invalid") ((TextBox)fileContent.FindName("SftpPort")).Text = "21";
                await Task.Delay(100);
                if (fileContent.CanSave) throw new InvalidOperationException("文件服务未经风险确认就可保存。");
                ((CheckBox)fileContent.FindName("RiskAcknowledgement")).IsChecked = true;
                if (state == "file-invalid")
                {
                    if (fileContent.CanSave || ((TextBlock)fileContent.FindName("ValidationNotice")).Visibility != Visibility.Visible)
                        throw new InvalidOperationException("冲突端口可提交。");
                }
                else
                {
                    if (!fileContent.CanSave) throw new InvalidOperationException("有效文件服务更改不能保存。");
                    await fileContent.SaveAsync(); await fileContent.SaveAsync();
                    if (fake.Writes != 1 || fileContent.CanSave) throw new InvalidOperationException("文件服务重复提交。");
                    if (state is "file-save-review" or "file-save-partial")
                    {
                        if (state == "file-save-partial" && ((TextBox)fileContent.FindName("SftpPort")).Text != "2222")
                            throw new InvalidOperationException("未生效的 SFTP 草稿被显示为当前值。");
                        if (((InfoBar)fileContent.FindName("StatusNotice")).Severity == InfoBarSeverity.Success)
                            throw new InvalidOperationException("文件服务未知或部分结果显示成功。");
                        await WriteSnapshotAsync(dialog);
                        await fileContent.ReloadAsync();
                        if (fake.Writes != 1 || fileContent.CanSave || !((ToggleSwitch)fileContent.FindName("Nfs")).IsOn)
                            throw new InvalidOperationException("文件服务回读重发或未采用实际状态。");
                        page.Deactivate(); await opened; return;
                    }
                }
            }
            await fileContent.SaveAsync();
            if (fake.Writes != (state == "file-save" ? 1 : 0)) throw new InvalidOperationException("文件服务写入次数错误。");
            await Task.Delay(100); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog);
            page.Deactivate(); await opened; return;
        }
        var content = (NasServiceSettingsDialogContent)dialog.Content;
        if (dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("服务设置弹窗未跟随主题。");
        if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("未更改/未确认的服务设置可保存。");
        if (state is "terminal-pending" or "terminal-recovered")
        {
            if (((TextBox)content.FindName("SshPort")).IsEnabled || !((InfoBar)content.FindName("StatusNotice")).IsOpen)
                throw new InvalidOperationException("页面重开后的未知结果没有保护。");
            if (state == "terminal-recovered")
            {
                await content.ReloadAsync();
                if (!((TextBox)content.FindName("SshPort")).IsEnabled || ((TextBox)content.FindName("SshPort")).Text != "2222")
                    throw new InvalidOperationException("回读后未恢复实际设置。");
                if (content.CanSave || fake.Writes != 0) throw new InvalidOperationException("恢复核对重放写入。");
            }
        }
        if (state.EndsWith("readonly", StringComparison.Ordinal))
        {
            if (((TextBlock)content.FindName("ReadOnlyNotice")).Visibility != Visibility.Visible ||
                ((ToggleSwitch)content.FindName(state.StartsWith("proxy", StringComparison.Ordinal) ? "ProxyToggle" : "SshToggle")).IsEnabled)
                throw new InvalidOperationException("只读设置仍可编辑。");
        }
        if (state == "terminal-no-port" && ((TextBox)content.FindName("SshPort")).Visibility != Visibility.Collapsed)
            throw new InvalidOperationException("未返回的 SSH 端口被猜测。");
        if (state == "terminal-loading" && !((ProgressRing)content.FindName("LoadingIndicator")).IsActive)
            throw new InvalidOperationException("缺少加载状态。");
        if (state == "proxy-error" && !((InfoBar)content.FindName("StatusNotice")).IsOpen)
            throw new InvalidOperationException("缺少错误恢复状态。");
        if (state is "terminal-save" or "terminal-review" or "proxy-save" or "proxy-invalid")
        {
            var proxy = state.StartsWith("proxy", StringComparison.Ordinal);
            ((TextBox)content.FindName(proxy ? "ProxyPort" : "SshPort")).Text = "2222";
            await Task.Delay(100);
            if (content.CanSave) throw new InvalidOperationException("未确认风险即允许保存。");
            var confirmation = (CheckBox)content.FindName("RiskAcknowledgement");
            confirmation.IsChecked = true;
            if (!content.CanSave) throw new InvalidOperationException("有效设置确认后仍不能保存。");
            if (state == "proxy-invalid")
            {
                ((TextBox)content.FindName("ProxyHost")).Text = "https://proxy.example.invalid/path";
                await Task.Delay(100);
                confirmation.IsChecked = true;
                if (content.CanSave || ((TextBlock)content.FindName("ValidationNotice")).Visibility != Visibility.Visible)
                    throw new InvalidOperationException("无效地址可提交。");
                await content.SaveAsync();
                if (fake.Writes != 0) throw new InvalidOperationException("无效输入产生写入。");
            }
            else
            {
                await content.SaveAsync();
                await content.SaveAsync();
                if (fake.Writes != 1 || content.CanSave) throw new InvalidOperationException("保存重复提交或未锁定。");
                var notice = (InfoBar)content.FindName("StatusNotice");
                if (state == "terminal-review")
                {
                    if (notice.Severity == InfoBarSeverity.Success) throw new InvalidOperationException("未知结果显示成功。");
                    await WriteSnapshotAsync(dialog);
                    await content.ReloadAsync();
                    if (fake.Writes != 1 || content.CanSave || ((TextBox)content.FindName("SshPort")).Text != "2222")
                        throw new InvalidOperationException("重新读取未采用实际设置或重放写入。");
                    dialog.Hide(); await opened; return;
                }
                if (notice.Severity != InfoBarSeverity.Success) throw new InvalidOperationException("确认成功未正确显示。");
            }
        }
        await Task.Delay(150); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog);
        page.Deactivate(); await opened;
        if (typeof(NasDetailsPage).GetField("_serviceSettingsDialog", flags)!.GetValue(page) is not null)
            throw new InvalidOperationException("页面离开后设置弹窗未清理。");
    }

    private static async Task SaveDownloadSettingsAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "settings-basic";
        var repository = new SmokeDownloadSettingsRepository(state);
        using var model = new DownloadSettingsViewModel(repository, repository);
        var load = model.LoadAsync(); if (state != "settings-loading") await load;
        if (state is "settings-folders" or "settings-empty-folders") await model.BrowseFoldersAsync("");
        using var content = new DownloadSettingsDialogContent(model);
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = root.ActualTheme,
            Title = Localization.LocalizationService.Current.Get("DownloadSettingsTitle"), Content = content,
            CloseButtonText = Localization.LocalizationService.Current.Get("DownloadSettingsClose"), PrimaryButtonText = content.PrimaryText,
            PrimaryButtonStyle = content.ActionButtonStyle, CloseButtonStyle = content.ActionButtonStyle,
            IsPrimaryButtonEnabled = content.CanSubmit, DefaultButton = ContentDialogButton.Close };
        void Update() { dialog.PrimaryButtonText = content.PrimaryText; dialog.IsPrimaryButtonEnabled = content.CanSubmit; }
        content.StateChanged += Update;
        var showing = dialog.ShowAsync(); await Task.Delay(350);
        if (state is "settings-save" or "settings-review" or "settings-partial")
        {
            ((NumberBox)content.FindName("BtDownload")).Value = 650;
            if (state is "settings-review" or "settings-partial") ((ToggleSwitch)content.FindName("ScheduleToggle")).IsOn = true;
            if (content.CanSubmit) throw new InvalidOperationException("设置未确认就允许保存。");
            ((CheckBox)content.FindName("Confirmation")).IsChecked = true;
            if (!content.CanSubmit) throw new InvalidOperationException("有效设置更改不能保存。");
            await content.SubmitAsync();
            if (state == "settings-review")
            {
                if (!model.RequiresReview || repository.ScheduleWrites != 0) throw new InvalidOperationException("未知基础设置结果没有暂停计划写入。");
                await content.SubmitAsync(); await content.SubmitAsync();
                if (!model.CanContinue || content.CanSubmit || repository.ScheduleWrites != 0) throw new InvalidOperationException("核对结果触发了未确认的计划写入。");
                ((CheckBox)content.FindName("Confirmation")).IsChecked = true; await content.SubmitAsync();
            }
            await content.SubmitAsync();
            if (repository.BasicWrites != 1 || content.CanSubmit || model.HasPending) throw new InvalidOperationException("设置重复提交保护或终态不正确。");
        }
        if (state == "settings-folders")
        {
            var list = (ListView)content.FindName("FolderList"); list.SelectedItem = model.Folders[0];
            if (((Button)content.FindName("ChooseFolderButton")).IsEnabled) throw new InvalidOperationException("只读目录可被选为默认位置。");
            list.SelectedItem = model.Folders[1];
            if (!((Button)content.FindName("ChooseFolderButton")).IsEnabled) throw new InvalidOperationException("可写目录无法选择。");
        }
        if (state == "settings-v1" && ((TextBox)content.FindName("DestinationBox")).IsEnabled) throw new InvalidOperationException("Info v1 开放了默认位置写入。");
        if (state == "settings-no-schedule" && ((ToggleSwitch)content.FindName("ScheduleToggle")).IsEnabled) throw new InvalidOperationException("不可用计划被当作可编辑。");
        if (state == "settings-no-schedule" && ((ToggleSwitch)content.FindName("ScheduleToggle")).Visibility != Visibility.Collapsed) throw new InvalidOperationException("未知计划状态被显示成关闭。");
        var expected = state == "settings-loading" ? "LoadingRing" : state == "settings-error" ? "ErrorPanel" : "Editor";
        if (content.FindName(expected) is not FrameworkElement { Visibility: Visibility.Visible }) throw new InvalidOperationException("设置状态显示错误。");
        if (dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("设置弹窗未跟随主题。");
        await Task.Delay(150); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog);
        content.StateChanged -= Update; dialog.Hide(); await showing; model.CancelLoad(); await load;
    }

    private static async Task SaveChatToolsAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "reminders";
        var repository = new SmokeAdvancedChatRepository(state);
        using var model = new ChatAdvancedViewModel(repository);
        var section = state switch { "schedules" => ChatAdvancedSection.ScheduledMessages, "polls" => ChatAdvancedSection.Polls,
            "actions-forward" => ChatAdvancedSection.Forward, "actions-pins" => ChatAdvancedSection.Announcements,
            "actions-close" or "batch-close" => ChatAdvancedSection.CloseConversation,
            "batch-forward" or "batch-direct" or "batch-review" => ChatAdvancedSection.Forward,
            "batch-delete" => ChatAdvancedSection.DeleteMessages, _ => ChatAdvancedSection.Reminders };
        var message = new ChatMessage("sample-message", "sample-chat", "synthetic-user", "Demo", true, DateTimeOffset.UtcNow,
            "Synthetic message for reminder", [], ChatEncryptionState.NotEncrypted)
        {
            Poll = new("sample-poll", "Synthetic question", false, false, null, false,
                [new("one", "First choice", 2, false), new("two", "Second choice", 1, false)]),
        };
        if (section == ChatAdvancedSection.Forward) message = message with { Poll = null };
        var messages = state.StartsWith("batch-", StringComparison.Ordinal) ? new[] { message, message with { Id = "sample-message-2", SentAt = message.SentAt.AddSeconds(1) } } : [message];
        var load = model.ActivateAsync(new("sample-chat", ChatConversationKind.Group, "Demo", [], 3, null, null, 0, false), messages, section);
        if (state != "advanced-loading") await load;
        if (state == "advanced-filtered") model.SetFilter("not-a-matching-synthetic-entry");
        if (state == "advanced-review") await model.SetReminderAsync("sample-message", DateTimeOffset.UtcNow.AddHours(1));
        using var content = new ChatAdvancedDialogContent(model, "sample-message");
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = root.ActualTheme, Title = "Synthetic chat tools", Content = content,
            CloseButtonText = Localization.LocalizationService.Current.Get("ChatAdvancedClose"), PrimaryButtonText = content.PrimaryText,
            PrimaryButtonStyle = content.ActionButtonStyle, CloseButtonStyle = content.ActionButtonStyle,
            IsPrimaryButtonEnabled = content.CanSubmit, DefaultButton = ContentDialogButton.Close };
        var showing = dialog.ShowAsync();
        await Task.Delay(400);
        if (state is "advanced-success" or "advanced-rejected")
        {
            await content.SubmitAsync(); await content.SubmitAsync();
            if (repository.MutationCalls != 1 || content.CanSubmit) throw new InvalidOperationException("确认成功后连续点击产生了第二次操作。");
            dialog.IsPrimaryButtonEnabled = content.CanSubmit;
            await Task.Delay(150);
            dialog.UpdateLayout();
        }
        if (dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("高级聊天弹窗没有跟随主题。");
        if (state.StartsWith("actions-", StringComparison.Ordinal))
        {
            if (content.CanSubmit) throw new InvalidOperationException("消息操作在确认前可提交。");
            if (section == ChatAdvancedSection.Forward)
            {
                var targetList = (ListView)content.FindName("TargetList");
                targetList.SelectedItems.Add(model.Targets[0]);
            }
            ((CheckBox)content.FindName("ActionConfirmation")).IsChecked = true;
            if (!content.CanSubmit) throw new InvalidOperationException("有效消息操作无法确认。");
            await content.SubmitAsync(); await content.SubmitAsync();
            if (repository.MutationCalls != 1) throw new InvalidOperationException("消息操作发生重复提交。");
            dialog.IsPrimaryButtonEnabled = content.CanSubmit;
            await Task.Delay(150); dialog.UpdateLayout();
        }
        if (state.StartsWith("batch-", StringComparison.Ordinal))
        {
            if (content.CanSubmit) throw new InvalidOperationException("批量操作在确认前可提交。");
            if (section is ChatAdvancedSection.Forward or ChatAdvancedSection.DeleteMessages)
            {
                var sources = (ListView)content.FindName("SourceList"); sources.SelectedItems.Clear();
                foreach (var item in sources.Items) sources.SelectedItems.Add(item);
            }
            if (section is ChatAdvancedSection.Forward or ChatAdvancedSection.CloseConversation)
            {
                var targets = (ListView)content.FindName("TargetList"); targets.SelectedItems.Clear();
                foreach (var item in targets.Items) targets.SelectedItems.Add(item);
            }
            if (state == "batch-direct") ((ListView)content.FindName("DirectUserList")).SelectedItems.Add(model.DirectUsers[0]);
            ((CheckBox)content.FindName("ActionConfirmation")).IsChecked = true;
            if (!content.CanSubmit) throw new InvalidOperationException("有效批量操作无法提交。");
            await content.SubmitAsync();
            if (state == "batch-review")
            {
                if (!model.RequiresReview || repository.MutationCalls != 1) throw new InvalidOperationException("未知批量结果没有暂停。");
                await content.SubmitAsync(); await content.SubmitAsync();
                if (!model.CanContinueBatch || content.CanSubmit || repository.MutationCalls != 1) throw new InvalidOperationException("核对结果暗中启动了剩余项。");
                ((CheckBox)content.FindName("ContinueConfirmation")).IsChecked = true;
                await content.SubmitAsync();
            }
            await content.SubmitAsync();
            var expectedCalls = state is "batch-close" or "batch-direct" ? 3 : 2;
            if (repository.MutationCalls != expectedCalls || model.RequiresReview || content.CanSubmit) throw new InvalidOperationException("批量操作结果或连点防护不正确。");
            if (state == "batch-close" && !model.BatchEntries.Any(item => item.State == ChatBatchItemState.Failed)) throw new InvalidOperationException("批量部分失败未展示。");
            dialog.PrimaryButtonText = content.PrimaryText; dialog.IsPrimaryButtonEnabled = content.CanSubmit;
            await Task.Delay(150); dialog.UpdateLayout();
        }
        var expected = state == "advanced-loading" ? "LoadingRing" : state == "advanced-error" ? "ErrorPanel" : "ContentPanel";
        if (content.FindName(expected) is not FrameworkElement { Visibility: Visibility.Visible }) throw new InvalidOperationException("高级聊天五态不正确。");
        if (state is "advanced-empty" or "advanced-filtered" && content.FindName("EmptyText") is not FrameworkElement { Visibility: Visibility.Visible })
            throw new InvalidOperationException("高级聊天没有显示空状态。");
        if (state == "advanced-readonly" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("只读环境开放了写按钮。");
        if (state == "advanced-review" && (!model.RequiresReview || !dialog.IsPrimaryButtonEnabled)) throw new InvalidOperationException("未确认操作没有保留核对入口。");
        await WriteSnapshotAsync(dialog);
        dialog.Hide(); await showing; model.CancelLoading(); await load;
    }

    private static async Task WriteSnapshotAsync(FrameworkElement windowRoot, bool markComplete = true)
    {
        var bitmap = new RenderTargetBitmap();
        // 连同自绘标题栏一起验证，避免页面正确但窗口顶部仍停留在浅色。
        await bitmap.RenderAsync(windowRoot);
        var pixels = (await bitmap.GetPixelsAsync()).ToArray();
        var file = await StorageFile.GetFileFromPathAsync(System.IO.Path.Combine(AppContext.BaseDirectory, "LanStash.App.exe"));
        var folder = await file.GetParentAsync();
        var snapshot = await folder.CreateFileAsync("workspace-smoke.png", CreationCollisionOption.ReplaceExisting);
        using var stream = await snapshot.OpenAsync(FileAccessMode.ReadWrite);
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
        await encoder.FlushAsync();
        await stream.FlushAsync();
        // 只有编码写入全部完成后才发出完成标记，避免复制尚为空的图片。
        if (markComplete) MarkSnapshotComplete();
    }
    private static void MarkSnapshotComplete() => System.IO.File.WriteAllText(System.IO.Path.Combine(AppContext.BaseDirectory, "smoke-complete.txt"), "complete");
}
