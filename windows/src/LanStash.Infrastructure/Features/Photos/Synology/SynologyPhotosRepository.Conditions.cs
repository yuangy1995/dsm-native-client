using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static readonly string[] ConditionReferences = ["folder_filter", "rating", "person", "concept", "general_tag", "camera", "lens", "aperture", "iso", "geocoding"];
    private static readonly string[] ConditionSets = Enum.GetValues<SynologyPhotoConditionField>().Select(SynologyPhotoCondition.Key).Concat(["folder_filter", "rating", "item_type", "time"]).ToArray();
    private static readonly HashSet<string> ConditionKeys = ConditionSets.Concat(["user_id", "keyword_policy", "person_policy", "concept_policy", "general_tag_policy"]).ToHashSet(StringComparer.Ordinal);
    private long ConditionUser(SynologyPhotoSpace space)
    {
        RequireAccess(space);
        if (_currentUserId is not > 0 || space == SynologyPhotoSpace.Shared && !_managesSharedSpace) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return space == SynologyPhotoSpace.Shared ? 0 : _currentUserId.Value;
    }
    private static JsonObject ConditionObject(SynologyPhotoCondition condition) => new(condition.Fields.Select(pair => new KeyValuePair<string, JsonNode?>(pair.Key, JsonNode.Parse(pair.Value.GetRawText()))));
    private JsonObject ConditionParameters(SynologyPhotoCondition condition)
    {
        var user = ConditionUser(condition.Space); var fields = ConditionObject(condition);
        if (fields.ContainsKey("user_id") && OptionalLong(fields, "user_id") != user) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        fields["user_id"] = user; if (!fields.ContainsKey("item_type")) fields["item_type"] = new JsonArray();
        foreach (var key in ConditionSets)
        {
            if (!fields.ContainsKey(key)) continue;
            if (fields[key] is not JsonArray array) throw Invalid();
            if (key != "item_type" && array.Count == 0) { fields.Remove(key); continue; }
            foreach (var value in array)
            {
                if (ConditionReferences.Contains(key) && (!TryInteger(value, out var id) || key == "rating" && id is < 0 or > 5 || key == "folder_filter" && id <= 0)) throw Invalid();
                if (key == "item_type" && (!TryInteger(value, out var type) || type is not (-1 or -2))) throw Invalid();
                if (key == "keyword" && (value is not JsonValue word || !word.TryGetValue<string>(out _))) throw Invalid();
                if (key == "time")
                {
                    if (value is not JsonObject time) throw Invalid();
                    var start = OptionalLong(time, "start_time"); var end = OptionalLong(time, "end_time");
                    if (start is null && end is null || start < 0 || end < 0 || start > end) throw Invalid();
                }
                if (key is "focal_length_group" or "exposure_time_group" && (value is not JsonObject range || !range.ContainsKey("start") || !range.ContainsKey("end"))) throw Invalid();
            }
            fields[key] = new JsonArray(array.Select(CanonicalAlbumJson).OrderBy(value => value?.ToJsonString() ?? "null", StringComparer.Ordinal).ToArray());
        }
        foreach (var field in Enum.GetValues<SynologyPhotoConditionField>().Where(SynologyPhotoCondition.HasPolicy))
        {
            var key = SynologyPhotoCondition.Key(field);
            if (fields[key] is JsonArray { Count: > 0 } && OptionalText(fields, key + "_policy") is not ("and" or "or")) throw Invalid();
        }
        return (JsonObject)CanonicalAlbumJson(fields)!;
    }
    private static bool TryInteger(JsonNode? value, out long number)
    {
        number = 0; return value is JsonValue scalar && scalar.TryGetValue<long>(out number);
    }
    private static long? OptionalLong(JsonObject value, string key) => value[key] is null ? null : Number(value, key);
    private string ConditionHash(SynologyPhotoCondition condition) => PhotoTextHash(ConditionParameters(condition).ToJsonString());
    private SynologyPhotoCondition NormalizeCondition(JsonObject raw)
    {
        var user = OptionalLong(raw, "user_id");
        if (user is null || user != 0 && user != _currentUserId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var fields = (JsonObject)raw.DeepClone(); var names = new Dictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>();
        foreach (var key in ConditionReferences)
        {
            if (!fields.ContainsKey(key)) continue;
            if (fields[key] is not JsonArray array) throw Invalid();
            var values = new JsonArray(); var choices = new List<SynologyPhotoConditionOption>();
            foreach (var value in array)
            {
                if (value is not JsonObject item || OptionalLong(item, "id") is not { } id) throw Invalid();
                values.Add(id); choices.Add(new(OptionalText(item, "name"), JsonSerializer.SerializeToElement(id)));
            }
            fields[key] = values; names[key] = choices;
        }
        return new(user == 0 ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal,
            fields.ToDictionary(pair => pair.Key, pair => JsonSerializer.SerializeToElement(pair.Value)), names);
    }
    public async Task<SynologyPhotoConditionSnapshot> AlbumConditionAsync(long id, CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration); var raw = await ReadAlbumRawAsync(id, cancellationToken).ConfigureAwait(false) ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        var album = AlbumSnapshot(raw);
        if (!album.IsOwner || !album.Conditional || album.Frozen) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var list = List(await ReadAsync("Browse.ConditionAlbum", 3, "get", Parameters(("id", new[] { id }), ("additional", new[] { "condition_object" })), cancellationToken, null).ConfigureAwait(false));
        if (list.Length != 1 || Positive(list[0], "id") != id) throw Invalid();
        var condition = NormalizeCondition(Object(Object(list[0]["additional"])["condition_object"])); var hash = ConditionHash(condition);
        RequireGeneration(generation, cancellationToken); return new(album, condition, hash);
    }
    public async Task<SynologyPhotoFrozenAlbum> FrozenAlbumAsync(long id, CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration); var raw = await ReadAlbumRawAsync(id, cancellationToken).ConfigureAwait(false) ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        var album = AlbumSnapshot(raw);
        if (!album.IsOwner || !album.Frozen) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var condition = Object(Object(raw["additional"])["condition_object"]); var unsupported = Object(raw["cant_migrate_condition"]);
        if (album.Shared is null || album.ItemCount is null || album.Shared == true && Object(raw["additional"])["sharing_info"] is not JsonObject) throw Invalid();
        var fields = new JsonObject(condition.Where(pair => ConditionKeys.Contains(pair.Key)).Select(pair => new KeyValuePair<string, JsonNode?>(pair.Key, pair.Value?.DeepClone())));
        SynologyPhotoCondition? normalized = null;
        try { normalized = NormalizeCondition(fields); }
        catch (SynologyPhotoException error) when (error.Failure is SynologyPhotoFailure.Permission or SynologyPhotoFailure.InvalidResponse) { }
        RequireGeneration(generation, cancellationToken);
        return new(album, normalized, unsupported.Select(pair => pair.Key).Concat(condition.Where(pair => !ConditionKeys.Contains(pair.Key)).Select(pair => pair.Key)).Distinct().ToArray(),
            normalized is not null && !(condition.Count == 1 && OptionalLong(condition, "user_id") == 0));
    }
    public async Task<IReadOnlyDictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>> ConditionSuggestionsAsync(SynologyPhotoSpace space, string keyword, CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration); var user = ConditionUser(space);
        var keys = Enum.GetValues<SynologyPhotoConditionField>().Where(field => field is not (SynologyPhotoConditionField.Keyword or SynologyPhotoConditionField.Flash)).Select(SynologyPhotoCondition.Key).ToArray();
        var raw = await ReadAsync("Browse.ConditionAlbum", 3, "suggest", Parameters(("keyword", keyword), ("user_id", user), ("condition", keys), ("additional", new[] { "thumbnail" })), cancellationToken, null).ConfigureAwait(false);
        var result = new Dictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>();
        foreach (var key in keys)
        {
            if (!raw.ContainsKey(key)) continue;
            if (raw[key] is not JsonArray array) throw Invalid();
            var options = new List<SynologyPhotoConditionOption>();
            void Location(JsonObject item, string[] parents, long? parent = null)
            {
                var name = Text(item, "name"); var id = Number(item, "id"); var names = parents.Append(name).ToArray();
                if (item["children"] is JsonArray { Count: > 0 } children) { foreach (var child in children) Location(Object(child), names, id); return; }
                var repeat = parents.LastOrDefault() == name && parent is not null;
                options.Add(new(string.Join(", ", repeat ? parents : names), JsonSerializer.SerializeToElement(repeat ? parent!.Value : id)));
            }
            foreach (var value in array)
            {
                var item = Object(value);
                if (key == "geocoding") { Location(item, []); continue; }
                if (key is "focal_length_group" or "exposure_time_group")
                { if (!item.ContainsKey("start") || !item.ContainsKey("end")) throw Invalid(); options.Add(new(null, JsonSerializer.SerializeToElement(item))); }
                else options.Add(new(Text(item, "name"), JsonSerializer.SerializeToElement(Number(item, "id"))));
            }
            result[key] = options;
        }
        RequireGeneration(generation, cancellationToken); _ = ConditionUser(space); return result;
    }
    public async Task<int> ConditionItemCountAsync(SynologyPhotoCondition condition, CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration);
        var data = await ReadAsync("Browse.ConditionAlbum", 3, "peek_item_count", Parameters(("condition", ConditionParameters(condition))), cancellationToken, null).ConfigureAwait(false);
        var count = OptionalInt(data, "count"); if (count is null or < 0) throw Invalid();
        RequireGeneration(generation, cancellationToken); _ = ConditionUser(condition.Space); return count.Value;
    }
    private async Task ValidateConditionAsync(SynologyPhotoCondition condition, CancellationToken token)
    {
        var fields = ConditionParameters(condition);
        if (fields["folder_filter"] is JsonArray folders)
            foreach (var id in folders) _ = await ReadPhotoFolderAsync(id!.GetValue<long>(), condition.Space, PhotoFolderRight.View, token).ConfigureAwait(false);
    }
    private async Task PrepareConditionAlbumAsync(PhotoAlbumChangeRecord record, SynologyPhotoCondition? condition, CancellationToken token)
    {
        var edit = record.Edit;
        if (edit.Kind == SynologyPhotoAlbumEditKind.Unfreeze) { _ = await FrozenAlbumAsync(edit.Album!.Id, token).ConfigureAwait(false); return; }
        if (!AlbumNeedsCondition(edit.Kind)) return;
        if (condition is null || condition.Space != edit.ConditionSpace || ConditionHash(condition) != record.ConditionHash) throw Invalid();
        SynologyPhotoCondition? original = null;
        if (edit.Kind == SynologyPhotoAlbumEditKind.Condition)
        {
            var current = await AlbumConditionAsync(edit.Album!.Id, token).ConfigureAwait(false);
            if (current.Revision != edit.OriginalConditionRevision) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            original = current.Condition;
            var oldUnknown = new JsonObject(ConditionObject(original).Where(pair => !ConditionKeys.Contains(pair.Key)).Select(pair => new KeyValuePair<string, JsonNode?>(pair.Key, pair.Value?.DeepClone())));
            var newUnknown = new JsonObject(ConditionObject(condition).Where(pair => !ConditionKeys.Contains(pair.Key)).Select(pair => new KeyValuePair<string, JsonNode?>(pair.Key, pair.Value?.DeepClone())));
            if (!JsonNode.DeepEquals(oldUnknown, newUnknown)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
        else
        {
            if (condition.Fields.Keys.Any(key => !ConditionKeys.Contains(key))) throw Invalid();
            if (edit.Kind == SynologyPhotoAlbumEditKind.Rebuild)
            {
                var current = await FrozenAlbumAsync(edit.Album!.Id, token).ConfigureAwait(false);
                if (!current.CanRebuild) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
                original = current.RebuildCondition;
            }
        }
        // 尚无可创建闪光灯值的契约；只允许保留或移除已读取的值。
        if (condition.Fields.TryGetValue("flash", out var flash) && flash.ValueKind == JsonValueKind.Array && flash.GetArrayLength() > 0 &&
            (original is null || !original.Fields.TryGetValue("flash", out var prior) || !JsonElement.DeepEquals(flash, prior))) throw Invalid();
        await ValidateConditionAsync(condition, token).ConfigureAwait(false);
    }
}
