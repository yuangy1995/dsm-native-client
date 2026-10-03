import Foundation

public extension NasPowerScheduleEntry {
    /// DSM 的每周编码为周日 0；其余星期与 ISO 编号一致。
    var scheduledWeekdays: [Int]? {
        switch recurrence {
        case .daily: return Array(0...6)
        case .weekly(let days):
            let values = days.map { $0.rawValue % 7 }.sorted()
            return !values.isEmpty && Set(values).count == values.count ? values : nil
        case .once, .unknown: return nil
        }
    }

    var canEdit: Bool {
        (action == .startup || action == .shutdown) && isEnabled != nil
            && (0...23).contains(hour) && (0...59).contains(minute) && scheduledWeekdays != nil
    }

    /// 全表替换不依赖快照内的临时行标识，也不受返回顺序影响。
    var scheduleComparisonKey: String {
        "\(action == .startup ? 0 : 1):\(isEnabled == true):\(hour):\(minute):\(scheduledWeekdays ?? [])"
    }
}

public extension NasPowerScheduleSnapshot {
    var canEdit: Bool {
        supportsEditing && !isTruncated && total == entries.count && entries.count <= 200
            && entries.allSatisfy(\.canEdit)
    }

    func hasSameSchedule(as other: [NasPowerScheduleEntry]) -> Bool {
        canEdit && other.allSatisfy(\.canEdit)
            && entries.map(\.scheduleComparisonKey).sorted() == other.map(\.scheduleComparisonKey).sorted()
    }

    static func replacementIsValid(_ entries: [NasPowerScheduleEntry]) -> Bool {
        guard entries.count <= 200, entries.allSatisfy(\.canEdit) else { return false }
        // 官方编辑器不允许相同时间与星期重叠，即使其中一条已停用。
        var occupied = Set<String>()
        for entry in entries {
            for day in entry.scheduledWeekdays ?? [] {
                guard occupied.insert("\(day):\(entry.hour):\(entry.minute)").inserted else { return false }
            }
        }
        return true
    }
}
