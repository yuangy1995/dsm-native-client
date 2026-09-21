using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // 内部 API：2026-09-20 官方页面只读观察；不能与公开 Guest.Image/Storage 混用。
    private const string InternalCreationRepoApi = "SYNO.Virtualization.Repo";
    private const string InternalCreationImageApi = "SYNO.Virtualization.Guest.Image";
    public bool CanReadAdvancedCreation => HasAuthenticatedVirtualMachineSession &&
        HasInternalVirtualMachineVersion(InternalSettingsGuestApi, 1, 1) && HasInternalVirtualMachineVersion(InternalSettingsGuestApi, 2, 2) &&
        HasInternalVirtualMachineVersion(InternalCreationRepoApi, 2, 2) && HasInternalVirtualMachineVersion(InternalCreationImageApi, 2, 2);
    public async Task<VirtualMachineAdvancedCreationInventory> LoadAdvancedCreationInventoryAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile();
        if (!CanReadAdvancedCreation) throw UnavailableVirtualMachineManagerError();
        var repos = await SecurityCallAsync(_capabilities[InternalCreationRepoApi] with { MinVersion = 2, MaxVersion = 2 }, "list", new(), cancellationToken).ConfigureAwait(false);
        var repoFrozen = AdvancedBool(repos, "is_freeze");
        var storages = RequiredObjectArray(repos, "repos").Select(item => new VirtualMachineCreationStorage(
            AdvancedText(item, "repo_id"), AdvancedText(item, "name"), AdvancedText(item, "host_id"), AdvancedText(item, "host_name"),
            AdvancedNumber(item, "allocated_size"), AdvancedText(item, "size"), AdvancedText(item, "used"), AdvancedText(item, "status"), AdvancedText(item, "status_type"))).ToArray();
        if (storages.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() != storages.Length) throw InvalidVirtualMachineManagerResponse();
        var imagesData = await SecurityCallAsync(_capabilities[InternalCreationImageApi] with { MinVersion = 2, MaxVersion = 2 }, "list", new(), cancellationToken).ConfigureAwait(false);
        var imagesFrozen = AdvancedBool(imagesData, "is_freeze");
        var images = RequiredObjectArray(imagesData, "images").Select(item => new VirtualMachineCreationImage(
            AdvancedText(item, "id"), AdvancedText(item, "name"), AdvancedText(item, "repo_id"), AdvancedText(item, "host_id"),
            AdvancedText(item, "type"), AdvancedText(item, "status"), AdvancedText(item, "status_type"))).ToArray();
        // 同一映像可分布于多个存储，仅相同实例重复才是冲突。
        if (images.Select(item => (item.Id, item.StorageId, item.HostId)).Distinct().Count() != images.Length) throw InvalidVirtualMachineManagerResponse();
        cancellationToken.ThrowIfCancellationRequested();
        return new(_profile.Id, repoFrozen, imagesFrozen, storages, images);
    }
    public async Task<VirtualMachineAdvancedSettings> LoadAdvancedSettingsAsync(string id, CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile();
        if (!HasAuthenticatedVirtualMachineSession || !VirtualMachinePowerRules.ValidId(id)) throw InvalidVirtualMachineManagerResponse();
        if (!HasInternalVirtualMachineVersion(InternalSettingsGuestApi, 1, 1) || !HasInternalVirtualMachineVersion(InternalSettingsGuestApi, 2, 2)) throw UnavailableVirtualMachineManagerError();
        var baseline = await ReadInternalVirtualMachineSettingsAsync(id, cancellationToken).ConfigureAwait(false);
        var data = await SecurityCallAsync(_capabilities[InternalSettingsGuestApi] with { MinVersion = 1, MaxVersion = 1 }, "get_setting",
            new() { ["guest_id"] = id }, cancellationToken).ConfigureAwait(false);
        var basic = baseline.Configuration;
        if (AdvancedText(data, "name") != basic.Name || AdvancedText(data, "desc", allowEmpty: true, allowMultiline: true) != basic.Description ||
            AdvancedNumber(data, "vcpu_num") != basic.CpuCount || InternalVirtualMachineMemoryMiB(data) != basic.MemoryMiB ||
            AdvancedNumber(data, "cpu_weight") != basic.CpuWeight || AdvancedNumber(data, "autorun") != (int)basic.AutoStart)
            throw InvalidVirtualMachineManagerResponse();
        var boot = AdvancedText(data, "boot_from") switch { "disk" => VirtualMachineBootDevice.Disk, "iso" => VirtualMachineBootDevice.Iso, _ => throw InvalidVirtualMachineManagerResponse() };
        var iso = AdvancedStringArray(data, "iso_images");
        if (iso.Count != 2) throw InvalidVirtualMachineManagerResponse();
        var disks = RequiredObjectArray(data, "vdisks").Select(item => new VirtualMachineAdvancedDisk(AdvancedText(item, "vdisk_id"),
            AdvancedText(item, "size"), AdvancedInt(item, "vdisk_mode"), AdvancedBool(item, "unmap"))).ToArray();
        var nics = RequiredObjectArray(data, "vnics").Select(item => new VirtualMachineAdvancedNic(AdvancedText(item, "vnic_id"),
            AdvancedText(item, "network_id", allowEmpty: true), AdvancedText(item, "mac"), AdvancedInt(item, "vnic_type"), AdvancedBool(item, "prefer_sriov"))).ToArray();
        if (disks.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() != disks.Length || nics.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() != nics.Length)
            throw InvalidVirtualMachineManagerResponse();
        var result = new VirtualMachineAdvancedSettings(baseline, AdvancedText(data, "repo_id"), AdvancedBool(data, "is_general_vm"),
            AdvancedBool(data, "use_ovmf") ? VirtualMachineFirmware.Uefi : VirtualMachineFirmware.Legacy, boot, iso,
            AdvancedText(data, "video_card"), AdvancedBool(data, "cpu_passthru"), AdvancedBool(data, "hyperv_enlighten"), AdvancedInt(data, "cpu_pin_num"),
            AdvancedText(data, "kb_layout"), AdvancedInt(data, "usb_version"), AdvancedStringArray(data, "usbs"), disks, nics);
        // get_setting 无回显 guest_id；前后用固定 ID 的 get 核查基础身份/状态，避免拼接漂移快照。
        if (await ReadInternalVirtualMachineSettingsAsync(id, cancellationToken).ConfigureAwait(false) != baseline) throw InvalidVirtualMachineManagerResponse();
        cancellationToken.ThrowIfCancellationRequested(); return result;
    }
    private static string AdvancedText(JsonObject data, string key, bool allowEmpty = false, bool allowMultiline = false) =>
        data[key] is JsonValue node && node.TryGetValue<string>(out var text) && (allowEmpty || !string.IsNullOrWhiteSpace(text)) &&
        !text.Any(character => character == '\0' || !allowMultiline && char.IsControl(character))
            ? text : throw InvalidVirtualMachineManagerResponse();
    private static bool AdvancedBool(JsonObject data, string key) => data[key] is JsonValue node && node.TryGetValue<bool>(out var value) ? value : throw InvalidVirtualMachineManagerResponse();
    private static long AdvancedNumber(JsonObject data, string key) => data[key] is JsonValue node && node.TryGetValue<long>(out var value) && value >= 0 ? value : throw InvalidVirtualMachineManagerResponse();
    private static int AdvancedInt(JsonObject data, string key) => AdvancedNumber(data, key) is var value && value <= int.MaxValue ? (int)value : throw InvalidVirtualMachineManagerResponse();
    private static IReadOnlyList<string> AdvancedStringArray(JsonObject data, string key) => data[key] is JsonArray array ?
        array.Select(item => item is JsonValue node && node.TryGetValue<string>(out var value) && VirtualMachinePowerRules.ValidId(value) ? value : throw InvalidVirtualMachineManagerResponse()).ToArray()
        : throw InvalidVirtualMachineManagerResponse();
}
