using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private enum PackageSubmissionKind { Control, Preferences, Upload, Download, Install, CancelDownload, Cleanup }
    // 与硬件摘要共用用户保护存储；套件字段独立，旧硬件记录没有此对象。
    private sealed class PackageRecord
    {
        public NasPackageActivityKind Kind { get; set; }
        public NasPackageAction? Action { get; set; }
        public NasPackageStepStage Stage { get; set; }
        public PackageSubmissionKind SubmissionKind { get; set; }
        public bool Submitted { get; set; }
        public bool Accepted { get; set; }
        public MutationErrorCategory? Error { get; set; }
        public string TargetDigest { get; set; } = "";
        public string DesiredDigest { get; set; } = "";
        public string? RemovedDigest { get; set; }
        public int CurrentIndex { get; set; }
        public PackageInstallReceipt[] Items { get; set; } = [];
    }
    private sealed class PackageInstallReceipt
    {
        public string TargetDigest { get; set; } = "";
        public string VersionDigest { get; set; } = "";
        public string OriginalDigest { get; set; } = "";
        public bool SameVersion { get; set; }
        public bool CompletedReceipt { get; set; }
        public NasPackageStepStage Stage { get; set; }
        public bool Submitted { get; set; }
        public bool Accepted { get; set; }
    }
    private IEnumerable<NasManagementRecord> OwnedPackageRecords => NasManagementRecords.Entries.Values.Where(entry =>
        entry.Package is not null && entry.ProfileId == ProfileId && entry.Owner == NasManagementOwner);
    private NasManagementRecord PackageRecordById(Guid id)
    {
        var entry = NasManagementEntry(id);
        return entry.Package is not null ? entry : throw PackageError();
    }
    private NasManagementRecord NewPackageRecord(Guid id, string signature, NasPackageActivityKind kind, string targetDigest, string desiredDigest) => new()
    {
        Id = id, ProfileId = ProfileId, Owner = NasManagementOwner, Signature = signature, CreatedAt = DateTimeOffset.UtcNow,
        Package = new() { Kind = kind, TargetDigest = targetDigest, DesiredDigest = desiredDigest },
    };
    private static void ValidatePackageRecord(Guid id, NasManagementRecord entry)
    {
        var value = entry.Package!;
        if (entry.Version != 1 || id == Guid.Empty || entry.Id != id || entry.ProfileId == Guid.Empty ||
            !RecoveryHash(entry.Owner) || !RecoveryHash(entry.Signature) || entry.Steps is not { Length: 0 } ||
            !Enum.IsDefined(value.Kind) || !Enum.IsDefined(value.Stage) || !Enum.IsDefined(value.SubmissionKind) ||
            value.Action is { } action && !Enum.IsDefined(action) || value.Kind == NasPackageActivityKind.Control && value.Action is null ||
            value.Kind != NasPackageActivityKind.Control && value.Action is not null ||
            !RecoveryHash(value.TargetDigest) || !RecoveryHash(value.DesiredDigest) || value.RemovedDigest is { } removed && !RecoveryHash(removed) ||
            value.Accepted && !value.Submitted || value.Stage == NasPackageStepStage.Confirmed && !value.Accepted ||
            value.Stage == NasPackageStepStage.NotStarted && value.Submitted || value.Stage == NasPackageStepStage.Unknown && !value.Submitted ||
            value.Error is { } error && !Enum.IsDefined(error) || value.Items is null || value.CurrentIndex < 0 || value.CurrentIndex > value.Items.Length ||
            value.Kind is not (NasPackageActivityKind.Installation or NasPackageActivityKind.Upload) && value.Items.Length != 0 ||
            value.Kind == NasPackageActivityKind.Installation && value.Items.Length == 0)
            throw new InvalidDataException("package.invalid-record");
        foreach (var item in value.Items)
            if (item is null || !RecoveryHash(item.TargetDigest) || !RecoveryHash(item.VersionDigest) || !RecoveryHash(item.OriginalDigest) ||
                !Enum.IsDefined(item.Stage) || item.Accepted && !item.Submitted || item.CompletedReceipt && !item.Accepted ||
                item.Stage == NasPackageStepStage.NotStarted && item.Submitted || item.Stage == NasPackageStepStage.Unknown && !item.Submitted ||
                item.Stage == NasPackageStepStage.Confirmed && !item.Accepted)
                throw new InvalidDataException("package.invalid-receipt");
        if (value.Items.Select(item => item.TargetDigest).Distinct(StringComparer.Ordinal).Count() != value.Items.Length ||
            value.Items.Length > 0 && value.Stage == NasPackageStepStage.Confirmed && value.Items.Any(item => item.Stage != NasPackageStepStage.Confirmed))
            throw new InvalidDataException("package.incomplete-receipts");
    }
    private static NasPackageActivity PackageActivityInfo(NasManagementRecord entry)
    {
        var value = entry.Package!;
        return new(entry.Id, value.Kind, entry.CreatedAt, value.Stage, value.Submitted, value.Accepted,
            value.Items.Count(item => item.Stage == NasPackageStepStage.Confirmed), Math.Max(1, value.Items.Length), value.Error,
            CanEndPackageQueue(value));
    }
    private static bool CanEndPackageQueue(PackageRecord record) => record.Kind == NasPackageActivityKind.Installation &&
        record.Stage is NasPackageStepStage.Unknown or NasPackageStepStage.NotStarted && record.Items.Length > 0 &&
        record.Items.Any(item => !item.Submitted) && record.Items.All(item => !item.Submitted || item.Stage == NasPackageStepStage.Confirmed) &&
        record.SubmissionKind == PackageSubmissionKind.Install;
    private NasManagementRecord? ExistingPackageRequest(Guid id, string signature)
    {
        if (id == Guid.Empty) throw PackageError();
        if (NasManagementRecords.Entries.TryGetValue(id, out var entry))
        {
            if (entry.Package is null || entry.Owner != NasManagementOwner || entry.ProfileId != ProfileId || entry.Signature != signature)
                throw PackageError("NasPackageConflict", MutationErrorCategory.Conflict);
            return entry;
        }
        RequirePackageIdle(); return null;
    }
    private void RequirePackageIdle()
    {
        if (OwnedPackageRecords.Any(entry => entry.Package!.Stage is NasPackageStepStage.NotStarted or NasPackageStepStage.Unknown))
            throw PackageError("NasPackageCenterBusy", MutationErrorCategory.Conflict);
    }
    public async Task<IReadOnlyList<NasPackageActivity>> LoadPackageActivitiesAsync(CancellationToken token = default)
    {
        await EnterNasManagementAsync(token).ConfigureAwait(false);
        try { return OwnedPackageRecords.OrderByDescending(entry => entry.CreatedAt).Select(PackageActivityInfo).ToArray(); }
        finally { NasManagementRecords.Gate.Release(); }
    }
    public async Task<NasPackageActivity> ReviewPackageActivityAsync(Guid id, CancellationToken token = default)
    {
        await EnterNasManagementAsync(token).ConfigureAwait(false);
        try { var entry = PackageRecordById(id); await ReviewPackageRecordCoreAsync(entry, token).ConfigureAwait(false); return PackageActivityInfo(entry); }
        finally { NasManagementRecords.Gate.Release(); }
    }
    private async Task ReviewPackageRecordCoreAsync(NasManagementRecord entry, CancellationToken token)
    {
        var record = entry.Package!;
        if (record.Stage is not (NasPackageStepStage.Unknown or NasPackageStepStage.NotStarted)) return;
        await RequirePackagePermissionAsync(token).ConfigureAwait(false);
        if (record.Kind == NasPackageActivityKind.Control)
        {
            var current = (await LoadPackagesAsync(token).ConfigureAwait(false)).FirstOrDefault(item => ServiceHash(item.Id) == record.TargetDigest);
            var matches = record.Action == NasPackageAction.Uninstall ? current is null : current is not null &&
                PackageInstallationIdentity(current) == record.DesiredDigest && (record.Action == NasPackageAction.Start ? current.IsRunning : current.IsStopped);
            if (record.Accepted && matches) { record.Stage = NasPackageStepStage.Confirmed; record.Error = null; }
        }
        else if (record.Kind == NasPackageActivityKind.Settings)
        {
            var actual = await LoadPackageCenterSettingsAsync(token).ConfigureAwait(false);
            if (record.Accepted && PackageSettingsTargetDigest(actual) == record.DesiredDigest)
            { record.Stage = NasPackageStepStage.Confirmed; record.Error = null; }
        }
        else if (record.Kind is NasPackageActivityKind.SaveSource or NasPackageActivityKind.RemoveSource)
        {
            var actual = await LoadPackageSourcesAsync(token).ConfigureAwait(false);
            var matches = record.Kind == NasPackageActivityKind.RemoveSource ? !actual.Any(source => ServiceHash(source.Url) == record.TargetDigest) :
                actual.Any(source => PackageSourceDigest(source) == record.DesiredDigest) &&
                (record.RemovedDigest is null || !actual.Any(source => ServiceHash(source.Url) == record.RemovedDigest));
            if (record.Accepted && matches) { record.Stage = NasPackageStepStage.Confirmed; record.Error = null; }
        }
        else
        {
            // 冷恢复只读正式安装；上传/下载中断与未提交依赖均不能从已安装目录认领。
            var installed = await LoadPackagesAsync(token).ConfigureAwait(false);
            foreach (var item in record.Items.Where(item => item.Submitted && item.Accepted && item.Stage == NasPackageStepStage.Unknown && (!item.SameVersion || item.CompletedReceipt)))
                if (installed.Any(current => ServiceHash(current.Id) == item.TargetDigest && ServiceHash(current.Version ?? "") == item.VersionDigest &&
                    (current.IsRunning || current.IsStopped))) item.Stage = NasPackageStepStage.Confirmed;
            if (record.Items.Length > 0 && record.Items.All(item => item.Stage == NasPackageStepStage.Confirmed))
            { record.Stage = NasPackageStepStage.Confirmed; record.Error = null; }
        }
        await SaveNasManagementAsync(entry).ConfigureAwait(false);
    }
    private async Task SubmitPackageCommandAsync(NasManagementRecord entry, PackageSubmissionKind step, string api, int version,
        string method, Dictionary<string, object> parameters, CancellationToken token)
    {
        await RequirePackagePermissionAsync(token).ConfigureAwait(false);
        var record = entry.Package!; record.SubmissionKind = step; record.Stage = NasPackageStepStage.Unknown;
        record.Submitted = true; record.Accepted = false; record.Error = null;
        token.ThrowIfCancellationRequested();
        await SaveNasManagementAsync(entry).ConfigureAwait(false);
        try { await PackageCallAsync(api, version, method, parameters, token).ConfigureAwait(false); record.Accepted = true; }
        catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) &&
            (step != PackageSubmissionKind.Control || error.Code is 102 or 103 or 104 or 105 or 106 or 107 or 119 or 404 or 408 or 900))
        { record.Stage = NasPackageStepStage.Rejected; record.Error = ServiceErrorCategory(error); }
        catch (Exception) { record.Error = MutationErrorCategory.Network; }
        await SaveNasManagementAsync(entry).ConfigureAwait(false);
    }
    private static string PackageInstallationIdentity(NasPackageSummary value) => ServiceHash(JsonSerializer.Serialize(new
    { value.Id, value.Version, value.InstallType, value.InstalledAt }));
}
