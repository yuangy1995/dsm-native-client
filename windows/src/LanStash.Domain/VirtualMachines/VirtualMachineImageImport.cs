namespace LanStash.Domain;

public enum VirtualMachineImageType { Disk, Iso, VirtualDsm }
public enum VirtualMachineImageImportStage { Importing, VerifyReceipt, VerifyImage, Complete, Rejected }
public sealed record VirtualMachineImageImportRequest(Guid ProfileId, string Name, string SourcePath, VirtualMachineImageType Type,
    IReadOnlyList<VirtualizationResourceSummary> Storages, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(VirtualMachineImageImportRequest);
}
public sealed record VirtualMachineImageImportResult(Guid RequestId, VirtualMachineImageImportStage Stage, MutationResult Result,
    int? ProgressPercent = null, string? ImageId = null)
{
    public override string ToString() => nameof(VirtualMachineImageImportResult);
}
public static class VirtualMachineImageImportRules
{
    public static string WireType(VirtualMachineImageType type) => type switch
    { VirtualMachineImageType.Disk => "disk", VirtualMachineImageType.Iso => "iso", VirtualMachineImageType.VirtualDsm => "vdsm", _ => throw new ArgumentOutOfRangeException(nameof(type)) };
    public static bool IsValid(VirtualMachineImageImportRequest? request)
    {
        if (request is null || !Enum.IsDefined(request.Type) || string.IsNullOrWhiteSpace(request.Name) || request.Name != request.Name.Trim() ||
            request.Name.Length > 255 || request.Name.Any(char.IsControl) || string.IsNullOrEmpty(request.SourcePath) ||
            !request.SourcePath.StartsWith('/') || request.SourcePath.Contains('\\') || request.SourcePath.Any(char.IsControl) ||
            request.Storages is null || request.Storages.Count == 0) return false;
        var segments = request.SourcePath[1..].Split('/');
        if (segments.Length < 2 || segments.Any(part => part.Length == 0 || part is "." or "..")) return false;
        var ids = new HashSet<string>(StringComparer.Ordinal);
        return request.Storages.All(item => item is { Kind: VirtualizationResourceKind.Storage, Health: VirtualizationResourceHealth.Healthy } &&
            VirtualMachinePowerRules.ValidId(item.Id) && !string.IsNullOrWhiteSpace(item.Name) && ids.Add(item.Id));
    }
}
