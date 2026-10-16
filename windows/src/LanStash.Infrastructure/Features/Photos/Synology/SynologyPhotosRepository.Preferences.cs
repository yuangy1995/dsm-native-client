using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static readonly string[] PhotoDateFormats = ["yyyy-mm-dd", "yyyy/mm/dd", "yyyy.mm.dd", "dd-mm-yyyy", "dd/mm/yyyy", "dd.mm.yyyy", "mm-dd-yyyy", "mm/dd/yyyy", "mm.dd.yyyy"];
    private static readonly SynologyPhotoCategory[] RecognitionKinds = [SynologyPhotoCategory.People, SynologyPhotoCategory.Subjects, SynologyPhotoCategory.Similar];
    private static string RecognitionField(SynologyPhotoCategory kind) => kind switch
    { SynologyPhotoCategory.People => "enable_person", SynologyPhotoCategory.Subjects => "enable_concept", SynologyPhotoCategory.Similar => "enable_similar", _ => throw Invalid() };
    private static bool? KnownPreference(JsonObject raw, string key) => raw[key] is JsonValue value && value.TryGetValue<bool>(out var result) ? result : null;
    private static SynologyPhotoDisplaySettings? ParseDisplaySettings(JsonObject raw)
    {
        string? Field(string key) => raw[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
        var grouping = Field("timeline_group_unit"); var clock = Field("time_format");
        var date = Array.IndexOf(PhotoDateFormats, Field("date_format")?.ToLowerInvariant());
        if (grouping is not ("day" or "month") || clock is not ("12" or "24") || date < 0 ||
            ParseSortField(Field("item_sort_by")) is not { } field || SortDirection(Field("sort_direction")) is not { } descending ||
            KnownPreference(raw, "show_item_info_in_lightbox") is not { } info) return null;
        return new(grouping == "day" ? SynologyPhotoGrouping.Day : SynologyPhotoGrouping.Month, (SynologyPhotoDateFormat)date, clock == "12", new(field, descending), info);
    }
    private async Task<JsonObject> ReadPreferenceUserAsync(CancellationToken token)
    {
        RequireAccess(); var generation = Volatile.Read(ref _accessGeneration);
        var value = await CallAsync("Setting.User", 1, "get", cancellationToken: token).ConfigureAwait(false);
        RequireGeneration(generation, token); return value;
    }
    public async Task<SynologyPhotoDisplaySettings> DisplaySettingsAsync(CancellationToken cancellationToken = default) =>
        ParseDisplaySettings(await ReadPreferenceUserAsync(cancellationToken).ConfigureAwait(false)) ?? throw Invalid();
    public async Task<SynologyPhotoDuplicateSettings> DuplicateSettingsAsync(CancellationToken cancellationToken = default)
    {
        var value = await ReadPreferenceUserAsync(cancellationToken).ConfigureAwait(false);
        return new(Text(value, "upload_default_action") switch { "ignore" => SynologyPhotoDuplicatePolicy.Skip, "rename" => SynologyPhotoDuplicatePolicy.KeepBoth, _ => throw Invalid() },
            Text(value, "copy_move_default_action") switch { "skip" => SynologyPhotoFileDuplicate.Skip, "overwrite" => SynologyPhotoFileDuplicate.Overwrite, _ => throw Invalid() });
    }
    public async Task<SynologyPhotoRecognitionSettings> RecognitionSettingsAsync(CancellationToken cancellationToken = default)
    {
        RequireAccess(); var generation = Volatile.Read(ref _accessGeneration);
        var user = await ReadPreferenceUserAsync(cancellationToken).ConfigureAwait(false);
        var admin = await CallAsync("Setting.Admin", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken);
        bool? Personal(string field) => KnownPreference(admin, field) is null ? null : KnownPreference(user, field);
        var result = new SynologyPhotoRecognitionSettings(Boolean(user, "enable_home_service"), Personal("enable_person"), Personal("enable_concept"), Personal("enable_similar"),
            KnownPreference(admin, "enable_person"), KnownPreference(admin, "enable_concept"), KnownPreference(admin, "enable_similar"));
        lock (_accessGate)
        {
            RequireGeneration(generation, cancellationToken);
            var disabled = _disabledPersonalCategories.ToHashSet();
            foreach (var kind in RecognitionKinds)
            {
                var field = RecognitionField(kind);
                if (KnownPreference(user, field) == false || KnownPreference(admin, field) == false) disabled.Add(kind);
                else if (KnownPreference(user, field) == true && KnownPreference(admin, field) == true) disabled.Remove(kind);
            }
            _disabledPersonalCategories = disabled;
        }
        return result;
    }
    private static void ValidateDisplaySetting(SynologyPhotoDisplaySettings value)
    {
        if (value is null || !Enum.IsDefined(value.Grouping) || !Enum.IsDefined(value.DateFormat) || value.DefaultSort is null || !Enum.IsDefined(value.DefaultSort.Field)) throw Invalid();
    }
    private static void ValidateSettingPayload(PhotoSettingsRecord record)
    {
        if (new object?[] { record.Automatic, record.Display, record.Duplicates, record.Recognition, record.Shared, record.Global, record.Cache, record.Members, record.Maintenance, record.Codec, record.Background }.Count(value => value is not null) != 1) throw Invalid();
        ValidateBackgroundRecord(record);
        ValidateMaintenanceRecord(record);
        ValidateMembersRecord(record);
        ValidateSharedSetting(record);
        ValidateGlobalSetting(record);
        if (record.Display is { } display) { ValidateDisplaySetting(display.Original); ValidateDisplaySetting(display.Updated); }
        if (record.Duplicates is { } duplicates && (duplicates.Original is null || duplicates.Updated is null || !Enum.IsDefined(duplicates.Original.Upload) ||
            !Enum.IsDefined(duplicates.Updated.Upload) || !Enum.IsDefined(duplicates.Original.Transfer) || !Enum.IsDefined(duplicates.Updated.Transfer))) throw Invalid();
        if (record.Recognition is { } recognition)
        {
            var a = recognition.Original; var b = recognition.Updated;
            if (a is null || b is null || a.PersonalEnabled != b.PersonalEnabled || a.GlobalPeople != b.GlobalPeople || a.GlobalSubjects != b.GlobalSubjects || a.GlobalSimilar != b.GlobalSimilar ||
                RecognitionKinds.Any(kind => a.Value(kind) != b.Value(kind) && (!a.Editable(kind) || b.Value(kind) is null))) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
    }
    private static Dictionary<string, string> SettingParameters(PhotoSettingsRecord record)
    {
        var values = new Dictionary<string, string>();
        void Change(string field, object original, object target) { if (!Equals(original, target)) Add(values, Parameters((field, target))); }
        if (record.Automatic is { } automatic) Change("auto_generate_thumbnail", automatic.Original, automatic.Enabled);
        if (record.Display is { Original: var a, Updated: var b })
        {
            Change("timeline_group_unit", a.Grouping == SynologyPhotoGrouping.Day ? "day" : "month", b.Grouping == SynologyPhotoGrouping.Day ? "day" : "month");
            Change("date_format", PhotoDateFormats[(int)a.DateFormat], PhotoDateFormats[(int)b.DateFormat]);
            Change("time_format", a.TwelveHourClock ? "12" : "24", b.TwelveHourClock ? "12" : "24");
            Change("item_sort_by", SortField(a.DefaultSort.Field), SortField(b.DefaultSort.Field));
            Change("sort_direction", a.DefaultSort.Descending ? "desc" : "asc", b.DefaultSort.Descending ? "desc" : "asc");
            Change("show_item_info_in_lightbox", a.ShowsPreviewInfo, b.ShowsPreviewInfo);
        }
        if (record.Duplicates is { Original: var c, Updated: var d })
        {
            Change("upload_default_action", c.Upload == SynologyPhotoDuplicatePolicy.Skip ? "ignore" : "rename", d.Upload == SynologyPhotoDuplicatePolicy.Skip ? "ignore" : "rename");
            Change("copy_move_default_action", c.Transfer == SynologyPhotoFileDuplicate.Skip ? "skip" : "overwrite", d.Transfer == SynologyPhotoFileDuplicate.Skip ? "skip" : "overwrite");
        }
        if (record.Recognition is { Original: var e, Updated: var f })
            foreach (var kind in RecognitionKinds.Where(kind => e.Value(kind) != f.Value(kind))) Add(values, Parameters((RecognitionField(kind), f.Value(kind) == true)));
        if (record.Shared is { Original: var shared, Updated: var target } change)
        {
            if (change.ChangesEnabled) Change("enabled", shared.Enabled, target.Enabled);
            else
            {
                foreach (var kind in RecognitionKinds.Where(kind => shared.Value(kind) != target.Value(kind))) Add(values, Parameters((RecognitionField(kind), target.Value(kind) == true)));
                if (shared.PublicRoot != target.PublicRoot) Change("allow_root_folder_public", shared.PublicRoot == true, target.PublicRoot == true);
            }
        }
        return values;
    }
    private async Task<bool> SettingMatchesAsync(PhotoSettingsRecord record, bool target, CancellationToken token)
    {
        if (record.Automatic is { } a) return await AutomaticPreviewEnabledAsync(token).ConfigureAwait(false) == (target ? a.Enabled : a.Original);
        if (record.Display is { } d) return await DisplaySettingsAsync(token).ConfigureAwait(false) == (target ? d.Updated : d.Original);
        if (record.Duplicates is { } u) return await DuplicateSettingsAsync(token).ConfigureAwait(false) == (target ? u.Updated : u.Original);
        if (record.Recognition is { } r) return await RecognitionSettingsAsync(token).ConfigureAwait(false) == (target ? r.Updated : r.Original);
        if (record.Shared is { } s) return SharedSettingMatches(s, await SharedSettingsAsync(token).ConfigureAwait(false), target);
        throw Invalid();
    }
    public Task<SynologyPhotoSettingsChange> SetDisplaySettingsAsync(Guid operationId, SynologyPhotoDisplaySettings original, SynologyPhotoDisplaySettings updated, CancellationToken cancellationToken = default) =>
        SetPreferenceAsync(new(operationId, ProfileId, UploadOwner(), null, Display: new(original, updated)), cancellationToken);
    public Task<SynologyPhotoSettingsChange> SetDuplicateSettingsAsync(Guid operationId, SynologyPhotoDuplicateSettings original, SynologyPhotoDuplicateSettings updated, CancellationToken cancellationToken = default) =>
        SetPreferenceAsync(new(operationId, ProfileId, UploadOwner(), null, Duplicates: new(original, updated)), cancellationToken);
    public Task<SynologyPhotoSettingsChange> SetRecognitionSettingsAsync(Guid operationId, SynologyPhotoRecognitionSettings original, SynologyPhotoRecognitionSettings updated, CancellationToken cancellationToken = default) =>
        SetPreferenceAsync(new(operationId, ProfileId, UploadOwner(), null, Recognition: new(original, updated)), cancellationToken);
}
