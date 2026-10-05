import DsmCore
import DsmLocalization
import SwiftUI

/// 复用共享读取结果；本页不提供弹出设备、终止进程或隐式保存动作。
struct MobileNasReadSections: View {
    @Bindable var model: MobileNasDetailsModel
    let destination: MobileNasAdministrationDestination
    var showsSectionTitle = true
    @State private var connection: NasExternalStorageConnection?
    @State private var query = ""
    @State private var scheduleFilter = MobileNasScheduleFilter.all

    var body: some View {
        switch destination {
        case .externalStorage: externalStorage
        case .processes: processes
        case .shareAccess: shareAccess
        case .zram: zram
        case .powerSchedule: powerSchedule
        default: EmptyView()
        }
    }

    private var externalStorage: some View {
        Section {
            content(model.state.externalStorage, emptyTitle: "external-storage.empty-title",
                    emptyMessage: "external-storage.empty-description") { directory in
                Picker(L10n.string("external-storage.filter-title"), selection: $connection) {
                    Text(L10n.string("external-storage.filter-all")).tag(nil as NasExternalStorageConnection?)
                    ForEach(NasExternalStorageConnection.allCases, id: \.self) { value in
                        Text(MobileNasReadFormatting.connection(value)).tag(Optional(value))
                    }
                }
                .accessibilityIdentifier("mobile.nas.externalStorage.filter")
                let devices = directory.devices.filter { connection == nil || $0.connection == connection }
                if devices.isEmpty {
                    emptyFilter(title: directory.devices.isEmpty ? "external-storage.empty-title" : "external-storage.filtered-empty-title",
                                message: directory.devices.isEmpty ? "external-storage.empty-description" : "external-storage.filtered-empty-description")
                }
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(device.displayName ?? L10n.string("external-storage.unnamed-device"), systemImage: "externaldrive")
                            .font(.headline)
                        LabeledContent(L10n.string("external-storage.filter-title"), value: MobileNasReadFormatting.connection(device.connection))
                        LabeledContent(L10n.string("mobile.nas-details.field.status"), value: MobileNasReadFormatting.storageStatus(device.status))
                        LabeledContent(L10n.string("mobile.nas-health.storage.capacity"), value: MobileNasReadFormatting.bytes(device.capacityBytes))
                        LabeledContent(L10n.string("mobile.nas-health.storage.used"), value: MobileNasReadFormatting.bytes(device.usedBytes))
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: { if showsSectionTitle { Text(destination.title) } } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("external-storage.description"))
                if let directory = model.state.externalStorage.value {
                    if directory.isTruncated { Text(L10n.string("external-storage.truncated")) }
                    if !directory.unavailableConnections.isEmpty {
                        Text(L10n.string("external-storage.partial-unavailable",
                                         directory.unavailableConnections.map(MobileNasReadFormatting.connection).joined(separator: L10n.string("external-storage.separator"))))
                    }
                }
            }
        }
    }

    private var processes: some View {
        Section {
            content(model.state.processes, emptyTitle: "processes.empty-title", emptyMessage: "processes.empty-description") { directory in
                searchField(prompt: "mobile.nas.processes.search")
                let processes = directory.processes.filter { MobileNasReadFormatting.matches(query, values: [$0.name, $0.processID, $0.status, $0.groupID]) }
                let groups = directory.groups.filter { MobileNasReadFormatting.matches(query, values: [$0.name, $0.id, $0.status]) }
                if processes.isEmpty && groups.isEmpty {
                    emptyFilter(title: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "processes.empty-title" : "processes.filtered-empty-title",
                                message: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "processes.empty-description" : "processes.filtered-empty-description")
                }
                if !groups.isEmpty {
                    Text(L10n.string("processes.groups-title")).font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.name).font(.headline)
                            if let count = group.processCount {
                                LabeledContent(L10n.string("processes.list-title"), value: count.formatted(.number.locale(L10n.locale)))
                            }
                            Text(MobileNasDetailsFormatting.nonempty(group.status)).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if !processes.isEmpty {
                    Text(L10n.string("processes.list-title")).font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(processes) { process in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(process.name).font(.headline)
                            Text(L10n.string("processes.process-id", process.processID))
                            if let group = process.groupID { Text(L10n.string("processes.group-name", group)) }
                            Text(MobileNasDetailsFormatting.nonempty(process.status)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        } header: { if showsSectionTitle { Text(destination.title) } } footer: {
            if let directory = model.state.processes.value {
                VStack(alignment: .leading, spacing: 6) {
                    if directory.isTruncated { Text(L10n.string("processes.truncated")) }
                    if directory.groupsAreUnavailable { Text(L10n.string("processes.groups-unavailable")) }
                }
            }
        }
    }

    private var shareAccess: some View {
        Section {
            content(model.state.shareAccess, emptyTitle: "share-access.empty-title", emptyMessage: "share-access.empty-description") { directory in
                searchField(prompt: "mobile.nas.shareAccess.search")
                let shares = directory.shares.filter { MobileNasReadFormatting.matches(query, values: [$0.name]) }
                if shares.isEmpty { emptyFilter(title: "mobile.nas.filter.empty", message: "mobile.nas.filter.retry") }
                ForEach(shares) { share in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(share.name, systemImage: "folder").font(.headline)
                        Text(MobileNasReadFormatting.access(share.accessLevel))
                        if share.canDelete { Text(L10n.string("share-access.can-delete")) }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: { if showsSectionTitle { Text(destination.title) } } footer: { Text(L10n.string("share-access.scope-description")) }
    }

    private var zram: some View {
        Section {
            content(model.state.zram, emptyTitle: "zram.empty-title", emptyMessage: "zram.empty-description") { value in
                LabeledContent(L10n.string("zram.status-title"), value: MobileNasReadFormatting.enabled(value.isEnabled))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.string("zram.status-title"))
                    .accessibilityValue(MobileNasReadFormatting.enabled(value.isEnabled))
                    .accessibilityIdentifier("mobile.nas.zram.status")
                if let bytes = value.configuredBytes {
                    LabeledContent(L10n.string("zram.capacity-title"), value: MobileNasReadFormatting.bytes(bytes))
                }
                if value.algorithm != .unknown {
                    LabeledContent(L10n.string("zram.algorithm-title"), value: MobileNasReadFormatting.algorithm(value.algorithm))
                }
            }
        } header: { if showsSectionTitle { Text(destination.title) } } footer: { Text(L10n.string("zram.manage-in-dsm")) }
    }

    private var powerSchedule: some View {
        Section {
            content(model.state.powerSchedule, emptyTitle: "power-schedule.empty-title", emptyMessage: "mobile.nas.powerSchedule.empty") { snapshot in
                Picker(L10n.string("power-schedule.filter-title"), selection: $scheduleFilter) {
                    ForEach(MobileNasScheduleFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .accessibilityIdentifier("mobile.nas.powerSchedule.filter")
                let entries = snapshot.entries.filter { scheduleFilter.includes($0.isEnabled) }
                if entries.isEmpty {
                    emptyFilter(title: snapshot.entries.isEmpty ? "power-schedule.empty-title" : "power-schedule.filtered-empty-title",
                                message: snapshot.entries.isEmpty ? "mobile.nas.powerSchedule.empty" : "power-schedule.filtered-empty-description")
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(MobileNasReadFormatting.action(entry.action), systemImage: "power")
                            .font(.headline)
                        Text(MobileNasReadFormatting.time(hour: entry.hour, minute: entry.minute))
                            .font(.title3.monospacedDigit())
                        Text(MobileNasReadFormatting.recurrence(entry.recurrence))
                        Text(MobileNasReadFormatting.enabled(entry.isEnabled))
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mobile.nas.powerSchedule.entry")
                }
            }
        } header: { if showsSectionTitle { Text(destination.title) } } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let snapshot = model.state.powerSchedule.value {
                    Text(snapshot.timeZoneIdentifier.map { L10n.string("power-schedule.time-zone", $0) }
                         ?? L10n.string("power-schedule.time-zone-unavailable"))
                    if snapshot.isTruncated { Text(L10n.string("power-schedule.truncated")) }
                }
                Text(L10n.string("mobile.nas.powerSchedule.manage"))
            }
        }
    }

    private func content<Value: Equatable & Sendable, Content: View>(
        _ section: MobileNasDetailsSection<Value>, emptyTitle: String, emptyMessage: String,
        @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        MobileNasDetailsSectionContent(section: section, loading: destination.loadingLabel,
            emptyTitle: L10n.string(emptyTitle), emptyMessage: L10n.string(emptyMessage),
            retry: { Task { await model.refresh(destination) } }, content: content)
    }

    private func searchField(prompt: String) -> some View {
        TextField(L10n.string(prompt), text: $query)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(minHeight: 44)
            .accessibilityIdentifier("mobile.nas.read.search")
    }

    private func emptyFilter(title: String, message: String) -> some View {
        ContentUnavailableView(L10n.string(title), systemImage: "magnifyingglass", description: Text(L10n.string(message)))
            .accessibilityIdentifier("mobile.nas.read.filteredEmpty")
    }
}

enum MobileNasScheduleFilter: CaseIterable, Hashable {
    case all, enabled, disabled

    var title: String {
        switch self {
        case .all: L10n.string("power-schedule.filter-all")
        case .enabled: L10n.string("power-schedule.filter-enabled")
        case .disabled: L10n.string("power-schedule.filter-disabled")
        }
    }

    func includes(_ enabled: Bool?) -> Bool {
        switch self {
        case .all: true
        case .enabled: enabled == true
        case .disabled: enabled == false
        }
    }
}

enum MobileNasReadFormatting {
    static func matches(_ query: String, values: [String?]) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.compactMap { $0 }.contains { $0.localizedStandardContains(query) }
    }

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return L10n.string("mobile.nas-details.value.unavailable") }
        return value.formatted(.byteCount(style: .file).locale(L10n.locale))
    }

    static func connection(_ value: NasExternalStorageConnection) -> String {
        L10n.string(value == .usb ? "external-storage.connection-usb" : "external-storage.connection-esata")
    }

    static func storageStatus(_ value: NasExternalStorageStatus) -> String {
        switch value {
        case .ready: L10n.string("external-storage.status-ready")
        case .busy: L10n.string("external-storage.status-busy")
        case .unavailable: L10n.string("external-storage.status-unavailable")
        case .unknown: L10n.string("external-storage.status-unknown")
        }
    }

    static func enabled(_ value: Bool?) -> String {
        switch value {
        case true: L10n.string("power-schedule.status-enabled")
        case false: L10n.string("power-schedule.status-disabled")
        default: L10n.string("power-schedule.status-unknown")
        }
    }

    static func algorithm(_ value: NasZRAMAlgorithm) -> String {
        switch value {
        case .lz4: L10n.string("zram.algorithm-lz4")
        case .lzo: L10n.string("zram.algorithm-lzo")
        case .zstd: L10n.string("zram.algorithm-zstd")
        case .unknown: L10n.string("zram.value-unavailable")
        }
    }

    static func access(_ value: NasShareAccessLevel) -> String {
        switch value {
        case .readWrite: L10n.string("share-access.read-write")
        case .readOnly: L10n.string("share-access.read-only")
        case .unknown: L10n.string("share-access.unknown")
        }
    }

    static func action(_ value: NasPowerScheduleAction) -> String {
        switch value {
        case .startup: L10n.string("power-schedule.action-startup")
        case .shutdown: L10n.string("power-schedule.action-shutdown")
        case .restart: L10n.string("power-schedule.action-restart")
        case .unknown: L10n.string("power-schedule.action-unknown")
        }
    }

    /// 用固定时区承载 NAS 墙上时间，仅按 App 语言格式化，不转换为设备时区。
    static func time(hour: Int, minute: Int, locale: Locale = L10n.locale) -> String {
        let formatter = wallClockFormatter(locale: locale)
        guard (0...23).contains(hour), (0...59).contains(minute),
              let date = formatter.calendar.date(from: DateComponents(timeZone: formatter.timeZone, year: 2001, month: 1, day: 1, hour: hour, minute: minute)) else {
            return L10n.string("mobile.nas-details.value.unavailable")
        }
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func recurrence(_ value: NasPowerScheduleRecurrence) -> String {
        switch value {
        case .daily: return L10n.string("power-schedule.recurrence-daily")
        case .weekly(let days):
            guard !days.isEmpty else { return L10n.string("power-schedule.recurrence-unknown") }
            return days.map(weekday)
                .joined(separator: L10n.string("power-schedule.weekday-separator"))
        case .once(let value):
            let formatter = wallClockFormatter(locale: L10n.locale)
            guard let date = formatter.calendar.date(from: DateComponents(timeZone: formatter.timeZone, year: value.year, month: value.month, day: value.day)) else {
                return L10n.string("power-schedule.recurrence-unknown")
            }
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        case .unknown: return L10n.string("power-schedule.recurrence-unknown")
        }
    }

    private static func weekday(_ day: NasWeekday) -> String {
        switch day {
        case .monday: L10n.string("power-schedule.weekday-monday")
        case .tuesday: L10n.string("power-schedule.weekday-tuesday")
        case .wednesday: L10n.string("power-schedule.weekday-wednesday")
        case .thursday: L10n.string("power-schedule.weekday-thursday")
        case .friday: L10n.string("power-schedule.weekday-friday")
        case .saturday: L10n.string("power-schedule.weekday-saturday")
        case .sunday: L10n.string("power-schedule.weekday-sunday")
        }
    }

    private static func wallClockFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
