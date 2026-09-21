using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string InternalCreationTaskApi = "SYNO.Virtualization.Cluster";
    public bool CanCreateAdvancedMachine => CanCreateMachine && CanReadAdvancedCreation && HasInternalVirtualMachineVersion(InternalCreationTaskApi, 1, 1);

    private async Task<VirtualMachineCreationStorage?> ValidateAdvancedCreationResourcesAsync(VirtualMachineCreationRequest request, CancellationToken token)
    {
        var options = request.Advanced!;
        var inventory = await LoadAdvancedCreationInventoryAsync(token).ConfigureAwait(false);
        var storage = inventory.Storages.SingleOrDefault(item => item.Id == options.Storage.Id);
        if (inventory.StoragesFrozen || storage is null || storage.Name != options.Storage.Name || storage.HostId != options.Storage.HostId ||
            storage.HostName != options.Storage.HostName || storage.Status != "online" || storage.StatusType != "healthy") return null;
        if (options.BootImage is { } image && (inventory.ImagesFrozen || !inventory.Images.Any(item => item == image && item.Type == "iso" && item.StatusType != "error") ||
            VmMutations.DeletionPending.ContainsKey((ImageDeletionScope(ServiceScope()), image.Id)) || ImageImportPending(ServiceScope(), image.Id, image.Name)))
            return null;
        return storage;
    }

    private static Dictionary<string, object> AdvancedWireParameters(JsonObject value) => value.ToDictionary(pair => pair.Key,
        pair => pair.Value is JsonValue scalar && scalar.TryGetValue<string>(out var text) ? (object)text : pair.Value!);

    internal static JsonObject BuildAdvancedCreationParameters(VirtualMachineCreationRequest request, VirtualMachineCreationStorage storage)
    {
        var advanced = request.Advanced!;
        var linux = advanced.OperatingSystem == VirtualMachineOperatingSystem.Linux;
        var windows = advanced.OperatingSystem == VirtualMachineOperatingSystem.Windows;
        var usedMacs = request.Networks.Where(item => item.MacAddress is not null).Select(item => item.MacAddress!).ToHashSet(StringComparer.OrdinalIgnoreCase);
        string Mac(VirtualMachineCreationNetwork nic)
        {
            if (nic.MacAddress is not null) return nic.MacAddress;
            string mac;
            do
            {
                var bytes = RandomNumberGenerator.GetBytes(6); bytes[0] = (byte)((bytes[0] | 2) & 0xfe);
                mac = string.Join(":", bytes.Select(value => value.ToString("x2", CultureInfo.InvariantCulture)));
            } while (!usedMacs.Add(mac));
            return mac;
        }
        // 内部创建仍先保持关机，已确认的开机选项由现有电源流程在完整核查后执行。
        return JsonSerializer.SerializeToNode(new Dictionary<string, object>
        {
            ["guest_privilege"] = Array.Empty<object>(), ["iso_images"] = new[] { advanced.BootImage?.Id ?? "unmounted", "unmounted" },
            ["autorun"] = (int)request.Settings.AutoStart, ["boot_from"] = "disk", ["bios"] = advanced.Firmware == VirtualMachineFirmware.Uefi ? "uefi" : "legacy",
            ["kb_layout"] = "Default", ["usb_version"] = 0, ["usbs"] = Enumerable.Repeat("unmounted", 4).ToArray(),
            ["is_windows_vm"] = windows, ["use_ovmf"] = advanced.Firmware == VirtualMachineFirmware.Uefi,
            ["vnics"] = request.Networks.Select(nic => new Dictionary<string, object> { ["prefer_sriov"] = false, ["vnic_type"] = linux ? 1 : 2,
                ["type"] = "add", ["mac"] = Mac(nic), ["network_id"] = nic.Network?.Id ?? "" }).ToArray(),
            ["is_general_vm"] = true, ["increaseAllocatedSize"] = request.Disks.Sum(disk => (long)disk.SizeMiB!.Value / 1024),
            ["vdisks"] = request.Disks.Select((disk, index) => new Dictionary<string, object>
            {
                ["type"] = "add", ["vdisk_mode"] = linux ? 1 : 2, ["name"] = "disk-" + (index + 1).ToString(CultureInfo.InvariantCulture),
                ["unmap"] = false, ["iops_enable"] = false, ["dev_limit"] = 0, ["dev_reservation"] = 0, ["dev_weight"] = 3,
                ["vdisk_size"] = disk.SizeMiB!.Value / 1024, ["idx"] = index
            }).ToArray(), ["auto_switch"] = windows ? 1 : 0, ["vdisk_struct"] = Array.Empty<object>(),
            ["name"] = request.Settings.Name, ["vcpu_num"] = request.Settings.CpuCount, ["vram_size"] = request.Settings.MemoryMiB,
            ["video_card"] = linux ? "vmvga" : "vga", ["cpu_weight"] = 256, ["desc"] = request.Settings.Description,
            ["cpu_passthru"] = true, ["hyperv_enlighten"] = advanced.OperatingSystem != VirtualMachineOperatingSystem.Other, ["cpu_pin_num"] = 0,
            ["repo_id"] = storage.Id, ["repo_name"] = storage.Name, ["host_id"] = storage.HostId, ["repo_host_name"] = storage.HostName,
            ["allocated_size"] = storage.AllocatedSize, ["size"] = storage.Size,
            ["poweron_after_create"] = false, ["synovmm_ui_id"] = request.RequestId.ToString("D")
        })!.AsObject();
    }

    private async Task<VirtualMachineCreationResult> ReviewAdvancedCreationAsync(VirtualMachineCreationOperation pending, bool allowPower, CancellationToken token)
    {
        VirtualMachineCreationResult Unknown(VirtualMachineCreationStage stage, MutationErrorCategory category = MutationErrorCategory.Unknown) => new(pending.Request.RequestId, stage,
            new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : pending.GuestId is null ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.PartialSuccess,
                CreateVmOperation, true, true, new(pending.GuestId is null ? 0 : 1, 0, 1), category), pending.Progress, pending.GuestId);
        if (token.IsCancellationRequested) return Unknown(VirtualMachineCreationStage.Creating);
        if (!CanReadAdvancedCreation || !HasInternalVirtualMachineVersion(InternalCreationTaskApi, 1, 1)) return Unknown(VirtualMachineCreationStage.Creating, MutationErrorCategory.Unsupported);
        try
        {
            if (!pending.AdvancedTaskSucceeded)
            {
                var progress = await SecurityCallAsync(_capabilities[InternalCreationTaskApi] with { MinVersion = 1, MaxVersion = 1 }, "get_total_progress",
                    new() { ["prefix"] = "virtualization_guest" }, token).ConfigureAwait(false);
                var matches = new List<(string Id, JsonObject Task)>();
                foreach (var (host, group) in progress)
                {
                    if (host == "local_host") continue;
                    if (host == "has_fail") { if (AdvancedBool(progress, "has_fail")) throw InvalidVirtualMachineManagerResponse(); continue; }
                    if (group is not JsonObject tasks) throw InvalidVirtualMachineManagerResponse();
                    foreach (var (id, value) in tasks)
                    {
                        if (value is not JsonObject task) throw InvalidVirtualMachineManagerResponse();
                        var expectedId = pending.TaskId is not null && pending.TaskId == id;
                        var expectedContext = task["info"] is JsonObject identity && identity["param"] is JsonObject parameters &&
                            CreationText(parameters, "synovmm_ui_id") == pending.Request.RequestId.ToString("D");
                        if (expectedId || pending.TaskId is null && expectedContext) matches.Add((id, task));
                    }
                }
                if (matches.Count != 1) return Unknown(pending.TaskId is null ? VirtualMachineCreationStage.VerifyReceipt : VirtualMachineCreationStage.Creating,
                    matches.Count > 1 ? MutationErrorCategory.Conflict : MutationErrorCategory.Unknown);
                var match = matches[0]; var taskRow = match.Task;
                if (!VirtualMachinePowerRules.ValidId(match.Id) || taskRow["info"] is not JsonObject info || CreationText(info, "api") != InternalSettingsGuestApi ||
                    CreationText(info, "method") != "create" || CreationText(info, "prefix") != "virtualization_guest_create" || AdvancedNumber(info, "version") != 1 ||
                    info["param"] is not JsonObject sent || pending.AdvancedParameters is not { } expected || expected.Any(pair => !JsonNode.DeepEquals(sent[pair.Key], pair.Value)))
                    return Unknown(VirtualMachineCreationStage.VerifyReceipt, MutationErrorCategory.Conflict);
                pending.TaskId = match.Id;
                var finished = AdvancedBool(taskRow, "finish"); var succeeded = AdvancedBool(taskRow, "success");
                if (taskRow["data"] is JsonObject taskData && taskData["progress"] is JsonValue number)
                {
                    if (!number.TryGetValue<int>(out var value) || value is < 0 or > 100) throw InvalidVirtualMachineManagerResponse();
                    pending.Progress = value;
                }
                if (!finished) return Unknown(VirtualMachineCreationStage.Creating);
                if (!succeeded)
                {
                    var code = taskRow["error"] is JsonObject error && error["code"] is JsonValue raw && raw.TryGetValue<int>(out var value) ? value : (int?)null;
                    var category = code is null ? MutationErrorCategory.Server : VirtualMachinePowerError(new DsmException("", "", code));
                    return FinishVirtualMachineCreation(pending, new(pending.Request.RequestId, VirtualMachineCreationStage.Rejected,
                        new(1, MutationResultStatus.ConfirmedFailure, CreateVmOperation, true, true, new(0, 1, 0), category), pending.Progress));
                }
                var guestId = taskRow["data"] is JsonObject data ? CreationText(data, "guest_id") : null;
                if (!VirtualMachinePowerRules.ValidId(guestId) || pending.ExistingIds.Contains(guestId!) || pending.GuestId is not null && pending.GuestId != guestId)
                    return Unknown(VirtualMachineCreationStage.VerifyConfiguration, MutationErrorCategory.Conflict);
                pending.GuestId = guestId; pending.AdvancedTaskSucceeded = true;
            }
            var current = await LoadAdvancedSettingsAsync(pending.GuestId!, token).ConfigureAwait(false);
            if (!AdvancedCreationMatches(pending, current)) return Unknown(VirtualMachineCreationStage.VerifyConfiguration, MutationErrorCategory.Conflict);
            return await FinishVerifiedVirtualMachineCreationAsync(pending, current.Basic, allowPower, token).ConfigureAwait(false);
        }
        catch (DsmException error) { return Unknown(VirtualMachineCreationStage.VerifyConfiguration, VirtualMachinePowerError(error)); }
        catch { return Unknown(VirtualMachineCreationStage.VerifyConfiguration, token.IsCancellationRequested ? MutationErrorCategory.Unknown : MutationErrorCategory.Network); }
    }

    private static bool AdvancedCreationMatches(VirtualMachineCreationOperation pending, VirtualMachineAdvancedSettings current)
    {
        var request = pending.Request; var options = request.Advanced!; var expected = pending.AdvancedParameters!;
        if (current.Basic.Id != pending.GuestId || current.Basic.Configuration != request.Settings with { CpuWeight = 256 } ||
            current.StorageId != options.Storage.Id || !current.IsGeneralMachine || current.Firmware != options.Firmware || current.BootDevice != VirtualMachineBootDevice.Disk ||
            !current.IsoImageIds.SequenceEqual(new[] { options.BootImage?.Id ?? "unmounted", "unmounted" }) || current.VideoCard != CreationText(expected, "video_card") ||
            current.CpuPassthrough != AdvancedBool(expected, "cpu_passthru") || current.HyperVEnlightenment != AdvancedBool(expected, "hyperv_enlighten") || current.ReservedCpuCount != 0 ||
            current.KeyboardLayout != "Default" || current.UsbVersion != 0 || !current.UsbIds.SequenceEqual(Enumerable.Repeat("unmounted", 4)) ||
            current.Disks.Count != request.Disks.Count || current.Nics.Count != request.Networks.Count) return false;
        var mode = options.OperatingSystem == VirtualMachineOperatingSystem.Linux ? 1 : 2;
        for (var index = 0; index < current.Disks.Count; index++)
        {
            var disk = current.Disks[index];
            if (!long.TryParse(disk.Size, NumberStyles.None, CultureInfo.InvariantCulture, out var size) || size != (long)request.Disks[index].SizeMiB! * 1024 * 1024 || disk.Controller != mode || disk.Unmap) return false;
        }
        for (var index = 0; index < current.Nics.Count; index++)
        {
            var nic = current.Nics[index];
            if (nic.Model != mode || nic.PreferSriov || nic.NetworkId != (request.Networks[index].Network?.Id ?? "") ||
                !string.Equals(nic.MacAddress, CreationText(expected["vnics"]![index]!.AsObject(), "mac"), StringComparison.OrdinalIgnoreCase)) return false;
        }
        return true;
    }
}
