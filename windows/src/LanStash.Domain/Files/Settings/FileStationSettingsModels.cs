using System.Collections.Immutable;

namespace LanStash.Domain;

public enum FileStationAccess { Administrators, Everyone, Selected }
public enum FileStationBandwidthPolicy { Disabled, Enabled, Scheduled, NotConfigured }
public enum FileStationBandwidthOwner { LocalUser, LocalGroup, LdapUser, LdapGroup, DomainUser, DomainGroup }
public enum FileStationDirectoryKind { Local, Ldap, Domain }
public sealed record FileStationAccountId(FileSharePrincipalKind Kind, int Value);
public sealed record FileStationPolicyAccount(FileStationAccountId Id, string Name, bool IsAdministrator);
public sealed record FileStationDirectory(FileStationDirectoryKind Kind, string Value = "", string Name = "")
{
    public override string ToString() => nameof(FileStationDirectory);
}
public sealed record FileStationDirectories(IReadOnlyList<FileStationDirectory> Items, bool HasUnavailableSources);

public abstract record FileStationSetting(Guid ProfileId)
{
    public abstract string Target { get; }
    public virtual bool IsValid => ProfileId != Guid.Empty;
    public virtual bool Equivalent(FileStationSetting other) => Equals(other);
    public sealed override string ToString() => GetType().Name;
}
public sealed record FileStationGeneralSettings(Guid ProfileId, bool RecordsTransfers, bool UsesDefaultPermissions,
    bool ShowsAccounts, FileStationAccess Sharing, FileStationAccess FileRequests, FileStationAccess RemoteMounts,
    FileStationAccess IsoMounts, ImmutableArray<FileStationAccountId> SharingAccounts, ImmutableArray<FileStationAccountId> RequestAccounts,
    int DefaultLinkLimit, FileStationBandwidthPolicy Bandwidth, string Schedule, bool? UsesCustomSharingPage) : FileStationSetting(ProfileId)
{
    public override string Target => "general";
    public override bool IsValid => base.IsValid && Enum.IsDefined(Sharing) && Enum.IsDefined(FileRequests) &&
        RemoteMounts is FileStationAccess.Administrators or FileStationAccess.Everyone && IsoMounts is FileStationAccess.Administrators or FileStationAccess.Everyone &&
        DefaultLinkLimit is >= 0 and <= 999999999 && Bandwidth is FileStationBandwidthPolicy.Disabled or FileStationBandwidthPolicy.Enabled or FileStationBandwidthPolicy.Scheduled &&
        FileStationSchedule.ValidOrEmpty(Schedule, false, Bandwidth) && ValidIds(SharingAccounts) && ValidIds(RequestAccounts);
    public override bool Equivalent(FileStationSetting other) => other is FileStationGeneralSettings value &&
        this with { SharingAccounts = value.SharingAccounts, RequestAccounts = value.RequestAccounts } == value &&
        SharingAccounts.ToHashSet().SetEquals(value.SharingAccounts) && RequestAccounts.ToHashSet().SetEquals(value.RequestAccounts);
    private static bool ValidIds(ImmutableArray<FileStationAccountId> ids) => !ids.IsDefault && ids.All(id => id.Value >= 0 && Enum.IsDefined(id.Kind)) && ids.Distinct().Count() == ids.Length;
}
public sealed record FileStationMountAccess(Guid ProfileId, FileStationAccess Access) : FileStationSetting(ProfileId)
{
    public override string Target => "mount-access";
    public override bool IsValid => base.IsValid && Enum.IsDefined(Access);
}
public sealed record FileStationMountAccount(Guid ProfileId, FileStationDirectory Source, FileStationAccountId Id,
    string Name, bool Enabled, bool CanModify) : FileStationSetting(ProfileId)
{
    public override string Target => $"mount-account:{Source.Kind}:{Source.Value}:{Id.Kind}:{Id.Value}";
    public override bool IsValid => base.IsValid && Id.Value >= 0 && Enum.IsDefined(Id.Kind) && !string.IsNullOrEmpty(Name) &&
        Enum.IsDefined(Source.Kind) && (Source.Kind != FileStationDirectoryKind.Domain || !string.IsNullOrEmpty(Source.Value));
}
public sealed record FileStationBandwidth(Guid ProfileId, string Name, FileStationBandwidthOwner Owner, FileStationBandwidthPolicy Policy,
    string Schedule, int UploadLimit, int DownloadLimit, int AlternateUploadLimit, int AlternateDownloadLimit) : FileStationSetting(ProfileId)
{
    public override string Target => $"bandwidth:{Owner}:{Name}";
    public override bool IsValid => base.IsValid && !string.IsNullOrEmpty(Name) && Enum.IsDefined(Owner) && Enum.IsDefined(Policy) &&
        FileStationSchedule.ValidOrEmpty(Schedule, true, Policy) && new[] { UploadLimit, DownloadLimit, AlternateUploadLimit, AlternateDownloadLimit }.All(v => v == 0 || v is >= 10 and <= 999999999);
}
public static class FileStationSchedule
{
    // 与官方时间表一致：星期日开始，每日 0 至 23 时；账号允许第二组限速。
    public static bool IsValid(string value, bool perAccount) => value.Length == 168 && value.All(c => c >= '0' && c <= (perAccount ? '2' : '1'));
    public static bool ValidOrEmpty(string value, bool perAccount, FileStationBandwidthPolicy policy) =>
        IsValid(value, perAccount) || value.Length == 0 && policy != FileStationBandwidthPolicy.Scheduled;
    public static string Set(string value, int day, int hour, int mode, bool perAccount)
    {
        if (!IsValid(value, perAccount) || day is < 0 or > 6 || hour is < 0 or > 23 || mode < 0 || mode > (perAccount ? 2 : 1)) throw new ArgumentException("file.settings.schedule");
        var chars = value.ToCharArray(); chars[day * 24 + hour] = (char)('0' + mode); return new(chars);
    }
}
public sealed record FileStationSettingsChange(Guid RequestId, FileStationSetting Baseline, FileStationSetting Desired, bool Confirmed)
{
    public bool IsValid => RequestId != Guid.Empty && Confirmed && Baseline.IsValid && Desired.IsValid &&
        Baseline.GetType() == Desired.GetType() && Baseline.ProfileId == Desired.ProfileId && Baseline.Target == Desired.Target && !Baseline.Equivalent(Desired);
    public override string ToString() => nameof(FileStationSettingsChange);
}
public sealed record FileStationSettingsProgress(FileStationSettingsChange Change, MutationResult Outcome)
{
    public override string ToString() => nameof(FileStationSettingsProgress);
}
public interface IFileStationSettingsRepository
{
    Guid ProfileId { get; }
    Task<bool> CanWriteFileStationSettingsAsync(CancellationToken token = default);
    Task<FileStationGeneralSettings> LoadFileStationSettingsAsync(CancellationToken token = default);
    Task<IReadOnlyList<FileStationPolicyAccount>> ListFileStationPolicyAccountsAsync(FileSharePrincipalKind kind, CancellationToken token = default);
    Task<FileStationMountAccess> LoadFileStationMountAccessAsync(CancellationToken token = default);
    Task<FileStationDirectories> LoadFileStationDirectoriesAsync(CancellationToken token = default);
    Task<IReadOnlyList<FileStationMountAccount>> ListFileStationMountAccountsAsync(FileStationDirectory source, FileSharePrincipalKind kind, CancellationToken token = default);
    Task<IReadOnlyList<FileStationBandwidth>> ListFileStationBandwidthAsync(FileStationBandwidthOwner owner, CancellationToken token = default);
    Task<FileStationSettingsProgress> SaveFileStationSettingAsync(FileStationSettingsChange change, CancellationToken token = default);
    Task<IReadOnlyList<FileStationSettingsProgress>> GetFileStationSettingsOperationsAsync(CancellationToken token = default);
    Task<FileStationSettingsProgress?> ReviewFileStationSettingAsync(Guid requestId, CancellationToken token = default);
}
