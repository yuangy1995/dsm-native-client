using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private static readonly ConditionalWeakTable<IProtectedTaskStore, OfficeRegistry> OfficeStores = new();
    private static readonly ConditionalWeakTable<IDsmApiClient, OfficeRegistry> OfficeMemory = new();
    private static readonly AsyncLocal<Guid?> OfficeExecuting = new();
    private readonly IProtectedTaskStore? _officeStore = officeEditingStore;
    private OfficeRegistry OfficeRecords => _officeStore is null
        ? OfficeMemory.GetValue(_api, _ => new() { Loaded = true })
        : OfficeStores.GetValue(_officeStore, _ => new());

    public async Task InitializeOfficeRecoveryAsync()
    {
        var registry = OfficeRecords;
        await registry.LoadGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (registry.Loaded || registry.Failed) return;
            IReadOnlyDictionary<Guid, byte[]>? records = null;
            try
            {
                records = await _officeStore!.LoadAsync().ConfigureAwait(false);
                var restored = records.Select(pair => RestoreOffice(pair.Key, pair.Value)).ToArray();
                lock (registry.Entries)
                    foreach (var entry in restored) registry.Entries.Add(entry.Info.Id, entry);
                registry.Loaded = true;
            }
            catch { registry.Failed = true; }
            finally
            {
                if (records is not null) foreach (var bytes in records.Values) CryptographicOperations.ZeroMemory(bytes);
            }
        }
        finally { registry.LoadGate.Release(); }
    }

    private bool OfficeRecoveryAvailable => OfficeRecords is { Loaded: true, Failed: false };

    private bool OfficeEditingConflicts(IEnumerable<string> paths)
    {
        if (!OfficeRecoveryAvailable) return true;
        lock (OfficeRecords.Entries)
            return OfficeRecords.Entries.Values.Any(entry => entry.Info.ProfileId == ProfileId &&
                entry.Info.Id != OfficeExecuting.Value && entry.Info.State != OfficeEditingState.Stopped &&
                paths.Any(path => path == "/" || CrossNasPathsOverlap(path, entry.Info.RemotePath)));
    }

    private OfficeEntry OfficeEntryFor(Guid id)
    {
        if (!OfficeRecoveryAvailable) throw new IOException("office.recovery-unavailable");
        lock (OfficeRecords.Entries)
            return OfficeRecords.Entries.TryGetValue(id, out var entry) && entry.Info.OwnerId == OfficeOwnerId &&
                entry.Info.ProfileId == ProfileId ? entry : throw new InvalidOperationException("office.session-unavailable");
    }

    private async Task SaveOfficeRecordAsync(OfficeEntry entry)
    {
        if (!OfficeRecoveryAvailable) throw new IOException("office.recovery-unavailable");
        if (_officeStore is null) return;
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new OfficeRecord(1, entry.Info with
        {
            Baseline = entry.Info.Baseline with { Metadata = entry.Info.Baseline.Metadata with
                { Item = entry.Info.Baseline.Metadata.Item with { Owner = null } } },
        }, entry.AttemptId, entry.Attempt, entry.Upload?.Accepted ?? entry.Accepted,
            entry.Upload?.Hash ?? entry.UploadHash));
        try { await _officeStore.SaveAsync(entry.Info.Id, bytes).ConfigureAwait(false); }
        catch { OfficeRecords.Failed = true; throw; }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    private static OfficeEntry RestoreOffice(Guid id, byte[] bytes)
    {
        var record = JsonSerializer.Deserialize<OfficeRecord>(bytes) ?? throw new InvalidDataException("office.empty-record");
        var info = record.Info;
        if (record.Version != 1 || info is null || id == Guid.Empty || info.Id != id || info.ProfileId == Guid.Empty ||
            !RecoveryHash(info.OwnerId) || !ValidOfficeBaseline(info.Baseline, info.Fingerprint) ||
            !ValidOfficeLocalPath(info.LocalPath, info.Baseline.Metadata.Item.Name) || !Enum.IsDefined(info.State) ||
            info.Error is { } error && !Enum.IsDefined(error) ||
            (record.AttemptId is null) != (record.Attempt is null) || record.AttemptId == Guid.Empty ||
            record.Attempt is not null && !ValidOfficeFingerprint(record.Attempt) ||
            record.UploadHash is not null && !RecoveryHash(record.UploadHash) ||
            record.Accepted && record.Attempt is null ||
            info.State == OfficeEditingState.ResultUnavailable && record.Attempt is null ||
            record.Attempt is not null && info.State != OfficeEditingState.ResultUnavailable)
            throw new InvalidDataException("office.invalid-record");
        return new(info with { State = info.State is OfficeEditingState.Ready or OfficeEditingState.Saved
            ? OfficeEditingState.Paused : info.State })
        {
            AttemptId = record.AttemptId, Attempt = record.Attempt, Accepted = record.Accepted,
            UploadHash = record.UploadHash, StopRequested = info.StopRequested,
        };
    }

    private static bool ValidOfficeLocalPath(string? path, string remoteName) =>
        !string.IsNullOrWhiteSpace(path) && Path.IsPathFullyQualified(path) && path.IndexOf('\0') < 0 &&
        string.Equals(Path.GetExtension(path), Path.GetExtension(remoteName), StringComparison.OrdinalIgnoreCase);

    private static bool ValidOfficeFingerprint(OfficeContentFingerprint? value) => value is { Length: >= 0, Md5.Length: 32 } &&
        value.Md5.All(Uri.IsHexDigit) && RecoveryHash(value.Sha256);

    private static bool ValidOfficeBaseline(OfficeRemoteSnapshot? baseline, OfficeContentFingerprint? fingerprint) =>
        baseline?.Metadata?.Item is { IsDirectory: false, ModifiedAt: not null } item &&
        OfficeDocumentFormat.Supports(item) && ValidMutationObjectPath(item.Path) && !ArchiveContainsRecycleSegment(item.Path) &&
        item.Path.EndsWith("/" + item.Name, StringComparison.Ordinal) && !UploadIsLink(baseline.Metadata) &&
        ValidOfficeFingerprint(fingerprint) && item.Size == fingerprint!.Length &&
        string.Equals(baseline.Md5, fingerprint.Md5, StringComparison.OrdinalIgnoreCase);

    private sealed class OfficeRegistry
    {
        public SemaphoreSlim LoadGate { get; } = new(1, 1);
        public SemaphoreSlim CreateGate { get; } = new(1, 1);
        public Dictionary<Guid, OfficeEntry> Entries { get; } = [];
        public volatile bool Loaded;
        public volatile bool Failed;
    }

    private sealed class OfficeEntry(OfficeEditingSessionInfo info)
    {
        public volatile bool Creating;
        public OfficeEditingSessionInfo Info { get; set; } = info;
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public Guid? AttemptId { get; set; }
        public OfficeContentFingerprint? Attempt { get; set; }
        public bool Accepted { get; set; }
        public string? UploadHash { get; set; }
        public PendingFileUpload? Upload { get; set; }
        public volatile bool StopRequested;
    }

    private sealed record OfficeRecord(int Version, OfficeEditingSessionInfo Info, Guid? AttemptId,
        OfficeContentFingerprint? Attempt, bool Accepted, string? UploadHash);
}
