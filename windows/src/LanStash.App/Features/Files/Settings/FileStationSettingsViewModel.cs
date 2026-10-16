using System.Collections.Immutable;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Settings;

public enum FileStationSettingsSection { General, MountAccess, MountAccounts, Bandwidth, Theme }
public sealed partial class FileStationSettingsViewModel(IFileStationSettingsRepository repository) : ObservableObject, IDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private bool _disposed;
    public FileStationSettingsSection Section { get; private set; }
    public FileStationSetting? Baseline { get; private set; }
    public FileStationSetting? Draft { get; private set; }
    public FileStationSettingsProgress? Progress { get; private set; }
    public IReadOnlyList<FileStationSettingsProgress> Pending { get; private set; } = [];
    public IReadOnlyList<FileStationSetting> Items { get; private set; } = [];
    public IReadOnlyList<FileStationPolicyAccount> PolicyAccounts { get; private set; } = [];
    public IReadOnlyList<FileStationDirectory> Directories { get; private set; } = [];
    public FileStationDirectory Source { get; private set; } = new(FileStationDirectoryKind.Local);
    public FileSharePrincipalKind AccountKind { get; private set; }
    public FileStationBandwidthOwner Owner { get; private set; }
    public string Filter { get; private set; } = "";
    public bool IsBusy { get; private set; }
    public bool LoadFailed { get; private set; }
    public bool CanWrite { get; private set; }
    public bool SourcesUnavailable { get; private set; }
    public bool ConfirmedExpansion { get; set; }
    public bool IsPending => Baseline is { } current && Pending.Any(p => p.Change.Baseline.Target == current.Target) || Progress?.Outcome.RequiresRefresh == true;
    public bool CanEdit => !_disposed && !IsBusy && !LoadFailed && CanWrite && !IsPending && Baseline is not null;
    public bool CanSave => CanEdit && !ThemePickerOpen && Draft is { IsValid: true } desired && Baseline is { } baseline && !baseline.Equivalent(desired) &&
        (baseline is not FileStationTheme old || desired is FileStationTheme next && (old.CustomLogo || !next.CustomLogo || next.LogoImage is not null) && (old.CustomBackground || !next.CustomBackground || next.BackgroundImage is not null)) &&
        desired is not FileStationBandwidth { Policy: FileStationBandwidthPolicy.NotConfigured } && desired is not FileStationMountAccount { CanModify: false } && (!NeedsExpansionConfirmation || ConfirmedExpansion);
    public bool NeedsExpansionConfirmation => (Baseline, Draft) switch
    {
        (FileStationGeneralSettings before, FileStationGeneralSettings after) => !before.ShowsAccounts && after.ShowsAccounts ||
            Expands(before.Sharing, after.Sharing) || Expands(before.FileRequests, after.FileRequests) || Expands(before.RemoteMounts, after.RemoteMounts) || Expands(before.IsoMounts, after.IsoMounts) ||
            after.SharingAccounts.Except(before.SharingAccounts).Any() || after.RequestAccounts.Except(before.RequestAccounts).Any(),
        (FileStationMountAccess before, FileStationMountAccess after) => Expands(before.Access, after.Access),
        (FileStationMountAccount { Enabled: false }, FileStationMountAccount { Enabled: true }) => true,
        _ => false,
    };
    public IReadOnlyList<string> ExpansionMessageKeys
    {
        get
        {
            if (Baseline is FileStationGeneralSettings before && Draft is FileStationGeneralSettings after)
            {
                var keys = new List<string>();
                if (!before.ShowsAccounts && after.ShowsAccounts) keys.Add("FsSettingsRiskAccountNames");
                if (Expands(before.Sharing, after.Sharing) || after.SharingAccounts.Except(before.SharingAccounts).Any()) keys.Add("FsSettingsRiskSharing");
                if (Expands(before.FileRequests, after.FileRequests) || after.RequestAccounts.Except(before.RequestAccounts).Any()) keys.Add("FsSettingsRiskRequests");
                if (Expands(before.RemoteMounts, after.RemoteMounts)) keys.Add("FsSettingsRiskRemote");
                if (Expands(before.IsoMounts, after.IsoMounts)) keys.Add("FsSettingsRiskIso");
                return keys;
            }
            return NeedsExpansionConfirmation ? ["FsSettingsRiskRemote"] : [];
        }
    }
    public IEnumerable<FileStationSetting> VisibleItems => Items.Where(v => ItemName(v).Contains(Filter, StringComparison.CurrentCultureIgnoreCase));
    public string? MessageKey => LoadFailed ? "FsSettingsLoadFailed" : Progress?.Outcome.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => "FsSettingsSaved",
        MutationResultStatus.SubmittedButUnverified => "FsSettingsPending",
        MutationResultStatus.PermissionDenied => "FsSettingsDenied",
        MutationResultStatus.Unsupported => "FsSettingsUnsupported",
        MutationResultStatus.ConfirmedFailure => Progress.Outcome.ErrorCategory == MutationErrorCategory.Conflict ? "FsSettingsChanged" : "FsSettingsSaveFailed",
        MutationResultStatus.CancelledBeforeSubmission => "FsSettingsNotSent",
        _ => !CanWrite && !IsBusy ? "FsSettingsReadOnly" : null,
    };
    public async Task SelectSectionAsync(FileStationSettingsSection section)
    { if (_disposed || IsBusy || !Enum.IsDefined(section)) return; CloseThemePicker(); Section = section; Filter = ""; Baseline = Draft = null; Progress = null; await LoadAsync(); }
    public async Task SetDirectoryAsync(FileStationDirectory source, FileSharePrincipalKind kind)
    { if (_disposed || IsBusy || !Directories.Contains(source)) return; Source = source; AccountKind = kind; Baseline = Draft = null; Progress = null; await LoadAsync(); }
    public async Task SetOwnerAsync(FileStationBandwidthOwner owner)
    { if (_disposed || IsBusy) return; Owner = owner; Baseline = Draft = null; Progress = null; await LoadAsync(); }
    public void SetFilter(string value) { if (_disposed) return; Filter = value; RaisePropertyChanged(nameof(Filter)); }
    public void Select(FileStationSetting item)
    {
        if (_disposed || IsBusy || !Items.Contains(item)) return;
        Baseline = item; Draft = item; Progress = Pending.FirstOrDefault(p => p.Change.Baseline.Target == item.Target);
        if (Progress is not null) { Baseline = Progress.Change.Baseline; Draft = Progress.Change.Desired; }
        ConfirmedExpansion = false; Notify();
    }
    public void UpdateDraft(FileStationSetting draft)
    {
        if (!CanEdit || Baseline is null || draft.ProfileId != Baseline.ProfileId || draft.Target != Baseline.Target || draft.GetType() != Baseline.GetType()) return;
        Draft = draft; Progress = null; ConfirmedExpansion = false; RaisePropertyChanged(nameof(Draft));
    }
    public void TogglePolicyAccount(FileStationAccountId id, bool sharing, bool enabled)
    {
        if (Draft is not FileStationGeneralSettings current || !PolicyAccounts.Any(a => a.Id == id && !a.IsAdministrator)) return;
        var original = sharing ? current.SharingAccounts : current.RequestAccounts;
        var next = enabled ? original.Add(id).Distinct().ToImmutableArray() : original.Where(v => v != id).ToImmutableArray();
        UpdateDraft(sharing ? current with { SharingAccounts = next } : current with { RequestAccounts = next });
    }
    public async Task LoadAsync()
    {
        if (_disposed || IsBusy) return; IsBusy = true; LoadFailed = false; Notify();
        try
        {
            var operations = await repository.GetFileStationSettingsOperationsAsync(_lifetime.Token);
            foreach (var operation in operations) await repository.ReviewFileStationSettingAsync(operation.Change.RequestId, _lifetime.Token);
            var pending = await repository.GetFileStationSettingsOperationsAsync(_lifetime.Token);
            bool writable; try { writable = await repository.CanWriteFileStationSettingsAsync(_lifetime.Token); } catch { writable = false; }
            FileStationSetting? loaded = null; IReadOnlyList<FileStationSetting> items = []; IReadOnlyList<FileStationPolicyAccount> accounts = [];
            var directories = new FileStationDirectories(Directories, SourcesUnavailable);
            switch (Section)
            {
                case FileStationSettingsSection.General:
                    loaded = await repository.LoadFileStationSettingsAsync(_lifetime.Token);
                    // 名单单独失败时禁止编辑具名授权，不阻断其他设置读取。
                    try { accounts = [.. await repository.ListFileStationPolicyAccountsAsync(FileSharePrincipalKind.User, _lifetime.Token), .. await repository.ListFileStationPolicyAccountsAsync(FileSharePrincipalKind.Group, _lifetime.Token)]; }
                    catch (OperationCanceledException) { throw; } catch { accounts = []; }
                    break;
                case FileStationSettingsSection.MountAccess: loaded = await repository.LoadFileStationMountAccessAsync(_lifetime.Token); break;
                case FileStationSettingsSection.MountAccounts:
                    directories = await repository.LoadFileStationDirectoriesAsync(_lifetime.Token);
                    if (!directories.Items.Contains(Source)) throw new InvalidDataException("file.settings.source.changed");
                    items = await repository.ListFileStationMountAccountsAsync(Source, AccountKind, _lifetime.Token); break;
                case FileStationSettingsSection.Bandwidth: items = await repository.ListFileStationBandwidthAsync(Owner, _lifetime.Token); break;
                case FileStationSettingsSection.Theme:
                    loaded = repository is IFileStationThemeRepository theme ? await theme.LoadFileStationThemeAsync(_lifetime.Token) : throw new NotSupportedException(); break;
            }
            if (_disposed) return;
            CanWrite = writable; Pending = pending; PolicyAccounts = accounts; Directories = directories.Items; SourcesUnavailable = directories.HasUnavailableSources;
            Items = items; Baseline = Draft = loaded; Progress = null; ConfirmedExpansion = false;
            if (loaded is not null && pending.FirstOrDefault(p => p.Change.Baseline.Target == loaded.Target) is { } targetOperation) { Progress = targetOperation; Baseline = targetOperation.Change.Baseline; Draft = targetOperation.Change.Desired; }
        }
        catch { if (!_disposed) { LoadFailed = true; Baseline = Draft = null; Items = []; CanWrite = false; } }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
    }
    public async Task SaveAsync()
    {
        if (!CanSave || Baseline is null || Draft is null) return;
        var change = new FileStationSettingsChange(Guid.NewGuid(), Baseline, Draft, true); IsBusy = true; Notify();
        try
        {
            var result = await repository.SaveFileStationSettingAsync(change, _lifetime.Token);
            var pending = await repository.GetFileStationSettingsOperationsAsync(_lifetime.Token);
            if (_disposed) return; Progress = result; Pending = pending;
            if (result.Outcome.Status == MutationResultStatus.ConfirmedSuccess)
            { Baseline = Draft = result.Change.Desired; Items = Items.Select(v => v.Target == Baseline.Target ? Baseline : v).ToArray(); }
        }
        catch { if (!_disposed) { LoadFailed = true; CanWrite = false; } }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
    }
    private static bool Expands(FileStationAccess old, FileStationAccess next) => old != next && next != FileStationAccess.Administrators && (old == FileStationAccess.Administrators || next == FileStationAccess.Everyone);
    public static string ItemName(FileStationSetting item) => item switch { FileStationMountAccount a => a.Name, FileStationBandwidth b => b.Name, _ => "" };
    private void Notify() => RaisePropertyChanged("State");
    public void Dispose() { if (_disposed) return; _disposed = true; _lifetime.Cancel(); _lifetime.Dispose(); Baseline = Draft = null; Items = []; PolicyAccounts = []; ThemeImages = []; ThemeFiles = []; ThemePreview = null; ThemeSelection = null; }
}
