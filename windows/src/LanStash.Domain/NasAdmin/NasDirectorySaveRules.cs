namespace LanStash.Domain;

// 原生表单和提交核心共用字段规则，未知字段不能作为空值写回。
public static class NasDirectorySaveRules
{
    public static bool IsValid(NasDirectorySaveRequest request, string? password, string? confirmation)
    {
        if (request.Desired is not { } value || !Enum.IsDefined(request.Kind) || !ValidName(value.Name) || value.Description is null) return false;
        if (request.Baseline is { } baseline && (baseline.Kind != request.Kind || baseline.Name != value.Name || baseline.Description is null)) return false;
        if (request.Baseline is null && (value.Name != value.Name.Trim() || NasDirectoryEntry.IsReserved(request.Kind, value.Name))) return false;
        if (request.Kind == NasDirectoryKind.Group)
            return value.Email is null && value.IsExpired is null && value.Groups is null && string.IsNullOrEmpty(password) && string.IsNullOrEmpty(confirmation);
        if (value.Email is null || value.IsExpired is null || request.Baseline is { } original && (original.Email is null || original.IsExpired is null)) return false;
        if (string.IsNullOrEmpty(password) ? request.Baseline is null || !string.IsNullOrEmpty(confirmation) : password != confirmation) return false;
        if (value.Groups is not null && (value.Groups.Any(item => !ValidName(item)) || value.Groups.Distinct(StringComparer.OrdinalIgnoreCase).Count() != value.Groups.Count ||
            request.Baseline is { Groups: null })) return false;
        return true;
    }
    public static bool Matches(NasDirectoryEntry actual, NasDirectoryValues desired) => actual.Name == desired.Name &&
        actual.Description == desired.Description && (actual.Kind == NasDirectoryKind.Group ||
            actual.Email == desired.Email && actual.IsExpired == desired.IsExpired &&
            (desired.Groups is null || actual.Groups is not null && SameGroups(actual.Groups, desired.Groups)));
    public static bool SameGroups(IReadOnlyList<string> left, IReadOnlyList<string> right) =>
        left.Order(StringComparer.Ordinal).SequenceEqual(right.Order(StringComparer.Ordinal));
    private static bool ValidName(string? name) => !string.IsNullOrWhiteSpace(name) && !name.Any(char.IsControl);
}
