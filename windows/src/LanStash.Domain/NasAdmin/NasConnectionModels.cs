using System.Text.Json.Serialization;

namespace LanStash.Domain;

// 原始设备/进程标识只用于内存中的预检和请求，不进入日志字符串或默认 JSON 导出。
public sealed record NasConnectionEntry(string Id, [property: JsonIgnore] string? ProcessId, [property: JsonIgnore] string? DeviceId,
    string? Account, string? Source, string? Type, string? Description, string? Protocol, string? Location,
    string? ReportedTime, bool? IsCurrent, bool? DisconnectAllowed)
{
    public bool IsAmbiguous { get; init; }
    public string TargetKey { get; init; } = "";
    public IReadOnlyList<string> IdentityKeys { get; init; } = [];
    public bool IsWeb => string.Equals(Type, "HTTP/HTTPS", StringComparison.OrdinalIgnoreCase);
    [JsonIgnore] public string? TargetIdentity => IsWeb ? DeviceId : string.IsNullOrWhiteSpace(Type) ? null : ProcessId;
    public bool CanDisconnect => !IsAmbiguous && !string.IsNullOrWhiteSpace(TargetIdentity) && DisconnectAllowed == true &&
        Account is not null && Source is not null && !string.IsNullOrWhiteSpace(Type) && (!IsWeb || Description is not null);
    public bool RequiresCurrentSessionConfirmation => IsCurrent != false;
    public override string ToString() => nameof(NasConnectionEntry);
}
public sealed record NasConnectionSnapshot(IReadOnlyList<NasConnectionEntry> Items, int? Total, bool IsComplete);
public sealed record NasConnectionDisconnectRequest(Guid ProfileId, NasConnectionEntry Baseline, Guid RequestId,
    bool RiskConfirmed, bool CurrentSessionConfirmed)
{
    public override string ToString() => nameof(NasConnectionDisconnectRequest);
}
public sealed record NasConnectionRecoveryInfo(string TargetKey, string? Account = null, string? Source = null, string? Protocol = null)
{
    public override string ToString() => nameof(NasConnectionRecoveryInfo);
}
