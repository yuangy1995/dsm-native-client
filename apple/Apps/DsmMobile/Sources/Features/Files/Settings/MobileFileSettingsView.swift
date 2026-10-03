import DsmCore
import DsmLocalization
import DsmNetwork
import SwiftUI

struct MobileFileSettingsView: View {
    let model: MobileFileSettingsModel
    let repository: DsmFileRepository
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                NavigationLink(L10n.string("files.settings.general")) { MobileFileGeneralSettingsView(model: model) }
                NavigationLink(L10n.string("files.settings.remoteAccess")) { MobileFileMountSettingsView(model: model, profileID: repository.profileID) }
                NavigationLink(L10n.string("files.settings.speed")) { MobileFileBandwidthList(model: model) }
                NavigationLink(L10n.string("files.settings.appearance")) { MobileFileThemeSettingsView(model: model) }
            }
            .navigationTitle(L10n.string("files.settings.title")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("files.common.close")) { dismiss() } } }
        }.id(model.activation).task(id: model.activation) { await model.loadAccess() }
    }
}

struct MobileFileSettingsCommit: View {
    let model: MobileFileSettingsModel
    let target: String
    let change: FileStationSettingsChange?
    let saved: @MainActor () async -> Void
    @State private var confirmation: FileStationSettingsChange?
    var body: some View {
        Section {
            if model.recoveryFailed { Text(L10n.string("mobile.file-settings.recovery-error")).foregroundStyle(.red) }
            else if model.isBlocked(target) { Text(L10n.string("mobile.file-settings.pending")).foregroundStyle(.secondary) }
            else if model.feedbackTarget == target, let feedback = model.feedback { Text(feedback).foregroundStyle(.secondary) }
            if model.access?.isAdministrator != true || model.access?.writesEnabled != true {
                Text(L10n.string(model.access?.isAdministrator == false ? "files.advanced.adminRequired" : "files.advanced.permissionUnavailable"))
                    .foregroundStyle(.secondary)
                if model.access == nil { Button(L10n.string("files.common.retry")) { Task { await model.loadAccess() } } }
            }
            if model.canReview(target) {
                Button(L10n.string("files.sharing.refresh")) { Task { if await model.refresh(target) { await saved() } } }
            } else {
                Button(L10n.string("files.settings.save")) {
                    guard let change else { return }
                    let activation = model.activation
                    if MobileFileSettingsModel.risks(change).isEmpty { Task { if await model.save(change, expectedActivation: activation) { await saved() } } }
                    else { confirmation = change }
                }.disabled(change == nil || !model.canWrite || model.isBlocked(target))
                    .accessibilityIdentifier("files.settings.save")
            }
            if model.busy { ProgressView() }
        }
        .alert(L10n.string("files.settings.confirm"), isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button(L10n.string("files.settings.save")) {
                guard let accepted = confirmation, accepted == change else { confirmation = nil; return }
                let activation = model.activation
                confirmation = nil
                Task { if await model.save(accepted, acceptedRisk: true, expectedActivation: activation) { await saved() } }
            }.accessibilityIdentifier("files.settings.confirm")
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { confirmation = nil }
        } message: {
            if let confirmation { Text(MobileFileSettingsModel.risks(confirmation).map { L10n.string($0) }.joined(separator: "\n")) }
        }
    }
}

struct MobileFileSettingsLoadError: View {
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("files.settings.loadFailed"), systemImage: "exclamationmark.triangle")
        } description: { Text(L10n.string("files.advanced.readFailed")) } actions: {
            Button(L10n.string("files.common.retry"), action: retry)
        }.fillsAvailableContentArea()
    }
}

private struct MobileFileGeneralSettingsView: View {
    let model: MobileFileSettingsModel
    @State private var baseline: FileStationSettings?
    @State private var failed = false
    var body: some View {
        Group {
            if let baseline { MobileFileGeneralSettingsForm(model: model, baseline: baseline, reload: load) }
            else if failed { MobileFileSettingsLoadError { Task { await load() } } }
            else { ProgressView(L10n.string("mobile.file-settings.loading")).fillsAvailableContentArea().accessibilityIdentifier("files.settings.loading") }
        }.navigationTitle(L10n.string("files.settings.general")).navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel(L10n.string("files.sharing.refresh")).disabled(model.busy) } }
    }
    private func load() async {
        do { let value = try await model.read { try await $0.loadFileStationSettings() }; baseline = value; failed = false }
        catch is CancellationError { }
        catch { failed = true; baseline = nil }
    }
}

private struct MobileFileGeneralSettingsForm: View {
    let model: MobileFileSettingsModel
    let baseline: FileStationSettings
    let reload: @MainActor () async -> Void
    @State private var value: FileStationSettings
    @State private var picker: Int?
    init(model: MobileFileSettingsModel, baseline: FileStationSettings, reload: @escaping @MainActor () async -> Void) {
        self.model = model; self.baseline = baseline; self.reload = reload; _value = State(initialValue: baseline)
    }
    var body: some View {
        Form {
            Group {
                Section {
                    Toggle(L10n.string("files.settings.recordTransfers"), isOn: $value.recordsTransfers)
                    Toggle(L10n.string("files.settings.defaultPermissions"), isOn: $value.usesDefaultPermissions)
                    Toggle(L10n.string("files.settings.showAccounts"), isOn: $value.showsAccounts)
                    if value.usesCustomSharingPage != nil {
                        Toggle(L10n.string("files.settings.customSharingPage"), isOn: Binding(get: { value.usesCustomSharingPage == true }, set: { value.usesCustomSharingPage = $0 }))
                    }
                }
                Section {
                    accessPicker("files.settings.sharePermission", selection: $value.sharing)
                    if value.sharing == .selected { Button(L10n.string("files.settings.chooseAccounts", value.sharingAccounts.count.formatted(.number.locale(L10n.locale)))) { picker = 0 } }
                    accessPicker("files.settings.requestPermission", selection: $value.fileRequests)
                    if value.fileRequests == .selected { Button(L10n.string("files.settings.chooseAccounts", value.requestAccounts.count.formatted(.number.locale(L10n.locale)))) { picker = 1 } }
                    LabeledContent(L10n.string("files.settings.linkLimit")) {
                        TextField(L10n.string("files.settings.linkLimit"), value: $value.defaultLinkLimit, format: .number.locale(L10n.locale))
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(minWidth: 72)
                    }
                }
                Section {
                    accessPicker("files.settings.mountPermission", selection: $value.remoteMounts, selected: false)
                    accessPicker("files.settings.isoPermission", selection: $value.isoMounts, selected: false)
                }
                Section {
                    MobileFileBandwidthPolicyPicker(value: $value.bandwidth)
                    if value.bandwidth == .scheduled {
                        NavigationLink(L10n.string("files.settings.scheduleLimit")) { MobileFileScheduleEditor(value: $value.schedule, perAccount: false) }
                    }
                }
            }.disabled(!model.canWrite || model.isBlocked("general"))
            MobileFileSettingsCommit(model: model, target: "general", change: value == baseline || !(0...999_999_999).contains(value.defaultLinkLimit)
                ? nil : .general(baseline: baseline, updated: value), saved: reload)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: baseline) { _, latest in value = latest }
        .onChange(of: value.bandwidth) { _, policy in if policy == .scheduled && value.schedule.isEmpty { value.schedule = String(repeating: "1", count: 168) } }
        .sheet(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } })) {
            MobileFilePolicyAccountPicker(model: model, selection: Binding(get: { picker == 0 ? value.sharingAccounts : value.requestAccounts }, set: {
                if picker == 0 { value.sharingAccounts = $0 } else { value.requestAccounts = $0 }
            }))
        }
    }
    private func accessPicker(_ key: String, selection: Binding<FileStationAccessScope>, selected: Bool = true) -> some View {
        Picker(L10n.string(key), selection: selection) {
            Text(L10n.string("files.settings.administrators")).tag(FileStationAccessScope.administrators)
            Text(L10n.string("files.settings.everyone")).tag(FileStationAccessScope.everyone)
            if selected { Text(L10n.string("files.settings.selectedAccounts")).tag(FileStationAccessScope.selected) }
        }
    }
}

struct MobileFileBandwidthPolicyPicker: View {
    @Binding var value: FileStationBandwidthPolicy
    var inheritedTitle: String?
    var body: some View {
        Picker(L10n.string("files.settings.speedPolicy"), selection: $value) {
            if let inheritedTitle { Text(inheritedTitle).tag(FileStationBandwidthPolicy.notConfigured) }
            Text(L10n.string("files.settings.unlimited")).tag(FileStationBandwidthPolicy.disabled)
            Text(L10n.string("files.settings.alwaysLimit")).tag(FileStationBandwidthPolicy.enabled)
            Text(L10n.string("files.settings.scheduleLimit")).tag(FileStationBandwidthPolicy.scheduled)
        }
    }
}

/// 星期顺序与共享契约一致。每行完整触控区域，辅助功能直接朗读当前策略。
struct MobileFileScheduleEditor: View {
    @Binding var value: String
    let perAccount: Bool
    @State private var day = 0
    @State private var painting: UInt8 = 49
    private var days: [String] { let formatter = DateFormatter(); formatter.locale = L10n.locale; return formatter.weekdaySymbols }
    var body: some View {
        Form {
            Section {
                Text(L10n.string("files.settings.scheduleClock")).foregroundStyle(.secondary)
                Picker(L10n.string("mobile.file-settings.day"), selection: $day) { ForEach(0..<7, id: \.self) { Text(days[$0]).tag($0) } }
                Picker(L10n.string("files.settings.paintSchedule"), selection: $painting) {
                    ForEach(Array((UInt8(48)...UInt8(perAccount ? 50 : 49))), id: \.self) { Text(title($0)).tag($0) }
                }
                Button(L10n.string("mobile.file-settings.fill-day")) { value = Self.paint(value, day: day, hour: nil, code: painting, perAccount: perAccount) }
                Button(L10n.string("files.settings.fillSchedule")) { value = String(repeating: String(UnicodeScalar(painting)), count: 168) }
            }
            if FileStationWeeklySchedule.isValid(value, perAccount: perAccount) {
                Section {
                    ForEach(0..<24, id: \.self) { hour in
                        let code = Array(value.utf8)[day * 24 + hour]
                        Button { value = Self.paint(value, day: day, hour: hour, code: painting, perAccount: perAccount) } label: {
                            HStack {
                                Text(Self.hourLabel(hour)).monospacedDigit()
                                Spacer()
                                Text(title(code)).foregroundStyle(Color.secondary)
                                Image(systemName: code == 48 ? "circle" : code == 49 ? "circle.fill" : "diamond.fill")
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.accessibilityLabel(L10n.string("files.settings.scheduleCell", days[day], hour.formatted(.number.locale(L10n.locale)), title(code)))
                            .accessibilityIdentifier("files.settings.hour.\(hour)")
                    }
                }
            }
        }.navigationTitle(L10n.string("files.settings.scheduleLimit")).navigationBarTitleDisplayMode(.inline)
    }
    private func title(_ code: UInt8) -> String { L10n.string(code == 48 ? "files.settings.unlimited" : code == 49 ? "files.settings.defaultLimit" : "files.settings.alternateLimit") }
    static func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: Date(timeIntervalSince1970: Double(hour * 3600)))
    }
    static func paint(_ value: String, day: Int, hour: Int?, code: UInt8, perAccount: Bool) -> String {
        guard FileStationWeeklySchedule.isValid(value, perAccount: perAccount), (48...(perAccount ? 50 : 49)).contains(code),
              let start = FileStationWeeklySchedule.index(day: day, hour: hour ?? 0) else { return value }
        var bytes = Array(value.utf8)
        for index in start..<(hour == nil ? start + 24 : start + 1) { bytes[index] = code }
        return String(decoding: bytes, as: UTF8.self)
    }
}
