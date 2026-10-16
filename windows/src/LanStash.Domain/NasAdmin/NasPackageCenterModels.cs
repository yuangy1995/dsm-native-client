using System.Text;

namespace LanStash.Domain;

public sealed record NasPackageCategory(string Id, string Name);
public sealed record NasPackageCatalogEntry(string PackageId, string Name, string Version, string Description,
    string ReleaseNotes, string Publisher, IReadOnlyList<string> Categories, bool IsBeta, bool IsOfficial,
    long? SizeBytes, string? InstalledVersion, bool IsUpdateAvailable)
{
    public string Id => PackageId + (IsBeta ? ":beta" : ":stable");
    public bool CanInstall => InstalledVersion is null || IsUpdateAvailable;
}
public sealed record NasPackageCatalog(IReadOnlyList<NasPackageCatalogEntry> Entries,
    IReadOnlyList<NasPackageCategory> Categories, bool CommunityAvailable);
public sealed record NasPackageInstallVolume(string Id, string Name);
public sealed record NasPackageInstallItem(NasPackageCatalogEntry Package, IReadOnlyList<NasPackageInstallVolume> Volumes, string DefaultVolumeId);
public sealed record NasPackageInstallPlan(Guid Id, Guid ProfileId, IReadOnlyList<NasPackageInstallItem> Items, IReadOnlyList<string> AffectedPackages);
public enum NasPackageOptionKind { Description, Text, Password, Toggle, Radio, Choice }
public sealed record NasPackageOptionValue(string? Text = null, bool? Flag = null);
public sealed record NasPackageInstallField(string Id, string Label, NasPackageOptionKind Kind,
    NasPackageOptionValue DefaultValue, IReadOnlyList<NasPackageCategory> Choices, string? Group = null,
    bool Required = false, int? MinimumLength = null, int? MaximumLength = null);
public sealed record NasPackageInstallConfiguration(string PackageName, string Version, string? License,
    IReadOnlyList<NasPackageInstallField> Fields, IReadOnlyList<NasPackageInstallVolume> Volumes,
    string DefaultVolumeId, bool CanStart, bool RequiresRestart)
{
    public bool Accepts(IReadOnlyDictionary<string, NasPackageOptionValue> values)
    {
        if (values.Keys.Any(key => !Fields.Any(field => field.Id == key && field.Kind != NasPackageOptionKind.Description))) return false;
        foreach (var field in Fields.Where(field => field.Kind != NasPackageOptionKind.Description))
        {
            var value = values.GetValueOrDefault(field.Id) ?? field.DefaultValue;
            if (field.Kind is NasPackageOptionKind.Toggle or NasPackageOptionKind.Radio)
            { if (value.Flag is null || value.Text is not null) return false; }
            else
            {
                if (value.Text is not { } text || value.Flag is not null || field.Required && text.Length == 0 ||
                    field.MinimumLength is { } min && text.EnumerateRunes().Count() < min ||
                    field.MaximumLength is { } max && text.EnumerateRunes().Count() > max ||
                    field.Kind == NasPackageOptionKind.Choice && !field.Choices.Any(choice => choice.Id == text)) return false;
            }
        }
        return Fields.Where(field => field.Group is not null).GroupBy(field => field.Group)
            .All(group => group.Count(field => (values.GetValueOrDefault(field.Id) ?? field.DefaultValue).Flag == true) == 1);
    }
}
public enum NasPackageInstallPhase { Uploading, Downloading, Installing, NeedsOptions, Completed, Failed, Unknown, Cancelled, Interrupted }
public enum NasPackageActivityKind { Control, Settings, SaveSource, RemoveSource, Installation, Upload }
public enum NasPackageStepStage { NotStarted, Unknown, Confirmed, Rejected, Cancelled }
public sealed record NasPackageActivity(Guid Id, NasPackageActivityKind Kind, DateTimeOffset CreatedAt,
    NasPackageStepStage Stage, bool Submitted, bool Accepted, int CompletedCount, int TotalCount,
    MutationErrorCategory? Error = null, bool CanEndQueue = false)
{
    public bool IsPending => Stage is NasPackageStepStage.Unknown or NasPackageStepStage.NotStarted;
}
public sealed record NasPackageInstallProgress(Guid Id, string PackageName, int CompletedCount, int TotalCount,
    NasPackageInstallPhase Phase, double? Fraction = null, NasPackageInstallConfiguration? Configuration = null,
    bool CanCancel = false, string? MessageKey = null)
{
    public bool IsActive => Phase is NasPackageInstallPhase.Uploading or NasPackageInstallPhase.Downloading or NasPackageInstallPhase.Installing;
}
public sealed record NasPackageInstallRequest(Guid ProfileId, Guid PlanId, Guid RequestId,
    IReadOnlyDictionary<string, string> Volumes, bool StartAfterInstall, bool RiskConfirmed);
public sealed record NasPackageConfigureRequest(Guid ProfileId, Guid ActivityId, string VolumeId,
    bool StartAfterInstall, bool LicenseAccepted, IReadOnlyDictionary<string, NasPackageOptionValue> Values, bool RiskConfirmed);
public enum NasPackageUpdatePolicy { Manual, Important, Latest, Selected }
public enum NasPackageSingleUpdatePolicy { Manual, Important, Latest }
public sealed record NasPackageUpdatePreference(string Id, string Name, bool CanUpdateAutomatically, NasPackageSingleUpdatePolicy? Policy);
public sealed record NasPackageCenterSettings(bool BetaEnabled, bool EmailNotifications, bool DesktopNotifications,
    NasPackageUpdatePolicy UpdatePolicy, string DefaultVolumeId, IReadOnlyList<NasPackageInstallVolume> Volumes,
    IReadOnlyList<NasPackageUpdatePreference> PackageUpdates);
public sealed record NasPackageSettingsRequest(Guid ProfileId, Guid RequestId, NasPackageCenterSettings Baseline,
    NasPackageCenterSettings Desired, bool RiskConfirmed);
public sealed record NasPackageSource(string Name, string Url)
{
    public NasPackageSource? Normalize()
    {
        var name = Name.Trim(); var address = Url.Trim();
        return name.Length > 0 && !name.Any(char.IsControl) && Uri.TryCreate(address, UriKind.Absolute, out var uri) &&
            uri.Scheme is "http" or "https" && uri.Host.Length > 0 && uri.UserInfo.Length == 0 && uri.Fragment.Length == 0
            ? new(name, address) : null;
    }
}
public sealed record NasPackageSourceRequest(Guid ProfileId, Guid RequestId, NasPackageSource? Baseline,
    NasPackageSource? Desired, bool RiskConfirmed);
public sealed record NasPackageCenterAvailability(bool CanBrowse, bool CanInstall, bool CanUpload,
    bool CanSaveSettings, bool CanManageSources, bool CanEnableAutomaticUpdates = false, bool CanTrustSources = false);
public sealed class NasPackageCenterException(string resourceKey, MutationErrorCategory category = MutationErrorCategory.Validation)
    : Exception(resourceKey)
{
    public string ResourceKey { get; } = resourceKey;
    public MutationErrorCategory Category { get; } = category;
}

// Windows 套件中心只增加现有 Repository 能力，旧实现默认不支持。
public partial interface INasSettingsRepository
{
    Uri? PackageCenterWebUri => null;
    NasPackageCenterAvailability PackageCenterAvailability => new(false, false, false, false, false);
    Task<NasPackageCatalog> LoadPackageCatalogAsync(CancellationToken token = default) => Task.FromException<NasPackageCatalog>(new NotSupportedException());
    Task<NasPackageInstallPlan> PreparePackageInstallationAsync(IReadOnlyList<string> catalogIds, CancellationToken token = default) => Task.FromException<NasPackageInstallPlan>(new NotSupportedException());
    Task<NasPackageInstallProgress> StartPackageInstallationAsync(NasPackageInstallRequest request, CancellationToken token = default) => Task.FromException<NasPackageInstallProgress>(new NotSupportedException());
    Task<NasPackageInstallProgress> AdvancePackageInstallationAsync(Guid id, CancellationToken token = default) => Task.FromException<NasPackageInstallProgress>(new NotSupportedException());
    Task<NasPackageInstallProgress?> GetPackageInstallationAsync(CancellationToken token = default) => Task.FromResult<NasPackageInstallProgress?>(null);
    Task<NasPackageInstallProgress> ConfigurePackageInstallationAsync(NasPackageConfigureRequest request, CancellationToken token = default) => Task.FromException<NasPackageInstallProgress>(new NotSupportedException());
    Task<NasPackageInstallProgress> CancelPackageInstallationAsync(Guid id, CancellationToken token = default) => Task.FromException<NasPackageInstallProgress>(new NotSupportedException());
    void StopPackageInstallationTracking() { }
    Task<NasPackageActivity> EndPackageInstallationQueueAsync(Guid id, CancellationToken token = default) => Task.FromException<NasPackageActivity>(new NotSupportedException());
    Task<NasPackageInstallProgress> UploadPackageAsync(Guid requestId, string filePath, CancellationToken token = default) => Task.FromException<NasPackageInstallProgress>(new NotSupportedException());
    Task<NasPackageCenterSettings> LoadPackageCenterSettingsAsync(CancellationToken token = default) => Task.FromException<NasPackageCenterSettings>(new NotSupportedException());
    Task<NasPackageActivity> SavePackageCenterSettingsAsync(NasPackageSettingsRequest request, CancellationToken token = default) => Task.FromException<NasPackageActivity>(new NotSupportedException());
    Task<IReadOnlyList<NasPackageSource>> LoadPackageSourcesAsync(CancellationToken token = default) => Task.FromException<IReadOnlyList<NasPackageSource>>(new NotSupportedException());
    Task<NasPackageActivity> SavePackageSourceAsync(NasPackageSourceRequest request, CancellationToken token = default) => Task.FromException<NasPackageActivity>(new NotSupportedException());
    Task<IReadOnlyList<NasPackageActivity>> LoadPackageActivitiesAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<NasPackageActivity>>([]);
    Task<NasPackageActivity> ReviewPackageActivityAsync(Guid id, CancellationToken token = default) => Task.FromException<NasPackageActivity>(new NotSupportedException());
}
