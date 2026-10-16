using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasPackageInstallProgress> ConfigurePackageInstallationAsync(NasPackageConfigureRequest request, CancellationToken token = default)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, _packageTrackingLifetime.Token); token = lifetime.Token;
        if (!AllowsPackageInstallation) throw PackageError("NasPackageCenterProtected", MutationErrorCategory.Unsupported);
        if (request.ProfileId != ProfileId || !request.RiskConfirmed) throw PackageError();
        var values = request.Values.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
        await EnterNasManagementAsync(token).ConfigureAwait(false);
        try
        {
            var entry = PackageRecordById(request.ActivityId);
            if (!NasManagementRecords.PackageJobs.TryGetValue(entry.Id, out var job) || job.OwnerLifetime.IsCancellationRequested || job.Phase != NasPackageInstallPhase.NeedsOptions || job.Checked is null ||
                job.Configuration is not { } configuration || job.FinalSubmitted || job.CancelRequested || job.CleanupSubmitted ||
                !configuration.Accepts(values) || configuration.License is not null && !request.LicenseAccepted) throw PackageError("NasPackageCenterOptionsRequired");
            RequirePackageVolume(request.VolumeId, new(job.Current.Entry, configuration.Volumes, configuration.DefaultVolumeId));
            await RequirePackagePermissionAsync(token).ConfigureAwait(false);
            var installed = await LoadPackagesAsync(token).ConfigureAwait(false);
            RequireOriginalPackageInstallation(job, installed);
            await PackageFeasibilityAsync([job.Current.Entry.PackageId], token).ConfigureAwait(false);
            var metadata = PackageMetadataObject(job.Checked);
            var check = new Dictionary<string, object> { ["id"] = job.Current.Entry.PackageId, ["blCheckDep"] = job.Manual };
            foreach (var pair in new[] { ("install_type", "install_type"), ("install_on_cold_storage", "install_on_cold_storage"), ("breakpkgs", "break_pkgs"), ("replacepkgs", "replace_pkgs") })
                if (metadata[pair.Item2] is { } value) check[pair.Item1] = PackageParameter(value);
            var environment = await PackageCallAsync("SYNO.Core.Package.Installation", 2, "check", check, token).ConfigureAwait(false);
            RequirePackageVolume(request.VolumeId, PackageEnvironmentItem(job.Current.Entry, environment, PackageText(metadata, "install_type")));
            var extra = configuration.Fields.Where(field => field.Kind != NasPackageOptionKind.Description).ToDictionary(field => field.Id, field =>
            {
                var value = values.GetValueOrDefault(field.Id) ?? field.DefaultValue;
                return value.Flag is { } flag ? (object)flag : value.Text!;
            }, StringComparer.Ordinal);
            var parameters = new Dictionary<string, object>
            {
                ["volume_path"] = request.VolumeId, ["extra_values"] = JsonSerializer.Serialize(extra), ["type"] = PackageInteger(job.Checked, "type") ?? 0,
                ["check_codesign"] = true, ["force"] = !job.Manual, ["installrunpackage"] = request.StartAfterInstall && configuration.CanStart,
            };
            if (PackageText(metadata, "task_id") is { Length: > 0 } taskId) parameters["task_id"] = taskId;
            else if (PackageText(job.Checked, "filename") is { Length: > 0 } path) parameters["path"] = path;
            else throw InvalidNasServiceSettings();
            var result = await SubmitInstallationRequestAsync(job, PackageSubmissionKind.Install,
                job.Current.Entry.InstalledVersion is null ? "install" : "upgrade", parameters, token).ConfigureAwait(false);
            if (result is not null)
            {
                // 此最终安装是同步命令；保存接受事实后仍读取完整版本与终态。
                entry.Package!.Items[job.Index].CompletedReceipt = true; job.TaskId = null; job.Configuration = null;
                await SaveNasManagementAsync(entry).ConfigureAwait(false); StartPackageMonitor(job);
            }
            return job.Progress;
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    public async Task<NasPackageInstallProgress> CancelPackageInstallationAsync(Guid id, CancellationToken token = default)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, _packageTrackingLifetime.Token); token = lifetime.Token;
        await EnterNasManagementAsync(token).ConfigureAwait(false);
        try
        {
            var entry = PackageRecordById(id);
            if (!NasManagementRecords.PackageJobs.TryGetValue(id, out var job) || job.OwnerLifetime.IsCancellationRequested) throw PackageError("NasPackageCenterInterrupted");
            if (job.CancelRequested || job.CleanupSubmitted) return job.Progress;
            if (!job.Progress.CanCancel || job.FinalSubmitted) throw PackageError("NasPackageCenterCannotCancel");
            await RequirePackagePermissionAsync(token).ConfigureAwait(false);
            if (job.Checked is not null) await CleanOwnedPackageAsync(job, token).ConfigureAwait(false);
            else if (job.TaskId is { } taskId)
            {
                job.CancelRequested = true;
                try
                {
                    await SubmitPackageCommandAsync(entry, PackageSubmissionKind.CancelDownload, "SYNO.Core.Package.Installation", 1,
                        "cancel", new() { ["taskid"] = taskId }, token).ConfigureAwait(false);
                }
                catch
                {
                    if (entry.Package!.SubmissionKind != PackageSubmissionKind.CancelDownload) job.CancelRequested = false;
                    else PackageJobUnknown(job);
                    throw;
                }
                job.CancelAccepted = entry.Package!.Accepted;
                // 接受或拒绝取消均不证明原下载已经结束，仍查询本次任务。
                entry.Package.Stage = NasPackageStepStage.Unknown; job.Phase = NasPackageInstallPhase.Downloading;
                await SaveNasManagementAsync(entry).ConfigureAwait(false); StartPackageMonitor(job);
            }
            return job.Progress;
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    private async Task CleanOwnedPackageAsync(PackageInstallJob job, CancellationToken token)
    {
        if (job.CleanupSubmitted || job.FinalSubmitted || job.Checked is null) { PackageJobUnknown(job); return; }
        await RequirePackagePermissionAsync(token).ConfigureAwait(false);
        job.CancelRequested = true; job.CleanupSubmitted = true; job.Configuration = null;
        try
        {
            if (await CleanOwnedPackageRecordAsync(job.Entry, job.Checked, token).ConfigureAwait(false))
            { job.Checked = null; await CancelledPackageJobAsync(job).ConfigureAwait(false); }
            else PackageJobUnknown(job);
        }
        catch
        {
            if (job.Entry.Package!.SubmissionKind != PackageSubmissionKind.Cleanup)
            {
                job.CleanupSubmitted = job.CancelRequested = false;
                // 未通过清理前权限检查时允许以后再次取消，不重复已发送的清理。
            }
            PackageJobUnknown(job); throw;
        }
    }
    private async Task<bool> CleanOwnedPackageRecordAsync(NasManagementRecord entry, JsonObject checkedPackage, CancellationToken token)
    {
        var metadata = PackageMetadataObject(checkedPackage);
        string method; Dictionary<string, object> parameters;
        if (PackageText(checkedPackage, "filename") is { Length: > 1 } path && path != "/" && !path.Any(char.IsControl))
        { method = "delete"; parameters = new() { ["path"] = path }; }
        else if (PackageText(metadata, "task_id") is { } taskId && StablePackageId(taskId))
        { method = "clean"; parameters = new() { ["task_id"] = taskId }; }
        else throw InvalidNasServiceSettings();
        await SubmitPackageCommandAsync(entry, PackageSubmissionKind.Cleanup, "SYNO.Core.Package.Installation", 1, method, parameters, token).ConfigureAwait(false);
        // 清理是同步命令；没有接受回执时不再次删除，也不重新打开安装表单。
        var completed = entry.Package!.Accepted;
        entry.Package.Stage = completed ? NasPackageStepStage.Cancelled : NasPackageStepStage.Unknown;
        await SaveNasManagementAsync(entry).ConfigureAwait(false); return completed;
    }
    private async Task CancelledPackageJobAsync(PackageInstallJob job)
    {
        job.Phase = NasPackageInstallPhase.Cancelled; job.Configuration = null; job.TaskId = null;
        job.Entry.Package!.Stage = NasPackageStepStage.Cancelled;
        foreach (var item in job.Entry.Package.Items.Where(item => !item.Submitted)) item.Stage = NasPackageStepStage.Cancelled;
        await SaveNasManagementAsync(job.Entry).ConfigureAwait(false);
    }
}
