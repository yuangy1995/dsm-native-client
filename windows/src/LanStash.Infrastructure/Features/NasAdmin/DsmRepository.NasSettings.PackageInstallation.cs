using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private readonly CancellationTokenSource _packageTrackingLifetime = new();
    internal bool PackageBackgroundTrackingEnabled { get; init; } = true;
    private sealed class PackageInstallJob(NasManagementRecord entry, PackageCandidate[] candidates, NasPackageInstallItem[] items,
        IReadOnlyList<NasPackageSummary> installed, Dictionary<string, string> volumes, bool start, CancellationToken ownerLifetime)
    {
        public CancellationToken OwnerLifetime { get; } = ownerLifetime;
        public NasManagementRecord Entry { get; } = entry;
        public PackageCandidate[] Candidates { get; } = candidates;
        public NasPackageInstallItem[] Items { get; } = items;
        public IReadOnlyList<NasPackageSummary> Installed { get; } = installed;
        public Dictionary<string, string> Volumes { get; } = volumes;
        public bool StartAfterInstall { get; set; } = start;
        public int Index { get; set; }
        public NasPackageInstallPhase Phase { get; set; }
        public double? Fraction { get; set; }
        public string? TaskId { get; set; }
        public JsonObject? Checked { get; set; }
        public NasPackageInstallConfiguration? Configuration { get; set; }
        public string? MessageKey { get; set; }
        public bool Manual, FinalSubmitted, CancelRequested, CancelAccepted, CleanupSubmitted, Paused;
        public int MonitorActive;
        public PackageCandidate Current => Candidates[Math.Min(Index, Candidates.Length - 1)];
        public NasPackageInstallProgress Progress => new(Entry.Id, Current.Entry.Name,
            Entry.Package!.Items.Count(item => item.Stage == NasPackageStepStage.Confirmed), Candidates.Length, Phase, Fraction, Configuration,
            !CancelRequested && !FinalSubmitted && !CleanupSubmitted && (Phase is NasPackageInstallPhase.Downloading or NasPackageInstallPhase.Unknown && TaskId is not null || Checked is not null), MessageKey);
    }
    public async Task<NasPackageInstallProgress> StartPackageInstallationAsync(NasPackageInstallRequest request, CancellationToken token = default)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, _packageTrackingLifetime.Token); token = lifetime.Token;
        if (!AllowsPackageInstallation) throw PackageError("NasPackageCenterProtected", MutationErrorCategory.Unsupported);
        if (request.ProfileId != ProfileId || !request.RiskConfirmed || request.RequestId == Guid.Empty) throw PackageError();
        var volumes = new Dictionary<string, string>(request.Volumes, StringComparer.Ordinal);
        var signature = ServiceHash(JsonSerializer.Serialize(new { request.PlanId, request.StartAfterInstall, Volumes = volumes.OrderBy(pair => pair.Key, StringComparer.Ordinal) }));
        await EnterNasManagementAsync(token).ConfigureAwait(false);
        try
        {
            if (ExistingPackageRequest(request.RequestId, signature) is { } previous) return PackageProgressForRecord(previous);
            var saved = _packageInstallPlan;
            if (saved is null || saved.Plan.Id != request.PlanId || saved.Plan.ProfileId != ProfileId) throw PackageError();
            await RequirePackagePermissionAsync(token).ConfigureAwait(false);
            var catalog = await ReadPackageCatalogAsync(token).ConfigureAwait(false);
            var fresh = await BuildPackagePlanAsync(saved.RequestedIds, catalog, token).ConfigureAwait(false);
            if (!PackagePlansEqual(saved, fresh) || volumes.Keys.Any(key => !saved.Plan.Items.Any(item => item.Package.Id == key))) throw PackageError();
            foreach (var item in saved.Plan.Items) RequirePackageVolume(volumes.GetValueOrDefault(item.Package.Id) ?? item.DefaultVolumeId, item);
            token.ThrowIfCancellationRequested();
            var entry = NewPackageRecord(request.RequestId, signature, NasPackageActivityKind.Installation, ServiceHash("package-installation"), ServiceHash(signature));
            entry.Package!.Items = saved.Candidates.Select(candidate => InstallReceipt(candidate, saved.Installed)).ToArray();
            var job = new PackageInstallJob(entry, saved.Candidates, saved.Plan.Items.ToArray(), saved.Installed, volumes, request.StartAfterInstall, _packageTrackingLifetime.Token);
            NasManagementRecords.PackageJobs.Add(entry.Id, job); _packageInstallPlan = null;
            await SubmitCurrentPackageAsync(job, token).ConfigureAwait(false);
            StartPackageMonitor(job); return job.Progress;
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    private static PackageInstallReceipt InstallReceipt(PackageCandidate candidate, IReadOnlyList<NasPackageSummary> installed) => new()
    {
        TargetDigest = ServiceHash(candidate.Entry.PackageId), VersionDigest = ServiceHash(candidate.Entry.Version),
        OriginalDigest = installed.FirstOrDefault(item => item.Id == candidate.Entry.PackageId) is { } old ? PackageInstallationIdentity(old) : ServiceHash("not-installed"),
        SameVersion = candidate.Entry.InstalledVersion == candidate.Entry.Version,
    };
    private NasPackageInstallProgress PackageProgressForRecord(NasManagementRecord entry)
    {
        if (NasManagementRecords.PackageJobs.TryGetValue(entry.Id, out var job) && !job.OwnerLifetime.IsCancellationRequested) return job.Progress;
        var record = entry.Package!;
        return new(entry.Id, "", record.Items.Count(item => item.Stage == NasPackageStepStage.Confirmed), Math.Max(1, record.Items.Length),
            record.Stage switch { NasPackageStepStage.Confirmed => NasPackageInstallPhase.Completed, NasPackageStepStage.Rejected => NasPackageInstallPhase.Failed,
                NasPackageStepStage.Cancelled => NasPackageInstallPhase.Cancelled, _ => NasPackageInstallPhase.Interrupted },
                MessageKey: record.Stage is NasPackageStepStage.Unknown or NasPackageStepStage.NotStarted ? "NasPackageCenterInterrupted" : null);
    }
    public async Task<NasPackageInstallProgress?> GetPackageInstallationAsync(CancellationToken token = default)
    {
        await EnterNasManagementAsync(token).ConfigureAwait(false);
        try
        {
            var entry = OwnedPackageRecords.Where(entry => entry.Package!.Kind is NasPackageActivityKind.Installation or NasPackageActivityKind.Upload)
                .OrderByDescending(entry => entry.CreatedAt).FirstOrDefault();
            return entry is null ? null : PackageProgressForRecord(entry);
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    private async Task SubmitCurrentPackageAsync(PackageInstallJob job, CancellationToken token)
    {
        try
        {
            if (job.Paused || job.OwnerLifetime.IsCancellationRequested || _packageTrackingLifetime.IsCancellationRequested) throw new OperationCanceledException();
            var candidate = job.Current;
            RequirePackageWorkflowCapabilities(candidate);
            await RequirePackagePermissionAsync(token).ConfigureAwait(false);
            var catalog = await ReadPackageCatalogAsync(token).ConfigureAwait(false);
            if (!catalog.Candidates.TryGetValue(candidate.Entry.Id, out var current) || !JsonNode.DeepEquals(candidate.Raw, current.Raw)) throw PackageError();
            RequireOriginalPackageInstallation(job, catalog.Installed);
            await PackageFeasibilityAsync([candidate.Entry.PackageId], token).ConfigureAwait(false);
            var environment = await PackageEnvironmentAsync(candidate, token).ConfigureAwait(false);
            var volume = job.Volumes.GetValueOrDefault(candidate.Entry.Id) ?? job.Items[job.Index].DefaultVolumeId;
            RequirePackageVolume(volume, environment);
            var parameters = new Dictionary<string, object> { ["name"] = candidate.Entry.PackageId, ["blqinst"] = candidate.Quick };
            if (candidate.Quick)
            {
                parameters["volume_path"] = volume; parameters["is_syno"] = candidate.Entry.IsOfficial;
                parameters["beta"] = candidate.Entry.IsBeta; parameters["installrunpackage"] = job.StartAfterInstall;
            }
            else
            {
                if (PackageText(candidate.Raw, "link") is not { Length: > 0 } link || PackageText(candidate.Raw, "md5") is not { Length: > 0 } checksum ||
                    PackageInteger(candidate.Raw, "size") is not > 0 || PackageInteger(candidate.Raw, "type") is not { } type) throw InvalidNasServiceSettings();
                parameters["url"] = link; parameters["checksum"] = checksum; parameters["filesize"] = PackageInteger(candidate.Raw, "size")!.Value;
                parameters["type"] = type; parameters["operation"] = candidate.Entry.InstalledVersion is null ? "install" : "upgrade";
            }
            var step = candidate.Quick ? PackageSubmissionKind.Install : PackageSubmissionKind.Download;
            var result = await SubmitInstallationRequestAsync(job, step, candidate.Entry.InstalledVersion is null ? "install" : "upgrade", parameters, token).ConfigureAwait(false);
            if (result is null) return;
            job.TaskId = PackageText(result, "taskid") ?? (result["data"] is JsonObject nested ? PackageText(nested, "taskid") : null);
            if (result["progress"] is not JsonValue progressValue || !progressValue.TryGetValue<double>(out var progress) || !double.IsFinite(progress))
            { PackageJobUnknown(job); return; }
            if (progress < 0) { await RejectPackageJobAsync(job, MutationErrorCategory.Server).ConfigureAwait(false); return; }
            if (string.IsNullOrWhiteSpace(job.TaskId)) { PackageJobUnknown(job); return; }
            job.Fraction = Math.Min(progress, 1); job.Phase = candidate.Quick ? NasPackageInstallPhase.Installing : NasPackageInstallPhase.Downloading;
        }
        catch (Exception error)
        {
            if (job.Entry.Package!.Submitted && job.Entry.Package.Stage == NasPackageStepStage.Unknown) PackageJobUnknown(job);
            else await RejectPackageJobAsync(job, PackageFailureCategory(error)).ConfigureAwait(false);
            if (NasManagementRecords.Failed) throw;
        }
    }
    private async Task<JsonObject?> SubmitInstallationRequestAsync(PackageInstallJob job, PackageSubmissionKind step, string method,
        Dictionary<string, object> parameters, CancellationToken token)
    {
        await RequirePackagePermissionAsync(token).ConfigureAwait(false);
        if (!AllowsPackageInstallation || job.Paused || job.OwnerLifetime.IsCancellationRequested || _packageTrackingLifetime.IsCancellationRequested) throw PackageError("NasPackageCenterProtected", MutationErrorCategory.Unsupported);
        token.ThrowIfCancellationRequested();
        var record = job.Entry.Package!;
        record.SubmissionKind = step; record.Stage = NasPackageStepStage.Unknown; record.Submitted = true; record.Accepted = false; record.Error = null;
        if (step == PackageSubmissionKind.Install)
        {
            var receipt = record.Items[job.Index]; receipt.Stage = NasPackageStepStage.Unknown; receipt.Submitted = true; receipt.Accepted = false;
            job.FinalSubmitted = true; job.Phase = NasPackageInstallPhase.Installing;
        }
        else job.Phase = NasPackageInstallPhase.Downloading;
        await SaveNasManagementAsync(job.Entry).ConfigureAwait(false);
        JsonObject result;
        try { result = await PackageCallAsync("SYNO.Core.Package.Installation", 1, method, parameters, token).ConfigureAwait(false); }
        catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
        { await RejectPackageJobAsync(job, ServiceErrorCategory(error)).ConfigureAwait(false); return null; }
        catch (Exception) { PackageJobUnknown(job); record.Error = MutationErrorCategory.Network; await SaveNasManagementAsync(job.Entry).ConfigureAwait(false); return null; }
        record.Accepted = true;
        if (step == PackageSubmissionKind.Install) record.Items[job.Index].Accepted = true;
        await SaveNasManagementAsync(job.Entry).ConfigureAwait(false);
        return result;
    }
    private static void RequireOriginalPackageInstallation(PackageInstallJob job, IReadOnlyList<NasPackageSummary> installed)
    {
        var current = installed.FirstOrDefault(item => item.Id == job.Current.Entry.PackageId);
        if ((current is null ? ServiceHash("not-installed") : PackageInstallationIdentity(current)) != job.Entry.Package!.Items[job.Index].OriginalDigest)
            throw PackageError();
    }
    public async Task<NasPackageInstallProgress> AdvancePackageInstallationAsync(Guid id, CancellationToken token = default)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, _packageTrackingLifetime.Token); token = lifetime.Token;
        PackageInstallJob? monitoring = null;
        await EnterNasManagementAsync(token).ConfigureAwait(false);
        try
        {
            var entry = PackageRecordById(id);
            if (!NasManagementRecords.PackageJobs.TryGetValue(id, out var job) || job.OwnerLifetime.IsCancellationRequested)
            { await ReviewPackageRecordCoreAsync(entry, token).ConfigureAwait(false); return PackageProgressForRecord(entry); }
            monitoring = job;
            if (job.Phase is NasPackageInstallPhase.Completed or NasPackageInstallPhase.Failed or NasPackageInstallPhase.Cancelled or NasPackageInstallPhase.NeedsOptions) return job.Progress;
            try
            {
                await RequirePackagePermissionAsync(token).ConfigureAwait(false);
                if (job.CleanupSubmitted) { PackageJobUnknown(job); return job.Progress; }
                if (job.TaskId is { } taskId)
                {
                    var status = await PackageCallAsync("SYNO.Core.Package.Installation", 1, "status", new() { ["task_id"] = taskId }, token).ConfigureAwait(false);
                    if (PackageBoolean(status, "finished") is not { } finished) throw InvalidNasServiceSettings();
                    if (status["progress"] is JsonValue value && value.TryGetValue<double>(out var fraction) && double.IsFinite(fraction) && fraction is >= 0 and <= 1) job.Fraction = fraction;
                    if (!finished)
                    { job.Phase = job.FinalSubmitted ? NasPackageInstallPhase.Installing : NasPackageInstallPhase.Downloading; job.MessageKey = null; return job.Progress; }
                    if (PackageBoolean(status, "success") is not { } succeeded) throw InvalidNasServiceSettings();
                    if (job.CancelRequested)
                    {
                        if (succeeded)
                        {
                            job.Checked = await DownloadedPackageAsync(job, token).ConfigureAwait(false); job.TaskId = null;
                            await CleanOwnedPackageAsync(job, token).ConfigureAwait(false);
                        }
                        else if (job.CancelAccepted) await CancelledPackageJobAsync(job).ConfigureAwait(false);
                        else PackageJobUnknown(job);
                        return job.Progress;
                    }
                    if (!succeeded) { await RejectPackageJobAsync(job, MutationErrorCategory.Server).ConfigureAwait(false); return job.Progress; }
                    job.TaskId = null;
                    if (job.FinalSubmitted)
                    { entry.Package!.Items[job.Index].CompletedReceipt = true; await SaveNasManagementAsync(entry).ConfigureAwait(false); }
                    else job.Checked = await DownloadedPackageAsync(job, token).ConfigureAwait(false);
                }
                if (!job.FinalSubmitted)
                {
                    if (job.Checked is null) { PackageJobUnknown(job); return job.Progress; }
                    try
                    {
                        job.Configuration = await PackageConfigurationAsync(job.Checked, job.Current.Entry, token).ConfigureAwait(false);
                        job.Phase = NasPackageInstallPhase.NeedsOptions; job.MessageKey = null; return job.Progress;
                    }
                    catch (NasPackageCenterException error) when (error.ResourceKey is "NasPackageCenterSignatureFailed" or "NasPackageCenterCustomOptions")
                    {
                        job.MessageKey = error.ResourceKey;
                        await CleanOwnedPackageAsync(job, token).ConfigureAwait(false);
                        if (job.Phase == NasPackageInstallPhase.Cancelled) { job.Phase = NasPackageInstallPhase.Failed; entry.Package!.Stage = NasPackageStepStage.Rejected; await SaveNasManagementAsync(entry).ConfigureAwait(false); }
                        return job.Progress;
                    }
                }
                var installed = await LoadPackagesAsync(token).ConfigureAwait(false);
                var receipt = entry.Package!.Items[job.Index]; var current = installed.FirstOrDefault(item => item.Id == job.Current.Entry.PackageId);
                if (!receipt.Accepted || receipt.SameVersion && !receipt.CompletedReceipt || current is null || current.Version != job.Current.Entry.Version || !(current.IsRunning || current.IsStopped))
                { PackageJobUnknown(job); return job.Progress; }
                receipt.Stage = NasPackageStepStage.Confirmed; job.Index++; entry.Package.CurrentIndex = job.Index;
                if (job.Index == job.Candidates.Length)
                { entry.Package.Stage = NasPackageStepStage.Confirmed; entry.Package.Accepted = true; job.Phase = NasPackageInstallPhase.Completed; job.MessageKey = null; }
                await SaveNasManagementAsync(entry).ConfigureAwait(false);
                if (job.Index < job.Candidates.Length)
                {
                    job.FinalSubmitted = false; job.Checked = null; job.Configuration = null; job.Fraction = null;
                    if (job.Paused || job.OwnerLifetime.IsCancellationRequested || _packageTrackingLifetime.IsCancellationRequested) { job.Phase = NasPackageInstallPhase.Interrupted; job.MessageKey = "NasPackageCenterInterrupted"; }
                    else await SubmitCurrentPackageAsync(job, token).ConfigureAwait(false);
                }
            }
            catch (Exception error)
            {
                PackageJobUnknown(job); entry.Package!.Error = PackageFailureCategory(error);
                if (NasManagementRecords.Failed) throw;
                await SaveNasManagementAsync(entry).ConfigureAwait(false);
            }
            return job.Progress;
        }
        finally { NasManagementRecords.Gate.Release(); if (monitoring is not null) StartPackageMonitor(monitoring); }
    }
    private Task<JsonObject> DownloadedPackageAsync(PackageInstallJob job, CancellationToken token) =>
        PackageCallAsync("SYNO.Core.Package.Installation.Download", 1, "check", new() { ["taskid"] = "@SYNOPKG_DOWNLOAD_" + job.Current.Entry.PackageId }, token);
    private static void PackageJobUnknown(PackageInstallJob job)
    { job.Phase = NasPackageInstallPhase.Unknown; job.MessageKey = "NasPackageCenterUnknown"; }
    private async Task RejectPackageJobAsync(PackageInstallJob job, MutationErrorCategory error)
    {
        job.Phase = NasPackageInstallPhase.Failed; job.MessageKey ??= "NasPackageCenterFailed";
        var record = job.Entry.Package!; record.Stage = NasPackageStepStage.Rejected; record.Error = error;
        if (job.FinalSubmitted) record.Items[job.Index].Stage = NasPackageStepStage.Rejected;
        await SaveNasManagementAsync(job.Entry).ConfigureAwait(false);
    }
    private static MutationErrorCategory PackageFailureCategory(Exception error) => error switch
    { NasPackageCenterException package => package.Category, DsmException dsm => ServiceErrorCategory(dsm), _ => MutationErrorCategory.Network };
    private void StartPackageMonitor(PackageInstallJob job)
    {
        if (!PackageBackgroundTrackingEnabled || !job.Progress.IsActive || _packageTrackingLifetime.IsCancellationRequested || Interlocked.CompareExchange(ref job.MonitorActive, 1, 0) != 0) return;
        _ = Task.Run(async () =>
        {
            try
            {
                while (job.Progress.IsActive && !_packageTrackingLifetime.IsCancellationRequested)
                {
                    await Task.Delay(TimeSpan.FromSeconds(1), _packageTrackingLifetime.Token).ConfigureAwait(false);
                    try { await AdvancePackageInstallationAsync(job.Entry.Id, _packageTrackingLifetime.Token).ConfigureAwait(false); }
                    catch (NasHardwareEditException error) when (error.Category == MutationErrorCategory.Conflict) { }
                }
            }
            catch { /* 原连接结束后保留记录，不把关闭窗口或断线当作安装取消。 */ }
            finally { Interlocked.Exchange(ref job.MonitorActive, 0); }
        });
    }
    public void StopPackageInstallationTracking() => _packageTrackingLifetime.Cancel();
    public async Task<NasPackageActivity> EndPackageInstallationQueueAsync(Guid id, CancellationToken token = default)
    {
        await EnterNasManagementAsync(token).ConfigureAwait(false);
        try
        {
            var entry = PackageRecordById(id); var record = entry.Package!;
            if (!CanEndPackageQueue(record)) throw PackageError("NasPackageCenterBusy", MutationErrorCategory.Conflict);
            if (NasManagementRecords.PackageJobs.TryGetValue(id, out var job)) { job.Paused = true; job.Phase = NasPackageInstallPhase.Cancelled; }
            foreach (var item in record.Items.Where(item => !item.Submitted)) item.Stage = NasPackageStepStage.Cancelled;
            record.Stage = NasPackageStepStage.Cancelled; await SaveNasManagementAsync(entry).ConfigureAwait(false);
            return PackageActivityInfo(entry);
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
}
