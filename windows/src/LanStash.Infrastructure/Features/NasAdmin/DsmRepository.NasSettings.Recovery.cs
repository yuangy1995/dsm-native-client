using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private static readonly ConditionalWeakTable<IProtectedTaskStore, NasManagementRegistry> NasManagementStores = new();
    private static readonly ConditionalWeakTable<IDsmApiClient, NasManagementRegistry> NasManagementMemory = new();
    private readonly IProtectedTaskStore? _nasManagementStore = nasManagementStore;
    private NasManagementRegistry NasManagementRecords => _nasManagementStore is null
        ? NasManagementMemory.GetValue(_api, _ => new() { Loaded = true }) : NasManagementStores.GetValue(_nasManagementStore, _ => new());
    public NasProfile? ConfiguredNasManagementProfile { private get; init; }
    // 定时关机会中断其他任务，真实 NAS 专项验收前保持保存入口关闭。
    public bool AllowsPowerScheduleChanges { get; init; }
    private string NasManagementOwner
    {
        get
        {
            var owner = ConfiguredNasManagementProfile ?? _profile;
            if (owner.Id != ProfileId || owner.Username != _profile.Username) throw new ArgumentException("nas.owner-mismatch");
            return ServiceHash(JsonSerializer.Serialize(new { owner.Id, owner.Username, owner.Host, owner.Port }));
        }
    }
    private async Task EnterNasManagementAsync(CancellationToken token)
    {
        if (_session.ProfileId != ProfileId || string.IsNullOrWhiteSpace(_session.Sid)) throw NasEditError(MutationErrorCategory.Authentication);
        var records = NasManagementRecords;
        if (!await records.Gate.WaitAsync(0, token).ConfigureAwait(false)) throw NasEditError(MutationErrorCategory.Conflict);
        try
        {
            if (!records.Loaded && !records.Failed)
            {
                IReadOnlyDictionary<Guid, byte[]>? stored = null;
                try
                {
                    stored = await _nasManagementStore!.LoadAsync().ConfigureAwait(false);
                    var restored = stored.Select(pair => RestoreNasManagement(pair.Key, pair.Value)).ToArray();
                    foreach (var entry in restored) records.Entries.Add(entry.Id, entry);
                    records.Loaded = true;
                }
                catch { records.Failed = true; throw; }
                finally { if (stored is not null) foreach (var bytes in stored.Values) CryptographicOperations.ZeroMemory(bytes); }
            }
            if (records.Failed) throw new IOException("nas.recovery-unavailable");
        }
        catch { records.Gate.Release(); throw; }
    }
    private async Task SaveNasManagementAsync(NasManagementRecord entry)
    {
        if (NasManagementRecords.Failed) throw new IOException("nas.recovery-unavailable");
        NasManagementRecords.Entries[entry.Id] = entry;
        if (_nasManagementStore is null) return;
        var bytes = JsonSerializer.SerializeToUtf8Bytes(entry);
        try { await _nasManagementStore.SaveAsync(entry.Id, bytes).ConfigureAwait(false); }
        catch { NasManagementRecords.Failed = true; throw; }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    private NasManagementRecord NasManagementEntry(Guid id) => NasManagementRecords.Entries.TryGetValue(id, out var entry) &&
        entry.ProfileId == ProfileId && entry.Owner == NasManagementOwner ? entry : throw NasEditError(MutationErrorCategory.Conflict);
    private static NasHardwareEditRecovery HardwareEditInfo(NasManagementRecord entry) => new(entry.Id, entry.Kind, entry.CreatedAt,
        entry.Steps.Select(step => new NasHardwareEditStep(step.Stage, step.Submitted, step.Accepted, step.Error)).ToArray());
    public async Task<IReadOnlyList<NasHardwareEditRecovery>> LoadHardwareEditRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        await EnterNasManagementAsync(cancellationToken).ConfigureAwait(false);
        try { return NasManagementRecords.Entries.Values.Where(entry => entry.Package is null && entry.ProfileId == ProfileId && entry.Owner == NasManagementOwner)
            .OrderByDescending(entry => entry.CreatedAt).Select(HardwareEditInfo).ToArray(); }
        finally { NasManagementRecords.Gate.Release(); }
    }
    public async Task<NasHardwareEditRecovery> ReviewHardwareEditAsync(Guid id, CancellationToken cancellationToken = default)
    {
        await EnterNasManagementAsync(cancellationToken).ConfigureAwait(false);
        try { var entry = NasManagementEntry(id); if (entry.Package is not null) throw NasEditError(MutationErrorCategory.Validation);
            await ReviewHardwareEditCoreAsync(entry, cancellationToken).ConfigureAwait(false); return HardwareEditInfo(entry); }
        finally { NasManagementRecords.Gate.Release(); }
    }
    private static NasManagementRecord RestoreNasManagement(Guid id, byte[] bytes)
    {
        var entry = JsonSerializer.Deserialize<NasManagementRecord>(bytes) ?? throw new InvalidDataException("nas.empty-record");
        if (entry.Package is not null) { ValidatePackageRecord(id, entry); return entry; }
        if (entry.Version != 1 || entry.Id == Guid.Empty || entry.Id != id || entry.ProfileId == Guid.Empty || !Enum.IsDefined(entry.Kind) ||
            !RecoveryHash(entry.Owner) || !RecoveryHash(entry.Signature) || entry.Steps is null ||
            entry.Steps.Length != (entry.Kind == NasHardwareEditKind.Zram ? 2 : 1)) throw new InvalidDataException("nas.invalid-record");
        foreach (var step in entry.Steps)
            if (!RecoveryHash(step.DesiredDigest) || !Enum.IsDefined(step.Stage) || step.Error is { } error && !Enum.IsDefined(error) ||
                step.Accepted && !step.Submitted || step.Stage == NasHardwareEditStage.Confirmed && !step.Accepted ||
                step.Stage == NasHardwareEditStage.NotStarted && step.Submitted ||
                step.Stage is NasHardwareEditStage.Unknown or NasHardwareEditStage.Rejected && !step.Submitted)
                throw new InvalidDataException("nas.invalid-step");
        return entry;
    }
    private sealed class NasManagementRegistry
    {
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public Dictionary<Guid, NasManagementRecord> Entries { get; } = [];
        public Dictionary<Guid, (string Id, string Name)> PackageTargets { get; } = [];
        public Dictionary<Guid, PackageInstallJob> PackageJobs { get; } = [];
        public bool Loaded, Failed;
    }
    private sealed class NasManagementRecord
    {
        public int Version { get; set; } = 1;
        public Guid Id { get; set; }
        public Guid ProfileId { get; set; }
        public string Owner { get; set; } = "";
        public NasHardwareEditKind Kind { get; set; }
        public DateTimeOffset CreatedAt { get; set; }
        public string Signature { get; set; } = "";
        public NasManagementStep[] Steps { get; set; } = [];
        public PackageRecord? Package { get; set; }
    }
    private sealed class NasManagementStep
    {
        public string DesiredDigest { get; set; } = "";
        public NasHardwareEditStage Stage { get; set; }
        public bool Submitted { get; set; }
        public bool Accepted { get; set; }
        public MutationErrorCategory? Error { get; set; }
    }
}
