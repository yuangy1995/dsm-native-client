using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static string GlobalField(SynologyPhotoGlobalKind kind) => kind switch
    { SynologyPhotoGlobalKind.People => "enable_person", SynologyPhotoGlobalKind.Subjects => "enable_concept", SynologyPhotoGlobalKind.Similar => "enable_similar",
      SynologyPhotoGlobalKind.UserSharing => "enable_user_sharing", SynologyPhotoGlobalKind.GuestInfo => "display_photo_info_to_guest", _ => "enable_converted_original_jpeg" };
    public async Task<SynologyPhotoGlobalSettings> GlobalSettingsAsync(CancellationToken cancellationToken = default)
    {
        RequireAccess(); var generation = Volatile.Read(ref _accessGeneration);
        var administrator = await RequirePhotoAdministratorAsync(cancellationToken).ConfigureAwait(false);
        var user = await CallAsync("Setting.User", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        var admin = await CallAsync("Setting.Admin", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        var team = await CallAsync("Setting.TeamSpace", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken);
        var role = Text(user, "team_space_permission") switch
        { "none" => SynologyPhotoSharedRole.None, "entry" => SynologyPhotoSharedRole.Entry, "management" => SynologyPhotoSharedRole.Management, _ => throw Invalid() };
        var extensions = admin["exclude_extension"] is null ? null : admin["exclude_extension"] is JsonArray array
            ? array.Select(item => item is JsonValue value && value.TryGetValue<string>(out var text) ? text : throw Invalid()).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray() : throw Invalid();
        var result = new SynologyPhotoGlobalSettings(ProfileId, administrator, KnownPreference(admin, "enable_person"), KnownPreference(admin, "enable_concept"), KnownPreference(admin, "enable_similar"),
            KnownPreference(admin, "enable_user_sharing"), KnownPreference(admin, "display_photo_info_to_guest"), KnownPreference(admin, "enable_converted_original_jpeg"), extensions,
            OptionalObject(user, "ame_status") is { } ame ? KnownPreference(ame, "has_hevc") : null, Boolean(user, "enable_home_service"), Boolean(team, "enabled"), role,
            KnownPreference(user, "enable_person"), KnownPreference(user, "enable_concept"), KnownPreference(user, "enable_similar"),
            KnownPreference(team, "enable_person"), KnownPreference(team, "enable_concept"), KnownPreference(team, "enable_similar"));
        lock (_accessGate)
        {
            RequireGeneration(generation, cancellationToken); SupportsOriginalSizeJpeg = result.SupportsOriginalJpeg;
            var personal = _disabledPersonalCategories.ToHashSet(); var shared = _sharedCategories.ToHashSet();
            foreach (var kind in RecognitionKinds)
            {
                var field = RecognitionField(kind); var global = KnownPreference(admin, field);
                if (KnownPreference(user, field) == false || global == false) personal.Add(kind);
                else if (KnownPreference(user, field) == true && global != false) personal.Remove(kind);
                if (KnownPreference(team, field) == true && global != false && result.SharedEnabled && role != SynologyPhotoSharedRole.None) shared.Add(kind);
                else if (KnownPreference(team, field) == false || global == false || !result.SharedEnabled || role == SynologyPhotoSharedRole.None) shared.Remove(kind);
            }
            _disabledPersonalCategories = personal; _sharedCategories = shared;
        }
        return result;
    }
    public async Task<SynologyPhotoConversionCache> ConversionCacheAsync(CancellationToken cancellationToken = default)
    {
        RequireAccess(); var generation = Volatile.Read(ref _accessGeneration);
        var administrator = await RequirePhotoAdministratorAsync(cancellationToken).ConfigureAwait(false);
        var status = Text(await CallAsync("Download", 2, "get_cache_status", cancellationToken: cancellationToken).ConfigureAwait(false), "status");
        var size = Number(await CallAsync("Download", 2, "calculate_cache_size", cancellationToken: cancellationToken).ConfigureAwait(false), "cache_size");
        RequireGeneration(generation, cancellationToken);
        if (status.Length == 0 || size < 0) throw Invalid();
        return new(ProfileId, administrator, size, status == "processing");
    }
    private sealed record GlobalSettingStep(SynologyPhotoSettingStep Kind, string Endpoint, int Version, string Method, Dictionary<string,string> Parameters);
    private static IReadOnlyList<GlobalSettingStep> GlobalSteps(PhotoSettingsRecord record)
    {
        var steps = new List<GlobalSettingStep>();
        if (record.Cache is not null || record.Global is { Original.OriginalJpeg: true, Updated.OriginalJpeg: false })
            steps.Add(new(SynologyPhotoSettingStep.Cache, "Download", 2, "clear_cache", []));
        if (record.Global is not { Original: var a, Updated: var b }) return steps;
        var admin = new Dictionary<string,string>();
        foreach (var kind in Enum.GetValues<SynologyPhotoGlobalKind>()) if (a.Value(kind) != b.Value(kind)) Add(admin, Parameters((GlobalField(kind), b.Value(kind) == true)));
        if (!SynologyPhotoGlobalSettings.SameExtensions(a.ExcludedExtensions, b.ExcludedExtensions)) Add(admin, Parameters(("exclude_extension", b.ExcludedExtensions!.Order(StringComparer.Ordinal).ToArray())));
        if (admin.Count > 0) steps.Add(new(SynologyPhotoSettingStep.Admin, "Setting.Admin", 1, "set", admin));
        foreach (var (kind, endpoint, before, after) in new[]
        {
            (SynologyPhotoSettingStep.Personal, "Setting.User", new[] { a.PersonalPeople, a.PersonalSubjects, a.PersonalSimilar }, new[] { b.PersonalPeople, b.PersonalSubjects, b.PersonalSimilar }),
            (SynologyPhotoSettingStep.Shared, "Setting.TeamSpace", new[] { a.SharedPeople, a.SharedSubjects, a.SharedSimilar }, new[] { b.SharedPeople, b.SharedSubjects, b.SharedSimilar })
        })
        {
            var values = new Dictionary<string,string>();
            for (var i = 0; i < before.Length; i++) if (before[i] != after[i]) Add(values, Parameters((RecognitionField(RecognitionKinds[i]), after[i] == true)));
            if (values.Count > 0) steps.Add(new(kind, endpoint, 1, "set", values));
        }
        return steps;
    }
    private static void ValidateGlobalSetting(PhotoSettingsRecord record)
    {
        if (record.Members is not null || record.Maintenance is not null || record.Codec is not null || record.Background is not null)
        { if (record.Global is not null || record.Cache is not null || record.Steps is { Length: > 0 } || record.GlobalResult is not null || record.CacheResult is not null) throw Invalid(); return; }
        if (record.Global is { Original: var a, Updated: var b })
        {
            if (a is null || b is null || a.ProfileId != record.ProfileId || a.AdministratorId <= 0 || !Enum.IsDefined(a.SharedRole) ||
                a.ExcludedExtensions?.Any(value => value is null) == true || b.ExcludedExtensions?.Any(value => value is null) == true) throw Invalid();
            var enabled = Enum.GetValues<SynologyPhotoGlobalKind>().Where(kind => b.Value(kind) == true).ToHashSet();
            if (!a.Applying(enabled, b.ExcludedExtensions).SameValues(b) ||
                Enum.GetValues<SynologyPhotoGlobalKind>().Any(kind => a.Value(kind) != b.Value(kind) && !a.Editable(kind)) ||
                (a.ExcludedExtensions is null) != (b.ExcludedExtensions is null) ||
                b.ExcludedExtensions?.Except(SynologyPhotoGlobalSettings.SupportedExtensions.Concat(a.ExcludedExtensions ?? []), StringComparer.Ordinal).Any() == true)
                throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
        if (record.Cache is { } cache && (cache.ProfileId != record.ProfileId || cache.AdministratorId <= 0 || !cache.CanClear)) throw Invalid();
        var steps = GlobalSteps(record).Select(step => step.Kind).ToArray(); var facts = record.Steps ?? [];
        if (facts.Length > steps.Length || facts.Select(fact => fact.Kind).Distinct().Count() != facts.Length ||
            facts.Where((fact, index) => fact.Kind != steps[index] || !Enum.IsDefined(fact.Status) || index < facts.Length - 1 && fact.Status != SynologyPhotoWriteStatus.Accepted).Any() ||
            record.CompletedSteps < 0 || record.CompletedSteps > facts.Length ||
            record.GlobalResult is { } result && (record.Global is null || result.ProfileId != record.ProfileId || result.AdministratorId != record.Global.Original.AdministratorId) ||
            record.CacheResult is { } current && (record.Global is null && record.Cache is null || current.ProfileId != record.ProfileId || current.SizeBytes < 0 || current.AdministratorId != (record.Cache?.AdministratorId ?? record.Global?.Original.AdministratorId))) throw Invalid();
        if (record.Global is null && record.Cache is null && (facts.Length > 0 || record.Members is null && record.CompletedSteps != 0)) throw Invalid();
        if ((record.Global is not null || record.Cache is not null) && record.State == SynologyPhotoChangeState.Completed && record.CompletedSteps != steps.Length) throw Invalid();
        if ((record.Global is not null || record.Cache is not null) && (record.Submitted != (facts.Length > 0) ||
            record.State == SynologyPhotoChangeState.Completed && (record.Global is not null && record.GlobalResult is null || record.Cache is not null && record.CacheResult is null))) throw Invalid();
    }
    private async Task ValidateGlobalSettingsAsync(PhotoSettingsRecord record, CancellationToken token)
    {
        if (record.Global is { } global)
        {
            if (!global.Original.SameValues(await GlobalSettingsAsync(token).ConfigureAwait(false))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if ((global.Original.UserSharing != global.Updated.UserSharing || global.Original.GuestInfo != global.Updated.GuestInfo) && !SettingsSafety.GlobalSharingChanges)
                throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        }
        if (GlobalSteps(record).Any(step => step.Kind == SynologyPhotoSettingStep.Cache))
        {
            var current = await ConversionCacheAsync(token).ConfigureAwait(false);
            if (current.IsClearing || record.Cache is { } original && (current.ProfileId != original.ProfileId || current.AdministratorId != original.AdministratorId || !current.CanClear))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
        foreach (var step in GlobalSteps(record)) _ = Capability(step.Endpoint, step.Version, null);
    }
    public Task<SynologyPhotoSettingsChange> SetGlobalSettingsAsync(Guid operationId, SynologyPhotoGlobalSettings original, SynologyPhotoGlobalSettings updated,
        bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (original is null || updated is null) throw Invalid();
        if (!original.SameValues(updated) && !confirmed) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return SetPreferenceAsync(new(operationId, ProfileId, UploadOwner(), null, Global: new(original, updated)), cancellationToken);
    }
    public Task<SynologyPhotoSettingsChange> ClearConversionCacheAsync(Guid operationId, SynologyPhotoConversionCache original, bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (original is null) throw Invalid(); if (!confirmed) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return SetPreferenceAsync(new(operationId, ProfileId, UploadOwner(), null, Cache: original), cancellationToken);
    }
}
