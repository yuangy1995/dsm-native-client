namespace LanStash.Domain;

// 表单与提交核心共用同一确认规则，不让页面验证与实际请求分叉。
public static class NasDdnsMutationRules
{
    public static bool IsValid(NasDdnsMutationRequest request, string? password)
    {
        if (!Enum.IsDefined(request.Action) || request.ExpectedProviderIds is null) return false;
        if (request.Action == NasDdnsAction.UpdateAddress)
            return request.Baseline is null && request.Desired is null && request.ExpectedProviderIds.Count > 0 &&
                request.ExpectedProviderIds.All(StableDdnsIdentity) && request.ExpectedProviderIds.Distinct(StringComparer.Ordinal).Count() == request.ExpectedProviderIds.Count;
        if (request.ExpectedProviderIds.Count != 0) return false;
        if (request.Baseline is { } original && (!StableDdnsIdentity(original.ProviderId) || original.Id != original.ProviderId)) return false;
        if (request.Action == NasDdnsAction.Delete) return request.Baseline is not null && request.Desired is null;
        var desired = request.Desired;
        if (desired is null || !StableDdnsIdentity(desired.ProviderId) || desired.Id != desired.ProviderId ||
            request.Baseline is { } baseline && baseline.ProviderId != desired.ProviderId ||
            string.IsNullOrWhiteSpace(desired.Username) || desired.Username.Any(char.IsControl) ||
            string.IsNullOrEmpty(desired.Hostname) || desired.Hostname.Length > 253 || desired.Hostname.StartsWith('.') ||
            desired.Hostname.EndsWith('.') || desired.Hostname.Contains("..", StringComparison.Ordinal) ||
            desired.Hostname.Any(c => !(char.IsAsciiLetterOrDigit(c) || c is '.' or '-'))) return false;
        // 编辑可省略密码以保留服务端凭据；Synology 使用已记录的固定标记，不是账号密码。
        return request.Baseline is not null || desired.ProviderId == "Synology" || !string.IsNullOrEmpty(password);
    }

    private static bool StableDdnsIdentity(string? value) => !string.IsNullOrWhiteSpace(value) && !value.Any(char.IsControl);
}
