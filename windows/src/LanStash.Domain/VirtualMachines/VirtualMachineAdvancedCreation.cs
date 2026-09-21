namespace LanStash.Domain;

public enum VirtualMachineOperatingSystem { Windows, Linux, Other }
public enum VirtualMachineFirmware { Legacy, Uefi }
public enum VirtualMachineBootDevice { Disk, Iso }
public sealed record VirtualMachineAdvancedCreationOptions(VirtualMachineOperatingSystem OperatingSystem, VirtualMachineFirmware Firmware,
    VirtualMachineCreationStorage Storage, VirtualMachineCreationImage? BootImage = null)
{
    public override string ToString() => nameof(VirtualMachineAdvancedCreationOptions);
}

// 高级创建使用内部存储身份，不用公开摘要中的缺失主机字段拼接请求。
public sealed record VirtualMachineCreationStorage(string Id, string Name, string HostId, string HostName,
    long AllocatedSize, string Size, string Used, string Status, string StatusType)
{
    public override string ToString() => nameof(VirtualMachineCreationStorage);
}
public sealed record VirtualMachineCreationImage(string Id, string Name, string StorageId, string HostId, string Type, string Status, string StatusType)
{
    public override string ToString() => nameof(VirtualMachineCreationImage);
}
public sealed record VirtualMachineAdvancedCreationInventory(Guid ProfileId, bool StoragesFrozen, bool ImagesFrozen,
    IReadOnlyList<VirtualMachineCreationStorage> Storages, IReadOnlyList<VirtualMachineCreationImage> Images)
{
    public override string ToString() => nameof(VirtualMachineAdvancedCreationInventory);
}
public sealed record VirtualMachineAdvancedDisk(string Id, string Size, int Controller, bool Unmap)
{
    public override string ToString() => nameof(VirtualMachineAdvancedDisk);
}
public sealed record VirtualMachineAdvancedNic(string Id, string NetworkId, string MacAddress, int Model, bool PreferSriov)
{
    public override string ToString() => nameof(VirtualMachineAdvancedNic);
}
public sealed record VirtualMachineAdvancedSettings(VirtualMachineSettings Basic, string StorageId, bool IsGeneralMachine,
    VirtualMachineFirmware Firmware, VirtualMachineBootDevice BootDevice, IReadOnlyList<string> IsoImageIds,
    string VideoCard, bool CpuPassthrough, bool HyperVEnlightenment, int ReservedCpuCount, string KeyboardLayout,
    int UsbVersion, IReadOnlyList<string> UsbIds, IReadOnlyList<VirtualMachineAdvancedDisk> Disks, IReadOnlyList<VirtualMachineAdvancedNic> Nics)
{
    public override string ToString() => nameof(VirtualMachineAdvancedSettings);
}
