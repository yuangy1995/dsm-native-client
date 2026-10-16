using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool AllowsPackageRemoval { get; init; }
    public NasPackageControlAvailability PackageControlAvailability => new(
        NasSettingsWriteAvailability.CanPackageControl && SecurityCapability("SYNO.Core.Package", 1) is not null && SecurityCapability("SYNO.Core.Package.Control", 1) is not null,
        AllowsPackageRemoval && NasSettingsWriteAvailability.CanPackageControl && SecurityCapability("SYNO.Core.Package", 1) is not null && SecurityCapability("SYNO.Core.Package.Uninstallation", 1) is not null);

    public async Task<IReadOnlyList<NasPackageRecoveryInfo>> GetPackageRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        await EnterNasManagementAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return OwnedPackageRecords.Where(entry => entry.Package!.Kind == NasPackageActivityKind.Control && entry.Package.Stage == NasPackageStepStage.Unknown)
                .Select(entry => new NasPackageRecoveryInfo(
                    NasManagementRecords.PackageTargets.TryGetValue(entry.Id, out var target) ? target.Id : "operation:" + entry.Id,
                    NasManagementRecords.PackageTargets.TryGetValue(entry.Id, out target) ? target.Name : "", entry.Package!.Action!.Value)
                    { RequestId = entry.Id }).ToArray();
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    public Task<MutationResult> ControlPackageAsync(NasPackageMutationRequest request, CancellationToken cancellationToken = default) =>
        (request.Action == NasPackageAction.Uninstall ? PackageControlAvailability.CanUninstall : PackageControlAvailability.CanStartStop)
            ? ExecutePackageMutationAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("controlPackage"));

    internal async Task<MutationResult> ExecutePackageMutationAsync(NasPackageMutationRequest request, CancellationToken token = default,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, _packageTrackingLifetime.Token); token = lifetime.Token;
        var operation = PackageOperationName(request?.Action ?? NasPackageAction.Start);
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baseline is null || !StablePackageId(request.Baseline.Id) || !Enum.IsDefined(request.Action) ||
            !request.RiskConfirmed || request.RequestId == Guid.Empty || request.ProfileId != _profile.Id ||
            _profile.Id != _session.ProfileId || string.IsNullOrWhiteSpace(_session.Sid) || !PackageActionAllowed(request.Baseline, request.Action))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        if (SecurityCapability("SYNO.Core.Package", 2) is null || SecurityCapability("SYNO.Core.Package", 1) is null ||
            SecurityCapability(request.Action == NasPackageAction.Uninstall ? "SYNO.Core.Package.Uninstallation" : "SYNO.Core.Package.Control", 1) is null)
            return UnsupportedResult(operation);
        request = request with { Baseline = request.Baseline with
        {
            AvailableOperations = request.Baseline.AvailableOperations?.ToArray(), DesktopApps = request.Baseline.DesktopApps?.ToArray(),
        } };
        var signature = ServiceHash(JsonSerializer.Serialize(new { request.Action, Baseline = PackageSnapshotSignature(request.Baseline) }));
        try { await EnterNasManagementAsync(token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        catch (NasHardwareEditException error) { return ServicePreflightFailure(operation, error.Category, true); }
        catch { return ServicePreflightFailure(operation, MutationErrorCategory.Unknown); }
        try
        {
            NasManagementRecord? entry;
            try { entry = ExistingPackageRequest(request.RequestId, signature); }
            catch (NasPackageCenterException error) { return ServicePreflightFailure(operation, error.Category, true); }
            if (entry is not null)
                return entry.Package!.Stage == NasPackageStepStage.Unknown
                    ? await ReconcilePackageAsync(entry, 1, token, false, delay ?? Task.Delay).ConfigureAwait(false) : PackageControlResult(entry);
            try
            {
                await RequirePackagePermissionAsync(token).ConfigureAwait(false);
                var current = (await LoadPackagesAsync(token).ConfigureAwait(false)).FirstOrDefault(item => item.Id == request.Baseline.Id);
                if (current is null || !PackageActionAllowed(current, request.Action) || PackageSnapshotSignature(current) != PackageSnapshotSignature(request.Baseline))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                await PackageCallAsync("SYNO.Core.Package", 1, "feasibility_check", new()
                {
                    ["type"] = request.Action switch { NasPackageAction.Start => "start_check", NasPackageAction.Stop => "stop_check", _ => "uninstall_check" },
                    ["packages"] = new[] { current.Id },
                }, token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (NasPackageCenterException error) { return ServicePreflightFailure(operation, error.Category); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }

            entry = NewPackageRecord(request.RequestId, signature, NasPackageActivityKind.Control,
                ServiceHash(request.Baseline.Id), PackageInstallationIdentity(request.Baseline));
            entry.Package!.Action = request.Action;
            NasManagementRecords.PackageTargets[entry.Id] = (request.Baseline.Id, request.Baseline.Name);
            var parameters = new Dictionary<string, object> { ["id"] = request.Baseline.Id };
            if (request.Action != NasPackageAction.Stop) parameters["dsm_apps"] = request.Baseline.DesktopApps!;
            try
            {
                await SubmitPackageCommandAsync(entry, PackageSubmissionKind.Control,
                    request.Action == NasPackageAction.Uninstall ? "SYNO.Core.Package.Uninstallation" : "SYNO.Core.Package.Control", 1,
                    request.Action.ToString().ToLowerInvariant(), parameters, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!entry.Package.Submitted) { return CancelledBeforeSubmissionResult(operation); }
            catch (NasPackageCenterException error) when (!entry.Package.Submitted) { return ServicePreflightFailure(operation, error.Category); }
            catch { return PackageControlResult(entry); }
            return await ReconcilePackageAsync(entry, request.Action == NasPackageAction.Uninstall ? 1 : entry.Package.Accepted ? 10 : 3,
                token, true, delay ?? Task.Delay).ConfigureAwait(false);
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    public async Task<MutationResult?> ReviewPackageAsync(string packageId, CancellationToken cancellationToken = default)
    {
        if (!StablePackageId(packageId) || _profile.Id != _session.ProfileId) return ServicePreflightFailure("controlPackage", MutationErrorCategory.Validation);
        try { await EnterNasManagementAsync(cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("controlPackage"); }
        catch (NasHardwareEditException error) { return ServicePreflightFailure("controlPackage", error.Category, true); }
        try
        {
            var record = OwnedPackageRecords.FirstOrDefault(entry => entry.Package!.Kind == NasPackageActivityKind.Control &&
                entry.Package.Stage == NasPackageStepStage.Unknown && (entry.Package.TargetDigest == ServiceHash(packageId) || packageId == "operation:" + entry.Id));
            return record is null ? null : await ReconcilePackageAsync(record, 1, cancellationToken, false, Task.Delay).ConfigureAwait(false);
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    private async Task<MutationResult> ReconcilePackageAsync(NasManagementRecord entry, int attempts, CancellationToken token,
        bool recoverCancellation, Func<TimeSpan, CancellationToken, Task> delay)
    {
        if (entry.Package!.Stage != NasPackageStepStage.Unknown) return PackageControlResult(entry);
        for (var index = 0; index < attempts && !token.IsCancellationRequested; index++)
        {
            try
            {
                if (index > 0) await delay(TimeSpan.FromSeconds(1), token).ConfigureAwait(false);
                await ReviewPackageRecordCoreAsync(entry, token).ConfigureAwait(false);
                if (entry.Package.Stage != NasPackageStepStage.Unknown) break;
            }
            catch (OperationCanceledException) { break; }
            catch (Exception error) when (PackageTrustOrPermissionFailure(error) || NasManagementRecords.Failed) { break; }
            catch { /* 无正文或读取失败不解除原操作保护。 */ }
        }
        if (entry.Package.Stage == NasPackageStepStage.Unknown && token.IsCancellationRequested && recoverCancellation)
        {
            using var recovery = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            try { await ReviewPackageRecordCoreAsync(entry, recovery.Token).ConfigureAwait(false); }
            catch { }
        }
        return PackageControlResult(entry, token.IsCancellationRequested);
    }
    private static MutationResult PackageControlResult(NasManagementRecord entry, bool cancelled = false)
    {
        var value = entry.Package!; var operation = PackageOperationName(value.Action!.Value);
        return value.Stage switch
        {
            NasPackageStepStage.Confirmed => new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(1, 0, 0)),
            NasPackageStepStage.Rejected => new(1, value.Error == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                operation, value.Submitted, false, new(0, 1, 0), value.Error),
            _ => new(1, cancelled ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
                operation, value.Submitted, true, new(0, 0, 1), value.Error ?? MutationErrorCategory.Network, diagnosticTag: "package.result-unverified"),
        };
    }
    private static bool PackageActionAllowed(NasPackageSummary value, NasPackageAction action) => action switch
    { NasPackageAction.Start => value.CanStart, NasPackageAction.Stop => value.CanStop, NasPackageAction.Uninstall => value.CanUninstall, _ => false };
    private static string PackageOperationName(NasPackageAction action) => action switch
    { NasPackageAction.Start => "startPackage", NasPackageAction.Stop => "stopPackage", NasPackageAction.Uninstall => "uninstallPackage", _ => "controlPackage" };
    private static string PackageSnapshotSignature(NasPackageSummary value) => JsonSerializer.Serialize(new
    {
        value.Id, value.Version, value.Status, value.State, value.Startable, value.InstallType, value.InstalledAt, value.UninstallAllowed,
        value.HasOperationObject, Operations = value.AvailableOperations?.Order(StringComparer.Ordinal), Apps = value.DesktopApps?.Order(StringComparer.Ordinal),
    });
}
