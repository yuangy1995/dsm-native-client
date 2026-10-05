#if DEBUG
import DsmCore
import DsmNetwork
import Foundation

/// 仅为明确启用的隔离 UI 测试提供合成读取数据，不连接真实 NAS。
enum MobileNasReadUIFixture {
    static let apiNames = [DsmAPIName.coreExternalStorageUSB, DsmAPIName.coreExternalStorageESATA,
                           DsmAPIName.coreSystemProcess, DsmAPIName.coreSystemProcessGroup,
                           DsmAPIName.coreHardwareZRAM, DsmAPIName.coreHardwarePowerSchedule]

    static func response(api: String, method: String, state: String) -> [String: Any]? {
        let empty = state == "nas-read-empty"
        switch (api, method) {
        case (DsmAPIName.coreExternalStorageUSB, "list"):
            return ["devices": empty ? [] : [["id": "usb-sample", "display_name": "Sample USB", "status": "ready", "capacity_bytes": 4_294_967_296, "used_bytes": 1_073_741_824]], "total": empty ? 0 : 1]
        case (DsmAPIName.coreExternalStorageESATA, "list"):
            return ["devices": [], "total": 0]
        case (DsmAPIName.coreSystemProcess, "list"):
            return ["processes": empty ? [] : [["pid": "42", "name": "Sample process", "status": "running", "group_id": "sample-service"]], "total": empty ? 0 : 1]
        case (DsmAPIName.coreSystemProcessGroup, "list"):
            return ["groups": empty ? [] : [["id": "sample-service", "display_name": "Sample service", "process_count": 1]], "total": empty ? 0 : 1]
        case (DsmAPIName.coreHardwareZRAM, "get"):
            return state == "nas-read-unknown" ? [:] : ["enable_zram": true]
        case (DsmAPIName.coreHardwarePowerSchedule, "load"):
            return ["poweron_tasks": empty ? [] : [["enabled": true, "weekdays": "1,2,3,4,5", "hour": 8, "min": 15]],
                    "poweroff_tasks": empty ? [] : [["enabled": false, "weekdays": "0,6", "hour": 22, "min": 30]], "timezone": "Asia/Taipei"]
        default: return nil
        }
    }
}
#endif
