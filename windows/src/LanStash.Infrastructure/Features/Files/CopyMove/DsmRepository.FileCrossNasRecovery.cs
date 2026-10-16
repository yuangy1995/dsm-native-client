using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private static readonly ConditionalWeakTable<IProtectedTaskStore, CrossNasRecoveryRegistry> CrossNasRecoveryRegistries = new();
    private static readonly AsyncLocal<Guid?> CrossNasExecuting = new();
    private readonly IProtectedTaskStore? _crossNasStore = crossNasStore;
    private CrossNasRecoveryRegistry? CrossNasRecovery => _crossNasStore is null ? null :
        CrossNasRecoveryRegistries.GetValue(_crossNasStore, _ => new());
    private Dictionary<(string Scope, Guid Id), CrossNasTransfer> CrossNasTransfers =>
        CrossNasRecovery?.Transfers ?? ServiceMutations.CrossNasTransfers;

    public async Task InitializeCrossNasRecoveryAsync()
    {
        if (CrossNasRecovery is not { } registry) return;
        await registry.LoadGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (registry.Loaded || registry.Failed) return;
            IReadOnlyDictionary<Guid, byte[]>? records = null;
            try
            {
                records = await _crossNasStore!.LoadAsync().ConfigureAwait(false);
                var transfers = records.Select(pair => RestoreCrossNasRecord(pair.Key, pair.Value)).ToArray();
                lock (registry.Transfers)
                    foreach (var transfer in transfers) registry.Transfers.Add((transfer.SourceScope, transfer.Id), transfer);
                registry.Loaded = true;
            }
            catch { registry.Failed = true; }
            finally { if (records is not null) foreach (var bytes in records.Values) CryptographicOperations.ZeroMemory(bytes); }
        }
        finally { registry.LoadGate.Release(); }
    }

    private bool CrossNasRecoveryUnavailable => CrossNasRecovery is { } registry && (!registry.Loaded || registry.Failed);
    private bool CrossNasRecoveryConflicts(IEnumerable<string> paths)
    {
        if (CrossNasRecoveryUnavailable) return true;
        lock (CrossNasTransfers)
            return CrossNasTransfers.Values.Where(task => task.Id != CrossNasExecuting.Value).Any(task =>
                task.Request.SourceProfileId == ProfileId && task.DeletionStarted &&
                    (task.Running || task.Items.Any(item => item.DeletionState == CrossNasSourceDeletionState.ResultUnavailable)) &&
                    paths.Any(path => CrossNasPathsOverlap(path, task.Request.SourcePath)) ||
                task.Request.TargetProfileId == ProfileId && (task.Running || task.Items.Any(item => item.State == CrossNasTransferItemState.ResultUnavailable) ||
                    task.Items.Any(item => item.DeletionState == CrossNasSourceDeletionState.ResultUnavailable)) &&
                    paths.Any(path => CrossNasPathsOverlap(path, task.DestinationPath)));
    }

    private async Task SaveCrossNasAsync(CrossNasTransfer task)
    {
        if (_crossNasStore is null) return;
        if (CrossNasRecoveryUnavailable) throw new IOException("file.cross-nas.recovery-unavailable");
        var request = task.Request;
        var record = new CrossNasRecord(1, task.Id, request.SourceProfileId, request.TargetProfileId, task.SourceScope, task.TargetScope,
            request.SourcePath, request.SourceName, request.IsDirectory, request.FileSize, request.DestinationFolderPath,
            request.SourceModifiedAt, task.HasSubmitted, task.Verified, task.DeletionStarted, task.Error?.ErrorCategory,
            task.DeletionError?.ErrorCategory, task.Items.Select(item => new CrossNasItemRecord(
                item.Source with { Item = item.Source.Item with { Owner = null } }, item.RelativePath, item.State,
                item.Result?.ErrorCategory, item.UploadId, item.Upload?.Submitted ?? false, item.Upload?.Accepted ?? false,
                item.Upload?.Hash, item.FolderReview?.Accepted == true || item.Source.Item.IsDirectory && item.State == CrossNasTransferItemState.Copied,
                item.DeletionState, item.DeleteSubmitted, item.DeleteTaskId)).ToArray());
        var bytes = JsonSerializer.SerializeToUtf8Bytes(record);
        try { await _crossNasStore.SaveAsync(task.Id, bytes).ConfigureAwait(false); }
        catch { CrossNasRecovery!.Failed = true; throw; }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    private async Task FinishCrossNasCheckpointAsync(CrossNasTransfer task)
    {
        try { await SaveCrossNasAsync(task).ConfigureAwait(false); }
        catch
        {
            var error = UploadFailure(MutationErrorCategory.Unknown, "file.cross-nas.recovery-unavailable");
            if (task.DeletionStarted) task.DeletionError = error;
            else task.Error = error;
        }
    }

    private static CrossNasTransfer RestoreCrossNasRecord(Guid id, byte[] bytes)
    {
        var record = JsonSerializer.Deserialize<CrossNasRecord>(bytes) ?? throw new InvalidDataException("recovery.empty-record");
        if (record.Version != 1 || record.Id != id || id == Guid.Empty || record.SourceProfileId == Guid.Empty ||
            record.TargetProfileId == Guid.Empty || record.SourceProfileId == record.TargetProfileId ||
            !RecoveryHash(record.SourceScope) || !RecoveryHash(record.TargetScope) ||
            !ValidMutationObjectPath(record.SourcePath) || !ValidMutationDirectory(record.DestinationFolderPath) ||
            !ValidMutationItemName(record.Name) || !record.SourcePath.EndsWith("/" + record.Name, StringComparison.Ordinal) ||
            record.Size < 0 || record.Items is null || record.Items.Length > CrossNasFolderItemLimit + 1)
            throw new InvalidDataException("recovery.invalid-record");
        var request = new CrossNasCopyMoveRequest(record.SourceProfileId, record.TargetProfileId, record.SourcePath, record.Name,
            record.IsDirectory, record.Size, record.DestinationFolderPath, false, OperationId: id)
            { TargetIdentity = record.TargetScope, SourceModifiedAt = record.SourceModifiedAt };
        var destination = JoinMutationPath(record.DestinationFolderPath, record.Name);
        var task = new CrossNasTransfer(id, request, record.SourceScope, record.TargetScope, destination)
        {
            HasSubmitted = record.HasSubmitted, Verified = record.Verified, DeletionStarted = record.DeletionStarted,
            RestoredNeedsReview = true,
            Error = record.Error is { } error ? UploadFailure(error, "file.cross-nas.saved-error") : null,
            DeletionError = record.DeletionError is { } deleteError ? UploadFailure(deleteError, "file.cross-nas.saved-error") : null,
        };
        var paths = new HashSet<string>(StringComparer.Ordinal);
        task.Items = record.Items.Select((row, index) =>
        {
            var sourcePath = index == 0 ? request.SourcePath : request.SourcePath + "/" + row.RelativePath;
            if (row.Source?.Item is not { } source || !ValidMutationObjectPath(sourcePath) || source.Path != sourcePath ||
                source.Name != sourcePath[(sourcePath.LastIndexOf('/') + 1)..] || !paths.Add(sourcePath) || source.Size < 0 ||
                index == 0 && (row.RelativePath != string.Empty || source.IsDirectory != request.IsDirectory || !source.IsDirectory && source.Size != request.FileSize) ||
                index > 0 && (!request.IsDirectory || string.IsNullOrEmpty(row.RelativePath)) ||
                !Enum.IsDefined(row.State) || !Enum.IsDefined(row.DeletionState) || row.UploadId == Guid.Empty ||
                row.Hash is not null && !RecoveryHash(row.Hash) || row.DeleteTaskId is { } receipt &&
                    (string.IsNullOrWhiteSpace(receipt) || receipt.Length > 1024 || receipt.Any(char.IsControl)))
                throw new InvalidDataException("recovery.invalid-item");
            var target = index == 0 ? destination : destination + "/" + row.RelativePath;
            var state = row.State == CrossNasTransferItemState.Copying ? CrossNasTransferItemState.ResultUnavailable : row.State;
            var item = new CrossNasTransferItem(row.Source, target, row.RelativePath)
            {
                UploadId = row.UploadId, State = state,
                Result = state == CrossNasTransferItemState.Copied ? UploadResult(MutationResultStatus.ConfirmedSuccess, true, false, 1, 0, 0) :
                    state == CrossNasTransferItemState.ResultUnavailable ? UploadUnverified("file.cross-nas.restored") :
                    state == CrossNasTransferItemState.Failed ? UploadFailure(row.Error ?? MutationErrorCategory.Unknown, "file.cross-nas.saved-error") : null,
                DeletionState = row.DeletionState == CrossNasSourceDeletionState.Deleting ? CrossNasSourceDeletionState.ResultUnavailable : row.DeletionState,
                DeleteSubmitted = row.DeleteSubmitted, DeleteTaskId = row.DeleteTaskId,
            };
            if (!source.IsDirectory && (row.UploadSubmitted || state is CrossNasTransferItemState.Copied or CrossNasTransferItemState.ResultUnavailable))
                item.Upload = new(row.UploadId, source.Size, new("uploadFile", MutationParent(target), target, null, false, [target]), new())
                    { Submitted = true, Accepted = row.UploadAccepted, Hash = row.Hash, Completed = state == CrossNasTransferItemState.Copied };
            if (source.IsDirectory && state == CrossNasTransferItemState.ResultUnavailable)
                item.FolderReview = new("createFolder", MutationParent(target), target, null, true, [target]) { Accepted = row.FolderAccepted };
            return item;
        }).ToArray();
        if (task.Verified && (task.Items.Length == 0 || task.Items.Any(item => item.State != CrossNasTransferItemState.Copied)) ||
            task.Items.Any(item => item.State == CrossNasTransferItemState.Copied && !item.Source.Item.IsDirectory && item.Upload is not { Accepted: true, Hash: not null }))
            throw new InvalidDataException("recovery.invalid-completion");
        task.HasSubmitted |= task.Items.Any(item => item.State is CrossNasTransferItemState.Copied or CrossNasTransferItemState.ResultUnavailable);
        return task;
    }
    private static bool RecoveryHash(string? value) => value is { Length: 64 } && value.All(Uri.IsHexDigit);
    private sealed class CrossNasRecoveryRegistry
    {
        public SemaphoreSlim LoadGate { get; } = new(1, 1);
        public Dictionary<(string Scope, Guid Id), CrossNasTransfer> Transfers { get; } = [];
        public volatile bool Loaded;
        public volatile bool Failed;
    }
    private sealed record CrossNasRecord(int Version, Guid Id, Guid SourceProfileId, Guid TargetProfileId,
        string SourceScope, string TargetScope, string SourcePath, string Name, bool IsDirectory, long Size,
        string DestinationFolderPath, DateTimeOffset? SourceModifiedAt, bool HasSubmitted, bool Verified, bool DeletionStarted,
        MutationErrorCategory? Error, MutationErrorCategory? DeletionError, CrossNasItemRecord[] Items);
    private sealed record CrossNasItemRecord(FileEntryMetadata Source, string RelativePath, CrossNasTransferItemState State,
        MutationErrorCategory? Error, Guid UploadId, bool UploadSubmitted, bool UploadAccepted, string? Hash,
        bool FolderAccepted, CrossNasSourceDeletionState DeletionState, bool DeleteSubmitted, string? DeleteTaskId);
}
