using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>严格读取已记录字段；缺失列表不能伪装为空，身份不能从显示名称猜测。</summary>
internal static class SynologyPhotosCodec
{
    internal static SynologyPhotoException Invalid() => new(SynologyPhotoFailure.InvalidResponse);
    internal static JsonObject Object(JsonNode? value) => value as JsonObject ?? throw Invalid();
    internal static JsonObject? OptionalObject(JsonObject value, string key) => value[key] is { } node ? Object(node) : null;
    internal static JsonObject[] List(JsonObject value, string key = "list") =>
        value[key] is JsonArray array ? array.Select(Object).ToArray() : throw Invalid();
    internal static JsonObject[] OptionalList(JsonObject value, string key) => value[key] is null ? [] : List(value, key);
    internal static string Text(JsonObject value, string key) =>
        value[key] is JsonValue node && node.TryGetValue<string>(out var result) ? result : throw Invalid();
    internal static string? OptionalText(JsonObject value, string key) => value[key] is null ? null : Text(value, key);
    internal static long Number(JsonObject value, string key) =>
        value[key] is JsonValue node && node.TryGetValue<long>(out var result) ? result : throw Invalid();
    internal static int Int(JsonObject value, string key) => Number(value, key) is var number && number is >= int.MinValue and <= int.MaxValue ? (int)number : throw Invalid();
    internal static int? OptionalInt(JsonObject value, string key) => value[key] is null ? null : Int(value, key);
    internal static long Positive(JsonObject value, string key) => Number(value, key) is var number && number > 0 ? number : throw Invalid();
    internal static double Decimal(JsonObject value, string key) =>
        value[key] is JsonValue node && node.TryGetValue<double>(out var result) && double.IsFinite(result) ? result : throw Invalid();
    internal static bool Boolean(JsonObject value, string key) =>
        value[key] is JsonValue node && node.TryGetValue<bool>(out var result) ? result : throw Invalid();
    internal static bool Permission(JsonObject? value, string key) =>
        value?[key] is JsonValue node && node.TryGetValue<bool>(out var result) && result;
    internal static Dictionary<string, string> Parameters(params (string Key, object Value)[] values) =>
        values.ToDictionary(pair => pair.Key, pair => JsonSerializer.Serialize(pair.Value), StringComparer.Ordinal);

    internal static DateTimeOffset Timestamp(JsonObject value, string key)
    {
        try { return DateTimeOffset.UnixEpoch.AddSeconds(Decimal(value, key)); }
        catch (ArgumentOutOfRangeException) { throw Invalid(); }
    }

    internal static SynologyPhoto Photo(JsonObject value, Guid profileId)
    {
        var size = Number(value, "filesize");
        if (size < 0) throw Invalid();
        var additional = OptionalObject(value, "additional");
        var resolution = additional is null ? null : OptionalObject(additional, "resolution");
        var exif = additional is null ? null : OptionalObject(additional, "exif");
        var thumbnail = additional is null ? null : OptionalObject(additional, "thumbnail");
        var gps = additional is null ? null : OptionalObject(additional, "gps");
        var latitude = gps is null ? (double?)null : Decimal(gps, "latitude");
        var longitude = gps is null ? (double?)null : Decimal(gps, "longitude");
        var validGps = latitude is >= -90 and <= 90 && longitude is >= -180 and <= 180;
        var address = additional is null ? null : OptionalObject(additional, "address");
        var video = additional is null ? null : OptionalObject(additional, "video_meta");
        string? Exif(string key) => exif is null ? null : OptionalText(exif, key);
        return new SynologyPhoto(
            new SynologyPhotoIdentity(profileId, SynologyPhotoSpace.Personal, Positive(value, "id")),
            Text(value, "filename"), size, Timestamp(value, "time"), Timestamp(value, "indexed_time"),
            Positive(value, "folder_id"), Text(value, "type"))
        {
            Thumbnail = thumbnail is null ? null : new(Positive(thumbnail, "unit_id"), Text(thumbnail, "cache_key")),
            Width = resolution is null ? null : OptionalInt(resolution, "width"),
            Height = resolution is null ? null : OptionalInt(resolution, "height"),
            Orientation = additional is null ? null : OptionalInt(additional, "orientation"),
            Description = additional is null ? null : OptionalText(additional, "description"),
            Camera = Exif("camera"), Lens = Exif("lens"), Aperture = Exif("aperture"),
            ExposureTime = Exif("exposure_time"), FocalLength = Exif("focal_length"), Iso = Exif("iso"),
            Duration = video?["duration"] is null ? null : Decimal(video, "duration"),
            Rating = additional is null ? null : OptionalInt(additional, "rating"),
            Latitude = validGps ? latitude : null, Longitude = validGps ? longitude : null,
            Address = address is null ? [] : new[] { "country", "state", "county", "city", "town", "district", "village", "route", "landmark" }
                .Select(key => OptionalText(address, key)).OfType<string>().Where(text => text.Length > 0).Distinct(StringComparer.Ordinal).ToArray(),
        };
    }

    internal static IReadOnlyList<SynologyPhotoDay> Days(JsonObject payload) => List(payload, "section").SelectMany(section =>
        List(section).Select(day =>
        {
            try
            {
                var count = Int(day, "item_count");
                if (count < 0) throw Invalid();
                return new SynologyPhotoDay(new DateOnly(Int(day, "year"), Int(day, "month"), Int(day, "day")), count);
            }
            catch (ArgumentOutOfRangeException) { throw Invalid(); }
        })).ToArray();

    internal static SynologyPhotoCollection Collection(JsonObject value, bool folder = false) =>
        new(Positive(value, "id"), folder ? Text(value, "name").TrimEnd('/').Split('/').Last() : Text(value, "name"),
            folder ? Number(value, "parent") : null, OptionalInt(value, "item_count"));

    internal static IReadOnlyList<SynologyPhotoCollection> Collections(JsonObject payload, int limit, bool folders = false, long? parentId = null)
    {
        var result = List(payload).Select(item => Collection(item, folders)).ToArray();
        if (result.Length > limit || result.DistinctBy(item => item.Id).Count() != result.Length ||
            result.Any(item => item.Count < 0 || (parentId is not null && item.ParentId != parentId))) throw Invalid();
        return result;
    }

    internal static SynologyPhotoFilterOptions Options(JsonObject payload)
    {
        IReadOnlyList<SynologyPhotoChoice> Choices(string key, bool required = false)
        {
            var result = (required ? List(payload, key) : OptionalList(payload, key))
                .Select(item => new SynologyPhotoChoice(Positive(item, "id"), Text(item, "name"))).ToArray();
            if (result.DistinctBy(item => item.Id).Count() != result.Length) throw Invalid();
            return result;
        }
        var seen = new HashSet<long>();
        SynologyPhotoLocation Location(JsonObject item, int depth)
        {
            var id = Positive(item, "id");
            if (depth > 32 || !seen.Add(id)) throw Invalid();
            return new(id, Text(item, "name"), Int(item, "level"), OptionalList(item, "children").Select(child => Location(child, depth + 1)).ToArray());
        }
        SynologyPhotoFraction Fraction(JsonObject item)
        {
            var value = new SynologyPhotoFraction(Int(item, "num"), Int(item, "den"));
            if (value.Num < 0 || value.Den <= 0) throw Invalid();
            return value;
        }
        return new SynologyPhotoFilterOptions
        {
            People = Choices("person", true), Locations = List(payload, "geocoding").Select(item => Location(item, 0)).ToArray(),
            Tags = Choices("general_tag"), Cameras = Choices("camera"), Lenses = Choices("lens"),
            Iso = Choices("iso"), Apertures = Choices("aperture"),
            FocalRanges = OptionalList(payload, "focal_length_group").Select(item =>
            {
                var range = new SynologyPhotoFocalRange(Int(item, "start"), Int(item, "end"));
                if (range.Start < 0 || range.End < 0) throw Invalid();
                return range;
            }).Distinct().ToArray(),
            ExposureRanges = OptionalList(payload, "exposure_time_group")
                .Select(item => new SynologyPhotoExposureRange(Fraction(Object(item["start"])), Fraction(Object(item["end"])))).Distinct().ToArray(),
        };
    }

    internal static Dictionary<string, string> FilterParameters(SynologyPhotoFilter filter)
    {
        if ((filter.StartTime is null) != (filter.EndTime is null)) throw Invalid();
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        void Put(string key, object value) => result[key] = JsonSerializer.Serialize(value);
        if (filter.MediaType is { } mediaType)
        {
            if (mediaType is < 0 or > 1) throw Invalid();
            Put("item_type", new[] { mediaType });
        }
        foreach (var (key, id) in new[] { ("person", filter.PersonId), ("geocoding", filter.LocationId), ("general_tag", filter.TagId),
                     ("camera", filter.CameraId), ("lens", filter.LensId), ("iso", filter.IsoId), ("aperture", filter.ApertureId) })
        {
            if (id is null) continue;
            if (id <= 0) throw Invalid();
            Put(key, new[] { id.Value });
        }
        if (filter.PersonId is not null) Put("person_policy", "or");
        if (filter.TagId is not null) Put("general_tag_policy", "or");
        if (filter.Rating is { } rating)
        {
            if (rating is < 0 or > 5) throw Invalid();
            Put("rating", new[] { rating });
        }
        if (filter.StartTime is { } start && filter.EndTime is { } end) result["time"] = Time(start, end);
        if (filter.FocalRange is { } focal)
        {
            if (focal.Start < 0 || focal.End < 0) throw Invalid();
            Put("focal_length_group", new[] { new { start = focal.Start, end = focal.End } });
        }
        if (filter.ExposureRange is { } exposure)
        {
            if (exposure.Start.Num < 0 || exposure.End.Num < 0 || exposure.Start.Den <= 0 || exposure.End.Den <= 0) throw Invalid();
            Put("exposure_time_group", new[] { new { start = new { num = exposure.Start.Num, den = exposure.Start.Den }, end = new { num = exposure.End.Num, den = exposure.End.Den } } });
        }
        return result;
    }

    internal static string Time(long start, long end)
    {
        if (start < 0 || end < start) throw Invalid();
        return JsonSerializer.Serialize(new[] { new { start_time = start, end_time = end } });
    }
}
