import DsmCore
import DsmFileFeature
import DsmLocalization
import SwiftUI

enum MobileNasStorageSelection: Identifiable {
    case disk(String), pool(String), volume(String), analysis
    var id: String {
        switch self {
        case .disk(let id): "disk:" + id
        case .pool(let id): "pool:" + id
        case .volume(let id): "volume:" + id
        case .analysis: "analysis"
        }
    }
}

struct MobileNasStorageScreen: View {
    @Bindable var model: MobileNasStorageModel
    @State private var selected: MobileNasStorageSelection?
    var body: some View {
        List { MobileNasStorageSections(model: model, onSelect: { selected = $0 }).id(model.activation) }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.string("mobile.nas-health.section.storage"))
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.refresh() }
            .task { await model.loadIfNeeded() }
            .onDisappear { model.cancelStorageRead() }
            .onChange(of: model.activation) { _, _ in selected = nil }
            .sheet(item: $selected) { selection in
                if case .analysis = selection {
                    NavigationStack { MobileNasAnalysisView(model: model) }
                } else {
                    NavigationStack {
                        Group {
                            switch selection {
                            case .disk(let id): MobileNasDiskView(model: model, diskID: id)
                            case .pool(let id): poolDetails(id)
                            case .volume(let id): volumeDetails(id)
                            case .analysis: EmptyView()
                            }
                        }
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.string("mobile.nas.logs.done")) { selected = nil }.accessibilityIdentifier("mobile.nas.storage.done")
                            }
                        }
                    }
                }
            }
            .fillsAvailableContentArea(alignment: .topLeading)
    }

    private func poolDetails(_ id: String) -> some View {
        Form {
            if let pool = model.storage.value?.pools.first(where: { $0.id == id }) {
                LabeledContent(L10n.string("mobile.nas-details.field.status"), value: MobileNasStorageFormatting.status(pool.status))
                LabeledContent(L10n.string("mobile.nas.storage.raid"), value: MobileNasDetailsFormatting.nonempty(pool.raidType))
                capacities(used: pool.usedBytes, total: pool.totalBytes)
                reportedRow("mobile.nas.storage.writable", value: pool.reportedWritable, id: "mobile.nas.pool.writable")
                LabeledContent(L10n.string("mobile.nas.storage.multipleVolumes"), value: reported(pool.supportsMultipleVolumes))
                reportedRow("mobile.nas.storage.scrubbing", value: pool.reportedScrubbing, id: "mobile.nas.pool.scrubbing")
                if let date = pool.nextScrubbingDate {
                    LabeledContent(L10n.string("mobile.nas.storage.nextScrubbing"), value: date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
                }
                ForEach(model.storage.value?.disks.filter { pool.diskIDs.contains($0.id) } ?? []) { disk in
                    LabeledContent(L10n.string("mobile.nas.storage.drive"), value: disk.name)
                }
                ForEach(model.storage.value?.disks.filter { pool.spareDiskIDs.contains($0.id) } ?? []) { disk in
                    LabeledContent(L10n.string("mobile.nas.storage.spare"), value: disk.name)
                }
            } else { Text(MobileNasStorageModel.Failure.changed.message) }
        }
        .navigationTitle(model.storage.value?.pools.first(where: { $0.id == id })?.name ?? L10n.string("mobile.nas-health.storage.pools"))
        .navigationBarTitleDisplayMode(.inline)
    }
    private func volumeDetails(_ id: String) -> some View {
        Form {
            if let volume = model.storage.value?.volumes.first(where: { $0.id == id }) {
                LabeledContent(L10n.string("mobile.nas-details.field.status"), value: MobileNasStorageFormatting.status(volume.status))
                LabeledContent(L10n.string("mobile.nas.storage.fileSystem"), value: MobileNasDetailsFormatting.nonempty(volume.fileSystem))
                capacities(used: volume.usedBytes, total: volume.totalBytes)
                LabeledContent(L10n.string("mobile.nas.storage.pool"), value: MobileNasDetailsFormatting.nonempty(model.storage.value?.pools.first(where: { $0.id == volume.poolID })?.name ?? volume.poolID))
                if let path = volume.path { LabeledContent(L10n.string("mobile.nas.storage.location"), value: path).textSelection(.enabled) }
                reportedRow("mobile.nas.storage.encrypted", value: volume.reportedEncrypted, id: "mobile.nas.volume.encrypted")
                reportedRow("mobile.nas.storage.writable", value: volume.reportedWritable, id: "mobile.nas.volume.writable")
            } else { Text(MobileNasStorageModel.Failure.changed.message) }
        }
        .navigationTitle(model.storage.value?.volumes.first(where: { $0.id == id })?.name ?? L10n.string("mobile.nas-health.storage.volumes"))
        .navigationBarTitleDisplayMode(.inline)
    }
    @ViewBuilder private func capacities(used: Int64?, total: Int64?) -> some View {
        LabeledContent(L10n.string("mobile.nas-health.storage.capacity"), value: MobileNasReadFormatting.bytes(total))
        LabeledContent(L10n.string("mobile.nas-health.storage.used"), value: MobileNasReadFormatting.bytes(used))
        let available = used.flatMap { used in total.flatMap { total in used >= 0 && total >= used ? total - used : nil } }
        LabeledContent(L10n.string("mobile.nas.storage.available"), value: MobileNasReadFormatting.bytes(available))
    }
    private func reportedRow(_ key: String, value: Bool?, id: String) -> some View {
        LabeledContent(L10n.string(key), value: reported(value))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.string(key))
            .accessibilityValue(reported(value))
            .accessibilityIdentifier(id)
    }
    private func reported(_ value: Bool?) -> String { MobileNasStorageFormatting.reported(value) }
}

struct MobileNasStorageSections: View {
    @Bindable var model: MobileNasStorageModel
    let onSelect: (MobileNasStorageSelection) -> Void

    var body: some View {
        Group {
            if let error = model.error {
                Section { Text(error.message).foregroundStyle(.secondary).accessibilityIdentifier("mobile.nas.storage.error") }
            }
            Section {
                Button(L10n.string("mobile.nas.analysis.open"), systemImage: "chart.bar.xaxis") { onSelect(.analysis) }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("mobile.nas.analysis.open")
            }
            Section {
                MobileNasDetailsSectionContent(section: model.storage,
                    loading: L10n.string("mobile.nas-health.loading.storage"),
                    emptyTitle: L10n.string("mobile.nas-health.storage.empty.title"),
                    emptyMessage: L10n.string("mobile.nas-health.storage.empty.message"),
                    retry: { Task { await model.refresh() } }) { snapshot in
                    if !snapshot.volumes.isEmpty {
                        Text(L10n.string("mobile.nas-health.storage.volumes")).font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(snapshot.volumes) { volume in
                            storageRow(volume.name, status: volume.status, size: volume.totalBytes, icon: "externaldrive.fill") { onSelect(.volume(volume.id)) }
                        }
                    }
                    if !snapshot.pools.isEmpty {
                        Text(L10n.string("mobile.nas-health.storage.pools")).font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(snapshot.pools) { pool in
                            storageRow(pool.name, status: pool.status, size: pool.totalBytes, icon: "externaldrive.badge.checkmark") { onSelect(.pool(pool.id)) }
                        }
                    }
                    if !snapshot.disks.isEmpty {
                        Text(L10n.string("mobile.nas-health.storage.drives")).font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(snapshot.disks) { disk in
                            storageRow(disk.name, status: disk.status, size: disk.totalBytes, icon: "internaldrive") { onSelect(.disk(disk.id)) }
                                .accessibilityIdentifier("mobile.nas.storage.disk.\(disk.id)")
                        }
                    }
                }
            }
            if model.recovery.failed {
                Section { Text(MobileNasStorageModel.Failure.storage.message) }
            }
            if !model.entries.isEmpty {
                Section(L10n.string("mobile.nas.disk.operations")) {
                    ForEach(model.entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.disk(for: entry)?.name ?? L10n.string("mobile.nas.disk.original"))
                                .font(.headline)
                            Text(entry.message)
                                .accessibilityIdentifier("mobile.nas.disk.activity.\(entry.phase.rawValue)")
                            Text(entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
                                .font(.caption).foregroundStyle(.secondary)
                            if entry.phase == .submitted, let disk = model.disk(for: entry) {
                                Button(L10n.string("mobile.nas.disk.refresh")) { Task { await model.refreshStatus(disk.id) } }
                                    .disabled(model.isOperating(disk))
                                    .accessibilityIdentifier("mobile.nas.disk.recover")
                            } else if !entry.isUnfinished, !model.recovery.isExecuting(entry.id) {
                                Button(L10n.string("mobile.nas.disk.removeRecord")) { model.removeRecord(entry.id) }
                            }
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                }
            }
        }
    }

    private func storageRow(_ name: String, status: String?, size: Int64?, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label(name, systemImage: icon).font(.headline).foregroundStyle(.primary)
                Text(MobileNasStorageFormatting.status(status)).foregroundStyle(.secondary)
                Text(MobileNasReadFormatting.bytes(size)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

}

private struct MobileNasDiskView: View {
    @Bindable var model: MobileNasStorageModel
    let diskID: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmation: NasDiskTestChange?
    @State private var confirmationActivation: UUID?

    private var disk: NasDisk? { model.storage.value?.disks.first { $0.id == diskID } }
    private var status: MobileNasDetailsSection<NasDiskTestStatus> { model.statuses[diskID] ?? .init() }

    var body: some View {
        Form {
            if let disk {
                Section {
                    field("mobile.nas-health.system.model", disk.model)
                    LabeledContent(L10n.string("mobile.nas-health.storage.capacity"), value: MobileNasReadFormatting.bytes(disk.totalBytes))
                    field("mobile.nas-health.system.temperature", MobileNasHealthFormatting.temperature(disk.temperatureCelsius))
                    field("mobile.nas-health.storage.smart-health", MobileNasStorageFormatting.status(disk.smartStatus))
                    if let value = disk.badSectorCount { LabeledContent(L10n.string("mobile.nas-health.storage.bad-sectors"), value: value.formatted(.number.locale(L10n.locale))) }
                    if let value = disk.estimatedLifePercent { LabeledContent(L10n.string("mobile.nas-health.storage.ssd-life"), value: (Double(value) / 100).formatted(.percent.locale(L10n.locale))) }
                }
                Section(L10n.string("mobile.nas.disk.test")) {
                    if let entry = model.entries.first(where: { $0.disk == MobileNasDiskTestStore.identity(disk) }) {
                        Text(model.isOperating(disk) ? L10n.string("mobile.nas.disk.sending") : entry.message)
                            .accessibilityIdentifier("mobile.nas.disk.operation.\(entry.phase.rawValue)")
                    }
                    if disk.supportsSmartTest {
                        MobileNasDetailsSectionContent(section: status,
                            loading: L10n.string("mobile.nas.disk.loading"),
                            emptyTitle: L10n.string("mobile.nas.disk.unavailable"),
                            emptyMessage: L10n.string("mobile.nas.disk.unavailable"),
                            retry: { Task { await model.refreshStatus(diskID) } }) { value in
                            LabeledContent(L10n.string("mobile.nas.disk.current"), value: state(value))
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(L10n.string("mobile.nas.disk.current"))
                                .accessibilityValue(state(value))
                                .accessibilityIdentifier("mobile.nas.disk.current")
                            if let progress = value.progressDescription, value.isRunning { field("mobile.nas.disk.progress", progress) }
                            if value.isHistoryAvailable {
                                field("mobile.nas.disk.lastQuick", MobileNasStorageFormatting.historyTime(value.lastQuickTest))
                                field("mobile.nas.disk.lastExtended", MobileNasStorageFormatting.historyTime(value.lastExtendedTest))
                                field("mobile.nas.disk.lastResult", MobileNasStorageFormatting.status(value.lastResult))
                            } else { Text(L10n.string("mobile.nas.disk.historyUnavailable")) }
                        }
                        Button(L10n.string("mobile.nas.disk.refresh"), systemImage: "arrow.clockwise") { Task { await model.refreshStatus(diskID) } }
                            .disabled(status.isRefreshing || model.isOperating(disk))
                            .accessibilityIdentifier("mobile.nas.disk.refresh")
                        if model.isOperating(disk) {
                            HStack { ProgressView(); Text(L10n.string("mobile.nas.disk.sending")) }
                        } else {
                            ForEach(NasDiskTestAction.allCases, id: \.self) { action in
                                if let change = model.request(action, diskID: diskID) {
                                    Button(action.title, role: action == .stop ? .destructive : nil) {
                                        confirmation = change; confirmationActivation = model.activation
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("mobile.nas.disk.\(action.rawValue)")
                                }
                            }
                            if !model.isAdministrator { Text((model.permissionError ?? .denied).message).foregroundStyle(.secondary) }
                        }
                    } else { Text(L10n.string("mobile.nas.disk.unavailable")) }
                }
                if let error = model.error, error != .pending {
                    Section { Text(error.message).accessibilityIdentifier("mobile.nas.storage.error") }
                }
                Section {
                    DisclosureGroup(L10n.string("mobile.nas.storage.more")) {
                        field("mobile.nas-details.field.status", MobileNasStorageFormatting.status(disk.status))
                        if let value = disk.vendor { field("mobile.nas.storage.vendor", value) }
                        if let value = disk.type { field("mobile.nas-health.storage.drive-type", value) }
                        if let value = disk.location { field("mobile.nas.storage.location", value) }
                        if let value = disk.usedBy { field("mobile.nas.storage.pool", model.storage.value?.pools.first(where: { $0.id == value })?.name ?? value) }
                        if let value = disk.serialNumber { field("mobile.nas.storage.serial", value) }
                        if let value = disk.firmwareVersion { field("mobile.nas.storage.firmware", value) }
                        if let value = disk.is4KNative { field("mobile.nas.storage.native4k", MobileNasStorageFormatting.reported(value)) }
                    }
                }
            } else { Text(MobileNasStorageModel.Failure.changed.message) }
        }
        .navigationTitle(disk?.name ?? L10n.string("mobile.nas.storage.drive"))
        .navigationBarTitleDisplayMode(.inline)
        .fillsAvailableContentArea(alignment: .topLeading)
        .task(id: scenePhase) {
            guard scenePhase == .active else { model.cancelStatus(diskID); return }
            await model.refreshStatus(diskID)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                guard let disk else { return }
                if status.value?.isRunning == true, !status.hasRefreshError, !model.isOperating(disk) {
                    await model.refreshStatus(diskID)
                }
            }
        }
        .onDisappear { model.cancelStatus(diskID) }
        .alert(confirmation?.action.title ?? L10n.string("mobile.nas.disk.test"), isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil; confirmationActivation = nil } }
        )) {
            if let confirmation, let token = confirmationActivation {
                Button(confirmation.action.title, role: confirmation.action == .stop ? .destructive : nil) {
                    model.perform(confirmation, activation: token)
                    self.confirmation = nil; confirmationActivation = nil
                }
                .accessibilityIdentifier("mobile.nas.disk.confirm")
            }
            Button(L10n.string("mobile.nas.disk.cancel"), role: .cancel) {
                confirmation = nil; confirmationActivation = nil
            }
            .accessibilityIdentifier("mobile.nas.disk.cancel")
        } message: { if let confirmation { Text(confirmation.action.message) } }
    }
    private func field(_ key: String, _ value: String?) -> some View {
        LabeledContent(L10n.string(key), value: MobileNasDetailsFormatting.nonempty(value))
    }
    private func state(_ value: NasDiskTestStatus) -> String {
        if value.isBusyWithOtherTest { return L10n.string("mobile.nas.disk.otherTest") }
        if value.isRunning {
            switch value.runningType {
            case .quick: return L10n.string("mobile.nas.disk.runningQuick")
            case .extended: return L10n.string("mobile.nas.disk.runningExtended")
            default: return L10n.string("mobile.nas.disk.running")
            }
        }
        return L10n.string("mobile.nas.disk.idle")
    }
}

extension NasDiskTestAction {
    var title: String {
        switch self {
        case .quick: L10n.string("mobile.nas.disk.quick")
        case .extended: L10n.string("mobile.nas.disk.extended")
        case .stop: L10n.string("mobile.nas.disk.stop")
        }
    }
    var message: String {
        switch self {
        case .quick: L10n.string("mobile.nas.disk.quickConfirm")
        case .extended: L10n.string("mobile.nas.disk.extendedConfirm")
        case .stop: L10n.string("mobile.nas.disk.stopConfirm")
        }
    }
}

extension MobileNasStorageModel.Failure {
    var message: String {
        switch self {
        case .read: L10n.string("mobile.nas.storage.readError")
        case .denied: L10n.string("mobile.nas.storage.denied")
        case .unavailable: L10n.string("mobile.nas.storage.unavailable")
        case .changed: L10n.string("mobile.nas.storage.changed")
        case .storage: L10n.string("mobile.nas.storage.localError")
        case .pending: L10n.string("mobile.nas.disk.pending")
        }
    }
}

extension MobileNasDiskTestStore.Entry {
    var message: String {
        switch phase {
        case .planned: L10n.string("mobile.nas.disk.sending")
        case .submitted: L10n.string("mobile.nas.disk.pending")
        case .cancelled: L10n.string("mobile.nas.disk.notStarted")
        case .failed:
            switch failure {
            case .denied: MobileNasStorageModel.Failure.denied.message
            case .changed: MobileNasStorageModel.Failure.changed.message
            default: MobileNasStorageModel.Failure.unavailable.message
            }
        case .succeeded:
            switch action {
            case .quick: L10n.string("mobile.nas.disk.startedQuick")
            case .extended: L10n.string("mobile.nas.disk.startedExtended")
            case .stop: L10n.string("mobile.nas.disk.stopped")
            }
        }
    }
}

enum MobileNasStorageFormatting {
    /// 沿用 Mac 已记录的存储状态；未识别值保留原文，不推断健康程度。
    static func status(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.string("mobile.nas-details.value.unavailable")
        }
        switch value.lowercased() {
        case "normal", "healthy", "good", "smart_complete": return L10n.string("ui.cfea0dce5c5d6d72")
        case "background": return L10n.string("ui.d85ff08f9141848c")
        case "attention", "warning": return L10n.string("ui.47a6e46e0880c994")
        case "not_use": return L10n.string("ui.07564e6524ba73ad")
        case "sys_partition_normal": return L10n.string("ui.c6d125d5b7100f6f")
        case "error", "failed", "critical", "abnormal": return L10n.string("ui.428fb8bfeecf7f91")
        default: return value
        }
    }

    /// 与 Mac 一致识别秒/毫秒及带时区的 ISO 时间；未知格式保留 NAS 原文，不猜时区。
    static func historyTime(_ value: String?, locale: Locale = L10n.locale) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let date: Date?
        if let timestamp = Double(value), timestamp.isFinite {
            date = Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
        } else { date = ISO8601DateFormatter().date(from: value) }
        return date?.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale)) ?? value
    }

    static func reported(_ value: Bool?) -> String {
        switch value {
        case true: L10n.string("mobile.nas.storage.yes")
        case false: L10n.string("mobile.nas.storage.no")
        default: L10n.string("mobile.nas-details.value.unavailable")
        }
    }
}
