import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func loadStorage() async throws -> NasStorageSnapshot {
        storageReadGeneration += 1
        let generation = storageReadGeneration
        var loaded = false
        defer {
            if !loaded, generation == storageReadGeneration { cacheStorageDisks([]) }
        }
        let value = try await call(DsmAPIName.storageOverview, method: "load_info", version: 1)
        try Task.checkCancellation()
        guard generation == storageReadGeneration else { throw CancellationError() }
        guard case .array(let rawDisks) = value["disks"] else { throw verificationError(L10n.string("shared.db6b9590023d51f5")) }
        var diskIDs = Set<String>(), deviceIDs = Set<String>()
        let disks = try rawDisks.enumerated().map { index, item in
            guard case .object = item, case .string(let id) = item["id"], case .string(let device) = item["device"],
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  diskIDs.insert(id).inserted, deviceIDs.insert(device).inserted else {
                throw verificationError(L10n.string("shared.db6b9590023d51f5"))
            }
            let supportsSmartTest: Bool
            if let support = item["smart_test_support"], support != .null {
                guard case .boolean(let flag) = support else { throw verificationError(L10n.string("shared.db6b9590023d51f5")) }
                supportsSmartTest = flag
            } else { supportsSmartTest = false }
            let smartStatus = item.string(["smart_status"])
            return NasDisk(
                id: id,
                deviceID: device,
                name: item.string(["longName", "name", "device"]) ?? L10n.string("shared.c89654ab90e80308", String(describing: index + 1)),
                vendor: item.string(["vendor"]),
                model: item.string(["model"]),
                type: item.string(["diskType", "portType"]),
                totalBytes: item.integer(["size_total"]),
                status: item.string([
                    "summary_status_key",
                    "drive_status_key",
                    "overview_status",
                    "status"
                ]),
                smartStatus: smartStatus,
                temperatureCelsius: item.number(["temp"]),
                isSSD: item.boolean(["isSsd"]) ?? false,
                usedBy: item.string(["used_by", "allocation_role"]),
                supportsSmartTest: supportsSmartTest,
                serialNumber: item.string(["serial"]),
                firmwareVersion: item.string(["firm"]),
                location: item["container"]?.string(["str"]),
                is4KNative: item.boolean(["is4Kn"]),
                estimatedLifePercent: item.integer(["remain_life"]).flatMap { value in
                    value >= 0 ? Int(value) : nil
                },
                badSectorCount: item.integer(["unc"]).flatMap { value in
                    value >= 0 ? Int(value) : nil
                }
            )
        }
        cacheStorageDisks(disks)
        let pools = value.objects("storagePools").enumerated().map { index, raw in
            let item = DsmDynamicJSON.object(raw)
            let id = item.string(["id", "uuid", "num_id"]) ?? "pool-\(index)"
            let size = item["size"] ?? .object([:])
            return NasStoragePool(
                id: id,
                name: item.string(["desc", "vol_desc"]) ?? L10n.string("shared.cecdcf599fc46c06", String(describing: index + 1)),
                raidType: item.string(["raidType", "device_type"]),
                status: item.string(["summary_status", "status", "space_status"]),
                totalBytes: size.integer(["total"]),
                usedBytes: size.integer(["used"]),
                isWritable: item.boolean(["is_writable"]) ?? false,
                isScrubbing: item.boolean(["data_scrubbing", "is_actioning"]) ?? false,
                nextScrubbingDate: Self.date(from: item.string(["next_schedule_time"])),
                diskIDs: item.strings(["disks"]),
                spareDiskIDs: item.strings(["spares"]),
                supportsMultipleVolumes: item.string(["raidType"]).map { $0 != "single" }
            )
        }
        let volumes = value.objects("volumes").enumerated().map { index, raw in
            let item = DsmDynamicJSON.object(raw)
            let id = item.string(["id", "uuid", "vol_path"]) ?? "volume-\(index)"
            let size = item["size"] ?? .object([:])
            return NasVolume(
                id: id,
                name: item.string(["vol_desc", "desc", "vol_path"]) ?? L10n.string("shared.e2687545daa50cb0", String(describing: index + 1)),
                fileSystem: item.string(["fs_type"]),
                status: item.string(["summary_status", "status", "space_status"]),
                totalBytes: size.integer(["total"]),
                usedBytes: size.integer(["used"]),
                isEncrypted: item.boolean(["is_encrypted"]) ?? false,
                isWritable: item.boolean(["is_writable"]) ?? false,
                poolID: item.string(["pool_path"]),
                path: item.string(["vol_path"])
            )
        }
        loaded = true
        return NasStorageSnapshot(
            overallStatus: value["overview_data"]?.string(["status_level"])
                ?? value["env"]?.string(["status"]),
            disks: disks,
            pools: pools,
            volumes: volumes
        )
    }
}
