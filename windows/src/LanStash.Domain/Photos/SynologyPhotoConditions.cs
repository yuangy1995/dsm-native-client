using System.Collections.ObjectModel;
using System.Text.Json;

namespace LanStash.Domain;

public enum SynologyPhotoConditionField { Keyword, Person, Concept, GeneralTag, Camera, Lens, Aperture, Iso, Geocoding, FocalLength, ExposureTime, Flash }
public sealed record SynologyPhotoConditionOption(string? Name, JsonElement Value);

/// <summary>条件正文只驻内存；保留未识别字段与引用编号，避免编辑时丢失旧规则。</summary>
public sealed class SynologyPhotoCondition
{
    public SynologyPhotoSpace Space { get; }
    public IReadOnlyDictionary<string, JsonElement> Fields { get; }
    public IReadOnlyDictionary<string, IReadOnlyList<SynologyPhotoConditionOption>> Names { get; }
    public SynologyPhotoCondition(SynologyPhotoSpace space, IReadOnlyDictionary<string, JsonElement> fields,
        IReadOnlyDictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>? names = null)
    {
        Space = space;
        Fields = new ReadOnlyDictionary<string, JsonElement>(fields.ToDictionary(pair => pair.Key, pair => pair.Value.Clone(), StringComparer.Ordinal));
        Names = new ReadOnlyDictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>((names ?? new Dictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>())
            .ToDictionary(pair => pair.Key, pair => (IReadOnlyList<SynologyPhotoConditionOption>)Array.AsReadOnly(pair.Value.Select(value => value with { Value = value.Value.Clone() }).ToArray()), StringComparer.Ordinal));
    }
    public static string Key(SynologyPhotoConditionField field) => field switch
    {
        SynologyPhotoConditionField.GeneralTag => "general_tag", SynologyPhotoConditionField.FocalLength => "focal_length_group",
        SynologyPhotoConditionField.ExposureTime => "exposure_time_group", _ => field.ToString().ToLowerInvariant(),
    };
    public static bool HasPolicy(SynologyPhotoConditionField field) => field is SynologyPhotoConditionField.Keyword or SynologyPhotoConditionField.Person or SynologyPhotoConditionField.Concept or SynologyPhotoConditionField.GeneralTag;
}
public sealed record SynologyPhotoConditionSnapshot(SynologyPhotoAlbum Album, SynologyPhotoCondition Condition, string Revision);
public sealed record SynologyPhotoFrozenAlbum(SynologyPhotoAlbum Album, SynologyPhotoCondition? RebuildCondition,
    IReadOnlyList<string> UnsupportedConditions, bool CanRebuild);
