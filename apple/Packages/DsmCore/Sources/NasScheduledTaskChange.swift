import Foundation

public enum NasScheduledTaskAction: String, Codable, Sendable { case create, save, enable, disable, run, delete }
public enum NasScheduledTaskCheckpoint: Equatable, Sendable {
    case willSubmit(existingIDs: [Int])
    case accepted
}

/// 只承载当次确认中的内容；脚本和通知资料不能写入恢复记录。
public enum NasScheduledTaskChange: Equatable, Sendable {
    case save(task: NasScheduledTask?, original: NasScheduledTaskDraft, desired: NasScheduledTaskDraft)
    case setEnabled(task: NasScheduledTask, original: NasScheduledTaskDraft?, enabled: Bool)
    case run(task: NasScheduledTask, original: NasScheduledTaskDraft?)
    case delete(task: NasScheduledTask)

    public var action: NasScheduledTaskAction {
        switch self {
        case .save(let task, _, _): task == nil ? .create : .save
        case .setEnabled(_, _, let enabled): enabled ? .enable : .disable
        case .run: .run
        case .delete: .delete
        }
    }
    public var task: NasScheduledTask? {
        switch self { case .save(let task, _, _): task; case .setEnabled(let task, _, _), .run(let task, _), .delete(let task): task }
    }
    public var originalDraft: NasScheduledTaskDraft? {
        switch self { case .save(_, let original, _): original; case .setEnabled(_, let original, let enabled): enabled ? original : nil; case .run(_, let original): original; case .delete: nil }
    }
    public var desiredDraft: NasScheduledTaskDraft? {
        switch self {
        case .save(_, _, let desired): return desired
        case .setEnabled(_, let original, let enabled):
            guard var desired = original, enabled else { return nil }; desired.isEnabled = enabled; return desired
        case .run, .delete: return nil
        }
    }
    public var isValid: Bool {
        if let task, Int(task.id).map({ $0 >= 0 }) != true { return false }
        switch self {
        case .save(let task, let original, let desired):
            guard desired.hasValidContent, desired.schedule.selectedWeekdays != nil || task != nil && desired.schedule.weekDays == original.schedule.weekDays,
                  original.id == desired.id, original.realOwner == desired.realOwner,
                  original.schedule.preservedFields == desired.schedule.preservedFields else { return false }
            if let task {
                return task.canEdit && task.isEnabledKnown && task.type == "script" && original.matches(task)
                    && original.savedFields != desired.savedFields
            }
            return original.id == nil && desired.id == nil
        case .setEnabled(let task, let original, let enabled):
            guard task.canEdit && task.isEnabledKnown && task.type == "script" && task.isEnabled != enabled else { return false }
            return !enabled || (original?.matches(task) == true && original?.hasValidContent == true)
        case .run(let task, let original):
            guard task.canRun, let type = task.type, !type.isEmpty else { return false }
            return type != "script" || (original?.matches(task) == true && original?.hasValidContent == true)
        case .delete(let task): return task.canEdit && task.isEnabledKnown && task.type == "script"
        }
    }
    public func matches(_ tasks: [NasScheduledTask]) -> Bool {
        guard isValid else { return false }
        if let task { return tasks.first(where: { $0.id == task.id }).map { task.hasSameManagementIdentity(as: $0) } == true }
        guard let desiredDraft else { return false }
        return !tasks.contains { $0.name == desiredDraft.normalizedName && $0.owner == desiredDraft.normalizedOwner }
    }
}

public extension NasScheduledTask {
    var managementTargetFields: [String?] { [id, realOwner, name, owner, type, action] }
    /// 下一运行时间自然变化，不属于用户确认的目标身份或权限。
    func hasSameManagementIdentity(as other: NasScheduledTask) -> Bool {
        managementTargetFields == other.managementTargetFields && isEnabled == other.isEnabled
            && isEnabledKnown == other.isEnabledKnown && canRun == other.canRun && canEdit == other.canEdit
    }
}

public extension NasScheduledTaskDraft {
    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedOwner: String { owner.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValidForManagement: Bool { hasValidContent && schedule.selectedWeekdays != nil }
    var hasValidContent: Bool {
        !normalizedName.isEmpty && !normalizedOwner.isEmpty && !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !normalizedName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !normalizedOwner.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && (0...23).contains(schedule.hour) && (0...59).contains(schedule.minute)
    }
    func matches(_ task: NasScheduledTask) -> Bool {
        id == Int(task.id) && name == task.name && owner == task.owner
            && (task.realOwner == nil || task.realOwner == realOwner) && task.isEnabledKnown && isEnabled == task.isEnabled
    }
    /// selector 由目录单独校验；这里覆盖实际保存的全部内容，不包含派生运行时间。
    var savedFields: [String] {
        [normalizedName, normalizedOwner, String(isEnabled), script, String(notifyOnError), notificationEmails,
         schedule.selectedWeekdays?.sorted().map(String.init).joined(separator: ",") ?? schedule.weekDays,
         String(schedule.hour), String(schedule.minute)] + schedule.preservedFields
    }
}

public extension NasTaskSchedule {
    var selectedWeekdays: Set<Int>? {
        let tokens = weekDays.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let days = tokens.compactMap(Int.init)
        guard !days.isEmpty, days.count == tokens.count, days.allSatisfy({ (0...6).contains($0) }), Set(days).count == days.count else { return nil }
        return Set(days)
    }
    /// 移动与 Mac 同范围只编辑时分和星期，其余日期/重复设置完整保留。
    var preservedFields: [String] {
        [String(dateType), date ?? "", String(repeatDate), monthlyWeek.map(String.init).joined(separator: ","),
         String(repeatHour), String(repeatMinute), String(lastWorkHour)]
    }
}
