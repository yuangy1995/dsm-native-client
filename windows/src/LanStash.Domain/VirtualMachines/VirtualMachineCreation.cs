namespace LanStash.Domain;

public sealed record VirtualMachineCreationDisk(int? SizeMiB, VirtualizationResourceSummary? Image = null);
public sealed record VirtualMachineCreationNetwork(VirtualizationResourceSummary? Network, string? MacAddress = null);
public sealed record VirtualMachineCreationRequest(Guid ProfileId, VirtualizationResourceSummary Storage,
    IReadOnlyList<VirtualMachineCreationDisk> Disks, IReadOnlyList<VirtualMachineCreationNetwork> Networks,
    VirtualMachineConfiguration Settings, Guid RequestId, bool RiskConfirmed)
{
    public bool PowerOnAfterCreation { get; init; }
    public VirtualMachineAdvancedCreationOptions? Advanced { get; init; }
    public override string ToString() => nameof(VirtualMachineCreationRequest);
}
// VerifyImageSource 保留旧枚举值兼容；公开克隆以确认的源 ID、同次任务结果及新资源快照核查。
public enum VirtualMachineCreationStage { Creating, Configure, VerifyConfiguration, VerifyImageSource, Complete, Rejected, VerifyReceipt, PowerOn, VerifyPower }
public sealed record VirtualMachineCreationRecovery(VirtualMachineCreationRequest Request)
{
    public override string ToString() => nameof(VirtualMachineCreationRecovery);
}
public sealed record VirtualMachineCreationResult(Guid RequestId, VirtualMachineCreationStage Stage,
    MutationResult Result, int? ProgressPercent = null, string? VirtualMachineId = null, bool CanContinue = false)
{
    public override string ToString() => nameof(VirtualMachineCreationResult);
}
public static class VirtualMachineCreationRules
{
    public static bool IsValid(VirtualMachineCreationRequest request)
    {
        if (request is null || request.Settings is not { } settings || request.Storage is not { Kind: VirtualizationResourceKind.Storage } storage ||
            !VirtualMachinePowerRules.ValidId(storage.Id) || string.IsNullOrWhiteSpace(storage.Name) ||
            request.Disks is null || request.Disks.Count is < 1 or > 8 || request.Networks is null || request.Networks.Count is < 1 or > 8 ||
            string.IsNullOrWhiteSpace(settings.Name) || settings.Name != settings.Name.Trim() || settings.Name.Length > 255 || settings.Name.Any(char.IsControl) ||
            settings.Description is null || settings.Description.Length > 1024 || settings.Description.Contains('\0') ||
            settings.CpuCount is < 1 or > 64 || settings.MemoryMiB is < 128 or > 1048576 || settings.CpuWeight is not null || !Enum.IsDefined(settings.AutoStart)) return false;
        if (request.Disks.Any(disk => disk is null || (disk.Image is null ? disk.SizeMiB is null or < 1 or > 1073741824 :
            disk.SizeMiB is not null || disk.Image.Kind != VirtualizationResourceKind.Image || disk.Image.Type != "disk" || !VirtualMachinePowerRules.ValidId(disk.Image.Id)))) return false;
        if (request.Advanced is { } advanced && (!Enum.IsDefined(advanced.OperatingSystem) || !Enum.IsDefined(advanced.Firmware) ||
            advanced.Storage is null || advanced.Storage.Id != storage.Id || advanced.Storage.Name != storage.Name ||
            !VirtualMachinePowerRules.ValidId(advanced.Storage.HostId) || string.IsNullOrWhiteSpace(advanced.Storage.HostName) ||
            request.Disks.Any(disk => disk.Image is not null || disk.SizeMiB < 10240 || disk.SizeMiB % 1024 != 0) ||
            advanced.BootImage is { } boot && (boot.Type != "iso" || !VirtualMachinePowerRules.ValidId(boot.Id)))) return false;
        var macs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var nic in request.Networks)
        {
            if (nic is null || nic.Network is { } network && (network.Kind != VirtualizationResourceKind.Network || !VirtualMachinePowerRules.ValidId(network.Id))) return false;
            if (nic.MacAddress is not null)
            {
                var parts = nic.MacAddress.Split(':');
                if (parts.Length != 6 || parts.Any(part => part.Length != 2 || !part.All(char.IsAsciiHexDigit)) ||
                    !macs.Add(nic.MacAddress) || (Convert.ToByte(parts[0], 16) & 1) != 0 || parts.All(part => part == "00")) return false;
            }
        }
        return true;
    }
}
