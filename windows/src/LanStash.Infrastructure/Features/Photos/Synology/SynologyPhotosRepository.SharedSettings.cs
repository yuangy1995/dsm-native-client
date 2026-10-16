using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private async Task<long> RequirePhotoAdministratorAsync(CancellationToken token)
    {
        RequireAccess(); var generation = Volatile.Read(ref _accessGeneration);
        var identity = await CallAsync("UserInfo", 1, "me", cancellationToken: token).ConfigureAwait(false);
        RequireGeneration(generation, token);
        var id = Positive(identity, "id");
        if (!Boolean(identity, "enabled") || KnownPreference(identity, "is_admin") != true || id != _currentUserId)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return id;
    }
    public async Task<SynologyPhotoSharedSettings> SharedSettingsAsync(CancellationToken cancellationToken = default)
    {
        RequireAccess(); var generation = Volatile.Read(ref _accessGeneration);
        var administrator = await RequirePhotoAdministratorAsync(cancellationToken).ConfigureAwait(false);
        var user = await CallAsync("Setting.User", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        var admin = await CallAsync("Setting.Admin", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        var team = await CallAsync("Setting.TeamSpace", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken);
        var role = Text(user, "team_space_permission") switch
        { "none" => SynologyPhotoSharedRole.None, "entry" => SynologyPhotoSharedRole.Entry, "management" => SynologyPhotoSharedRole.Management, _ => throw Invalid() };
        bool? Value(string field) => KnownPreference(admin, field) is null ? null : KnownPreference(team, field);
        var result = new SynologyPhotoSharedSettings(ProfileId, administrator, Boolean(team, "enabled"), Boolean(user, "enable_home_service"), role,
            KnownPreference(team, "team_space_disabled_by_share_folder_disabled"), Value("enable_person"), Value("enable_concept"), Value("enable_similar"),
            KnownPreference(team, "allow_root_folder_public"), KnownPreference(admin, "enable_person"), KnownPreference(admin, "enable_concept"), KnownPreference(admin, "enable_similar"));
        lock (_accessGate)
        {
            RequireGeneration(generation, cancellationToken); _sharedAllowed = result.CanAccess;
            _managesSharedSpace = result.CanAccess && role == SynologyPhotoSharedRole.Management;
            var categories = new HashSet<SynologyPhotoCategory>();
            if (result.CanAccess)
            {
                categories.UnionWith([SynologyPhotoCategory.Recent, SynologyPhotoCategory.Locations, SynologyPhotoCategory.Tags, SynologyPhotoCategory.Videos]);
                foreach (var kind in RecognitionKinds)
                    if (KnownPreference(team, RecognitionField(kind)) == true && KnownPreference(admin, RecognitionField(kind)) != false) categories.Add(kind);
            }
            _sharedCategories = categories;
        }
        return result;
    }
    private static string SettingEndpoint(PhotoSettingsRecord record) => record.Shared is null ? "Setting.User" : "Setting.TeamSpace";
    private static bool SharedSettingMatches(SynologyPhotoSharedSettingChange change, SynologyPhotoSharedSettings actual, bool target) =>
        target && change.ChangesEnabled
            ? actual.ProfileId == change.Original.ProfileId && actual.AdministratorId == change.Original.AdministratorId && actual.Enabled == change.Updated.Enabled &&
                actual.PersonalEnabled == change.Original.PersonalEnabled && actual.Role == change.Original.Role
            : actual == (target ? change.Updated : change.Original);
    private static void ValidateSharedSetting(PhotoSettingsRecord record)
    {
        if (record.Shared is not { } change) { if (record.SharedResult is not null && record.Members is null) throw Invalid(); return; }
        var a = change.Original; var b = change.Updated;
        if (a is null || b is null || a.ProfileId != record.ProfileId || a.AdministratorId <= 0 || !Enum.IsDefined(a.Role)) throw Invalid();
        if (record.State == SynologyPhotoChangeState.Completed && record.SharedResult is null) throw Invalid();
        if (change.ChangesEnabled)
        {
            if (a with { Enabled = b.Enabled } != b || a.Enabled != b.Enabled && !a.CanSetEnabled(b.Enabled)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
        else if (a with { People = b.People, Subjects = b.Subjects, Similar = b.Similar, PublicRoot = b.PublicRoot } != b ||
            RecognitionKinds.Any(kind => a.Value(kind) != b.Value(kind) && (!a.Editable(kind) || b.Value(kind) is null)) ||
            a.PublicRoot != b.PublicRoot && (!a.Enabled || a.PublicRoot is null || b.PublicRoot is null))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (record.SharedResult is { } result && (record.State != SynologyPhotoChangeState.Completed || !Enum.IsDefined(result.Role) || !SharedSettingMatches(change, result, true))) throw Invalid();
    }
    private void CheckSharedSettingSafety(PhotoSettingsRecord record)
    {
        if (record.Shared is not { } change) return;
        if (change.Original.ProfileId != ProfileId || change.Original.AdministratorId != _currentUserId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (change.ChangesEnabled && change.Original.Enabled != change.Updated.Enabled && !SettingsSafety.SharedLibraryChanges ||
            change.Original.PublicRoot != change.Updated.PublicRoot && !SettingsSafety.PublicDirectorySharing)
            throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
    }
    public Task<SynologyPhotoSettingsChange> SetSharedSettingsAsync(Guid operationId, SynologyPhotoSharedSettings original,
        SynologyPhotoSharedSettings updated, bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (original is null || updated is null) throw Invalid();
        if (original.PublicRoot != updated.PublicRoot && !confirmed) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return SetPreferenceAsync(new(operationId, ProfileId, UploadOwner(), null, Shared: new(original, updated, false)), cancellationToken);
    }
    public Task<SynologyPhotoSettingsChange> SetSharedEnabledAsync(Guid operationId, SynologyPhotoSharedSettings original,
        bool enabled, bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (original is null) throw Invalid();
        if (original.Enabled != enabled && !confirmed) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return SetPreferenceAsync(new(operationId, ProfileId, UploadOwner(), null, Shared: new(original, original with { Enabled = enabled }, true)), cancellationToken);
    }
}
