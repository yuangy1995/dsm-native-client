using System.Globalization;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private static readonly ConditionalWeakTable<IProtectedTaskStore, DownloadRegistry> DownloadStores = new();
    private static readonly ConditionalWeakTable<IDsmApiClient, DownloadRegistry> DownloadMemory = new();
    private readonly IProtectedTaskStore? _downloadStore = downloadActionsStore;
    private DownloadRegistry DownloadRecords => _downloadStore is null
        ? DownloadMemory.GetValue(_api, _ => new() { Loaded = true }) : DownloadStores.GetValue(_downloadStore, _ => new());
    public NasProfile? ConfiguredDownloadProfile { private get; init; }
    // 未完成文件可能被移动；真实 NAS 专项验收前保持此入口关闭。
    public bool CanFinishIncomplete { get; init; }
    private string DownloadOwner
    {
        get
        {
            var owner = ConfiguredDownloadProfile ?? _profile;
            if (owner.Id != ProfileId || owner.Username != _profile.Username) throw new InvalidOperationException("download.owner-mismatch");
            return DownloadCreateDigest("owner", owner.Id.ToString("N"), owner.Username, owner.Host,
                owner.Port?.ToString(CultureInfo.InvariantCulture) ?? "");
        }
    }
    private async Task EnterDownloadsAsync(CancellationToken token)
    {
        if (_session.ProfileId != ProfileId) throw new ArgumentException("download.session-mismatch");
        if (!await DownloadRecords.Gate.WaitAsync(0, token).ConfigureAwait(false)) throw new DownloadActionConflictException();
        try
        {
            if (!DownloadRecords.Loaded && !DownloadRecords.Failed)
            {
                IReadOnlyDictionary<Guid, byte[]>? records = null;
                try
                {
                    records = await _downloadStore!.LoadAsync().ConfigureAwait(false);
                    var restored = records.Select(pair => RestoreDownloadRecord(pair.Key, pair.Value)).ToArray();
                    foreach (var entry in restored) DownloadRecords.Entries.Add(entry.Id, entry);
                    DownloadRecords.Loaded = true;
                }
                catch { DownloadRecords.Failed = true; throw; }
                finally { if (records is not null) foreach (var bytes in records.Values) CryptographicOperations.ZeroMemory(bytes); }
            }
            if (DownloadRecords.Failed) throw new IOException("download.recovery-unavailable");
        }
        catch { DownloadRecords.Gate.Release(); throw; }
    }
    private async Task SaveDownloadAsync(DownloadRecord entry)
    {
        if (DownloadRecords.Failed) throw new IOException("download.recovery-unavailable");
        DownloadRecords.Entries[entry.Id] = entry;
        if (_downloadStore is null) return;
        var bytes = JsonSerializer.SerializeToUtf8Bytes(entry);
        try { await _downloadStore.SaveAsync(entry.Id, bytes).ConfigureAwait(false); }
        catch { DownloadRecords.Failed = true; throw new DownloadActionPersistenceException(entry.Steps.Any(step => step.Submitted)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    private DownloadRecord DownloadEntry(Guid id) => DownloadRecords.Entries.TryGetValue(id, out var entry) &&
        entry.ProfileId == ProfileId && entry.Owner == DownloadOwner ? entry : throw new DownloadActionConflictException();
    private DownloadRecord? PendingDownload(DownloadActionKind kind, IEnumerable<string> targets)
    {
        var keys = targets.ToHashSet(StringComparer.Ordinal);
        return DownloadRecords.Entries.Values.FirstOrDefault(entry => entry.Owner == DownloadOwner && entry.ProfileId == ProfileId &&
            entry.Steps.Any(step => DownloadPending(step.Stage) && keys.Contains(step.Target)) &&
            DownloadScope(entry.Kind) == DownloadScope(kind));
    }
    private static int DownloadScope(DownloadActionKind kind) => kind switch
    { DownloadActionKind.CreateLink or DownloadActionKind.CreateFile => 0, DownloadActionKind.RefreshRss => 1, DownloadActionKind.Settings => 2, _ => 3 };
    private static bool DownloadPending(DownloadActionStage stage) => stage is DownloadActionStage.NotStarted or DownloadActionStage.Unknown;
    private DownloadRecord NewDownload(DownloadActionKind kind, DownloadStep[] steps, Guid? id = null) => new()
    { Id = id ?? Guid.NewGuid(), ProfileId = ProfileId, Owner = DownloadOwner, Kind = kind, CreatedAt = DateTimeOffset.UtcNow, Steps = steps };
    private static string DownloadIdentity(DownloadTask task) => DownloadCreateDigest("task", task.Id, task.Title,
        task.Size?.ToString(CultureInfo.InvariantCulture) ?? "");
    private static string DownloadLocation(string? value) => DownloadCreateDigest("destination", value ?? "");
    private static bool ValidDownloadId(string? id) => !string.IsNullOrWhiteSpace(id) && id == id.Trim() && !id.Contains(',') && !id.Any(char.IsControl);
    private static DownloadActionInfo DownloadInfo(DownloadRecord entry) => new(entry.Id, entry.ProfileId, entry.Kind, entry.CreatedAt,
        entry.Steps.Select(step => new DownloadActionItem(step.Target, step.Stage, step.Error, step.Current) { WasSubmitted = step.Submitted }).ToArray())
        { CancellationRequestedAfterSubmission = entry.CancelledAfterSubmission };
    public async Task<IReadOnlyList<DownloadActionInfo>> LoadDownloadActionsAsync(CancellationToken cancellationToken = default)
    {
        await EnterDownloadsAsync(cancellationToken).ConfigureAwait(false);
        try { return DownloadRecords.Entries.Values.Where(entry => entry.Owner == DownloadOwner && entry.ProfileId == ProfileId)
            .OrderByDescending(entry => entry.CreatedAt).Select(DownloadInfo).ToArray(); }
        finally { DownloadRecords.Gate.Release(); }
    }
    public Task<DownloadActionInfo> ReviewDownloadActionAsync(Guid id, CancellationToken cancellationToken = default) =>
        RunExistingDownloadAsync(id, false, false, cancellationToken);
    public Task<DownloadActionInfo> ContinueDownloadActionAsync(Guid id, CancellationToken cancellationToken = default) =>
        RunExistingDownloadAsync(id, true, false, cancellationToken);
    public Task<DownloadActionInfo> CancelDownloadActionRemainderAsync(Guid id, CancellationToken cancellationToken = default) =>
        RunExistingDownloadAsync(id, false, true, cancellationToken);
    private async Task<DownloadActionInfo> RunExistingDownloadAsync(Guid id, bool resume, bool cancel, CancellationToken token)
    {
        await EnterDownloadsAsync(token).ConfigureAwait(false);
        try
        {
            var entry = DownloadEntry(id);
            entry.CancelledAfterSubmission = false;
            if (cancel)
            {
                foreach (var step in entry.Steps.Where(step => step.Stage == DownloadActionStage.NotStarted)) step.Stage = DownloadActionStage.Cancelled;
                await SaveDownloadAsync(entry).ConfigureAwait(false);
            }
            else
            {
                await ReviewDownloadAsync(entry, token).ConfigureAwait(false);
                if (resume && !entry.Steps.Any(step => step.Stage == DownloadActionStage.Unknown))
                {
                    if (entry.Kind == DownloadActionKind.Settings) await ExecuteDownloadSettingsAsync(entry, token).ConfigureAwait(false);
                    else if (DownloadScope(entry.Kind) == 3) await ExecuteDownloadTasksAsync(entry, token).ConfigureAwait(false);
                }
            }
            return DownloadInfo(entry);
        }
        finally { DownloadRecords.Gate.Release(); }
    }
    private async Task ReviewDownloadAsync(DownloadRecord entry, CancellationToken token)
    {
        foreach (var step in entry.Steps.Where(step => step.Stage == DownloadActionStage.Unknown))
        {
            try
            {
                if (DownloadScope(entry.Kind) == 0)
                {
                    // 没有查询创建操作的官方编号；完整列表不能替代丢失的接受回执。
                    await LoadAllPublicDownloadTasksAsync(token).ConfigureAwait(false);
                    continue;
                }
                if (entry.Kind == DownloadActionKind.Settings)
                {
                    if (await DownloadSettingsStepMatchesAsync(step, desired: true, token).ConfigureAwait(false)) step.Stage = DownloadActionStage.Confirmed;
                }
                else if (entry.Kind == DownloadActionKind.RefreshRss)
                {
                    var site = (await ListRssSitesAsync(token).ConfigureAwait(false)).SingleOrDefault(site => site.Id.ToString(CultureInfo.InvariantCulture) == step.Target);
                    if (site is not null && site.IdentityDigest == step.Identity && !site.IsUpdating && site.LastUpdate > step.LastUpdate)
                        step.Stage = DownloadActionStage.Confirmed;
                    else if (site is not null && site.IdentityDigest != step.Identity) step.Error = MutationErrorCategory.Conflict;
                }
                else
                {
                    var current = (await LoadAllPublicDownloadTasksAsync(token).ConfigureAwait(false)).SingleOrDefault(task => task.Id == step.Target);
                    if (entry.Kind is DownloadActionKind.Remove or DownloadActionKind.FinishIncomplete)
                    {
                        if (step.Accepted && current is null) step.Stage = DownloadActionStage.Confirmed;
                    }
                    else if (current is not null && DownloadIdentity(current) == step.Identity)
                    {
                        step.Current = current;
                        var reached = entry.Kind switch
                        {
                            DownloadActionKind.Pause => current.State == DownloadTaskState.Paused && DownloadLocation(current.Destination) == step.Location,
                            DownloadActionKind.Resume => (current.State is DownloadTaskState.Waiting or DownloadTaskState.Downloading or DownloadTaskState.Checking or DownloadTaskState.Seeding or DownloadTaskState.Finished) && DownloadLocation(current.Destination) == step.Location,
                            DownloadActionKind.EditDestination => step.Accepted && current.Destination == step.Destination,
                            _ => false,
                        };
                        if (reached) step.Stage = DownloadActionStage.Confirmed;
                    }
                    if (current is not null && DownloadIdentity(current) != step.Identity) step.Error = MutationErrorCategory.Conflict;
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { break; }
            catch { /* 已提交记录保持未知；回读失败不会解除防重。 */ }
            await SaveDownloadAsync(entry).ConfigureAwait(false);
        }
    }
    private static DownloadRecord RestoreDownloadRecord(Guid id, byte[] bytes)
    {
        var entry = JsonSerializer.Deserialize<DownloadRecord>(bytes) ?? throw new InvalidDataException("download.empty-record");
        if (entry.Version != 1 || id == Guid.Empty || entry.Id != id || entry.ProfileId == Guid.Empty || !RecoveryHash(entry.Owner) ||
            !Enum.IsDefined(entry.Kind) || entry.Steps is not { Length: > 0 } || entry.Steps.Select(step => step.Target).Distinct().Count() != entry.Steps.Length)
            throw new InvalidDataException("download.invalid-record");
        foreach (var step in entry.Steps)
        {
            if (!ValidDownloadId(step.Target) || !Enum.IsDefined(step.Stage) || step.Error is { } error && !Enum.IsDefined(error) ||
                !RecoveryHash(step.Identity) || step.Location is not null && !RecoveryHash(step.Location) ||
                step.Destination is not null && !ValidDownloadSettingsDestination(step.Destination) || step.LastUpdate < 0 ||
                step.Stage == DownloadActionStage.Accepted && !step.Accepted ||
                DownloadScope(entry.Kind) == 0 && (!RecoveryHash(step.Target) || step.Stage == DownloadActionStage.NotStarted) ||
                DownloadScope(entry.Kind) == 3 && (step.Location is null || !Enum.IsDefined(step.ExpectedState) || step.RawStatus is null) ||
                entry.Kind == DownloadActionKind.EditDestination && step.Destination is null ||
                entry.Kind == DownloadActionKind.Settings && !ValidDownloadSettingsStep(step))
                throw new InvalidDataException("download.invalid-step");
        }
        return entry;
    }
    private sealed class DownloadRegistry
    {
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public Dictionary<Guid, DownloadRecord> Entries { get; } = [];
        public bool Loaded, Failed;
    }
    private sealed class DownloadRecord
    {
        public int Version { get; set; } = 1;
        public Guid Id { get; set; }
        public Guid ProfileId { get; set; }
        public string Owner { get; set; } = "";
        public DownloadActionKind Kind { get; set; }
        public DateTimeOffset CreatedAt { get; set; }
        public DownloadStep[] Steps { get; set; } = [];
        [JsonIgnore] public bool CancelledAfterSubmission { get; set; }
    }
    private sealed class DownloadStep
    {
        public string Target { get; set; } = "";
        public string Identity { get; set; } = "";
        public string? Location { get; set; }
        public string? Destination { get; set; }
        public DownloadTaskState ExpectedState { get; set; }
        public string? RawStatus { get; set; }
        public long LastUpdate { get; set; }
        public DownloadActionStage Stage { get; set; }
        public bool Accepted { get; set; }
        public bool Submitted { get; set; }
        public MutationErrorCategory? Error { get; set; }
        public Dictionary<string, string>? Before { get; set; }
        public Dictionary<string, string>? Desired { get; set; }
        [JsonIgnore] public DownloadTask? Current { get; set; }
    }
    private sealed class DownloadActionConflictException : Exception;
    private sealed class DownloadActionPersistenceException(bool submitted) : IOException
    { public bool Submitted { get; } = submitted; }
}
