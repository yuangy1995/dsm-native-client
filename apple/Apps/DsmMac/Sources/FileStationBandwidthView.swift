import DsmCore
import DsmLocalization
import SwiftUI

struct FileStationBandwidthView: View {
    let model: WorkspaceModel
    @State private var ownerType = FileStationBandwidthEntry.OwnerType.localUser
    @State private var rows: [FileStationBandwidthEntry] = []
    @State private var query = ""
    @State private var offset = 0
    @State private var total = 0
    @State private var loading = true
    @State private var error: String?
    @State private var selected: FileStationBandwidthEntry?
    @State private var generation = UUID()
    private var filtered: [FileStationBandwidthEntry] { rows.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(L10n.string("files.settings.accountType"), selection: $ownerType) {
                    Text(L10n.string("files.settings.localUsers")).tag(FileStationBandwidthEntry.OwnerType.localUser)
                    Text(L10n.string("files.settings.localGroups")).tag(FileStationBandwidthEntry.OwnerType.localGroup)
                    Text(L10n.string("files.settings.domainUsers")).tag(FileStationBandwidthEntry.OwnerType.domainUser)
                    Text(L10n.string("files.settings.domainGroups")).tag(FileStationBandwidthEntry.OwnerType.domainGroup)
                    Text(L10n.string("files.settings.ldapUsers")).tag(FileStationBandwidthEntry.OwnerType.ldapUser)
                    Text(L10n.string("files.settings.ldapGroups")).tag(FileStationBandwidthEntry.OwnerType.ldapGroup)
                }.labelsHidden()
                TextField(L10n.string("files.principals.search"), text: $query)
                Button(L10n.string("files.sharing.refresh")) { Task { await load(reset: true) } }.disabled(loading)
            }
            if loading && rows.isEmpty { ProgressView().fillsAvailableContentArea() }
            else if let error { FileSettingsLoadError(error: error) { Task { await load(reset: true) } } }
            else if filtered.isEmpty {
                ContentUnavailableView(L10n.string("files.principals.empty"), systemImage: "person.2",
                    description: Text(query.isEmpty ? L10n.string("files.settings.noAccounts") : L10n.string("files.principals.emptyDetail")))
                    .fillsAvailableContentArea()
            } else {
                List(filtered) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        Text(row.policy == .notConfigured ? unconfiguredBandwidthTitle(row.ownerType)
                            : row.policy == .disabled ? L10n.string("files.settings.unlimited") : row.policy == .scheduled
                            ? L10n.string("files.settings.scheduleLimit") : L10n.string("files.settings.alwaysLimit"))
                            .foregroundStyle(.secondary)
                        Button(L10n.string("files.settings.editLimit")) { selected = row }
                    }
                }
            }
            if offset < total { Button(L10n.string("files.principals.more")) { Task { await load(reset: false) } }.disabled(loading) }
        }.padding(16).task(id: ownerType) { await load(reset: true) }
            .sheet(item: $selected, onDismiss: { Task { await load(reset: true) } }) { FileStationBandwidthEditor(model: model, baseline: $0) }
            .onDisappear { generation = UUID() }
    }
    private func load(reset: Bool) async {
        let token: UUID
        if reset { token = UUID(); generation = token; rows = []; offset = 0; total = 0 }
        else { guard !loading else { return }; token = generation }
        loading = true; error = nil
        do {
            let page = try await model.listFileStationBandwidth(ownerType: ownerType, offset: offset)
            guard token == generation, !Task.isCancelled else { return }
            let ids = Set(rows.map(\.id)); rows += page.items.filter { !ids.contains($0.id) }; offset = page.nextOffset; total = page.total
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.settings.loadFailed")
        }
        loading = false
    }
}

private func unconfiguredBandwidthTitle(_ ownerType: FileStationBandwidthEntry.OwnerType) -> String {
    switch ownerType {
    case .localUser, .ldapUser, .domainUser: L10n.string("files.settings.groupBandwidth")
    case .localGroup, .ldapGroup, .domainGroup: L10n.string("files.settings.noBandwidthConfiguration")
    }
}

struct FileStationBandwidthEditor: View {
    let model: WorkspaceModel
    let baseline: FileStationBandwidthEntry
    @Environment(\.dismiss) private var dismiss
    @State private var value: FileStationBandwidthEntry
    @State private var locked = false
    init(model: WorkspaceModel, baseline: FileStationBandwidthEntry) {
        self.model = model; self.baseline = baseline; _value = State(initialValue: baseline)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("files.settings.editLimit")).font(.title2.bold())
            Text(baseline.name).textSelection(.enabled)
            Form {
                Picker(L10n.string("files.settings.speedPolicy"), selection: $value.policy) {
                    if baseline.policy == .notConfigured {
                        Text(unconfiguredBandwidthTitle(baseline.ownerType)).tag(FileStationBandwidthPolicy.notConfigured)
                    }
                    Text(L10n.string("files.settings.unlimited")).tag(FileStationBandwidthPolicy.disabled)
                    Text(L10n.string("files.settings.alwaysLimit")).tag(FileStationBandwidthPolicy.enabled)
                    Text(L10n.string("files.settings.scheduleLimit")).tag(FileStationBandwidthPolicy.scheduled)
                }
                if value.policy == .enabled || value.policy == .scheduled {
                    Text(L10n.string("files.settings.rateUnits")).foregroundStyle(.secondary)
                    TextField(L10n.string("files.settings.uploadLimit"), value: $value.uploadLimit, format: .number.locale(L10n.locale))
                    TextField(L10n.string("files.settings.downloadLimit"), value: $value.downloadLimit, format: .number.locale(L10n.locale))
                }
                if value.policy == .scheduled {
                    TextField(L10n.string("files.settings.alternateUpload"), value: $value.alternateUploadLimit, format: .number.locale(L10n.locale))
                    TextField(L10n.string("files.settings.alternateDownload"), value: $value.alternateDownloadLimit, format: .number.locale(L10n.locale))
                    FileStationScheduleEditor(value: $value.schedule, perAccount: true)
                }
            }.formStyle(.grouped).disabled(locked)
            if !validRates { Text(L10n.string("files.settings.invalidRate")).foregroundStyle(.red) }
            FileSettingsCommitControls(model: model, change: !validRates || value == baseline || value.policy == .notConfigured
                ? nil : .bandwidth(baseline: baseline, updated: value), locked: $locked)
            Button(L10n.string("files.common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 760, height: 680)
            .onChange(of: value.policy) { _, policy in
                if policy == .scheduled && value.schedule.isEmpty { value.schedule = String(repeating: "1", count: 168) }
            }
    }
    private var validRates: Bool {
        [value.uploadLimit, value.downloadLimit, value.alternateUploadLimit, value.alternateDownloadLimit].allSatisfy { $0 == 0 || (10...999_999_999).contains($0) }
    }
}

struct FileStationScheduleEditor: View {
    @Binding var value: String
    let perAccount: Bool
    @State private var painting: UInt8 = 49
    private var days: [String] {
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        return formatter.shortWeekdaySymbols
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("files.settings.scheduleClock")).font(.caption).foregroundStyle(.secondary)
            Picker(L10n.string("files.settings.paintSchedule"), selection: $painting) {
                Text(L10n.string("files.settings.unlimited")).tag(UInt8(48))
                Text(L10n.string("files.settings.defaultLimit")).tag(UInt8(49))
                if perAccount { Text(L10n.string("files.settings.alternateLimit")).tag(UInt8(50)) }
            }.pickerStyle(.segmented).labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            if FileStationWeeklySchedule.isValid(value, perAccount: perAccount) {
                ScrollView(.horizontal) {
                    Grid(horizontalSpacing: 2, verticalSpacing: 4) {
                        GridRow {
                            Color.clear.frame(width: 40, height: 12)
                            ForEach(0..<24, id: \.self) { hour in
                                Text(hour.formatted(.number.locale(L10n.locale))).font(.caption2).frame(width: 21)
                            }
                        }
                        ForEach(0..<7, id: \.self) { day in
                            GridRow {
                                Text(days[day]).font(.caption).frame(width: 40, alignment: .leading)
                                ForEach(0..<24, id: \.self) { hour in cell(day: day, hour: hour) }
                            }
                        }
                    }
                }
                Button(L10n.string("files.settings.fillSchedule")) { value = String(repeating: String(UnicodeScalar(painting)), count: 168) }
            }
        }
    }
    private func cell(day: Int, hour: Int) -> some View {
        let index = day * 24 + hour
        let byte = Array(value.utf8)[index]
        let title = byte == 48 ? L10n.string("files.settings.unlimited") : byte == 49
            ? L10n.string("files.settings.defaultLimit") : L10n.string("files.settings.alternateLimit")
        return Button {
            var bytes = Array(value.utf8); bytes[index] = painting; value = String(decoding: bytes, as: UTF8.self)
        } label: {
            Text(byte == 48 ? "○" : byte == 49 ? "●" : "◆")
                .font(.caption).frame(width: 21, height: 24)
                .background(byte == 48 ? Color.secondary.opacity(0.12) : byte == 49 ? Color.accentColor.opacity(0.25) : Color.orange.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 3))
        }.buttonStyle(.plain)
            .accessibilityLabel(L10n.string("files.settings.scheduleCell", days[day], hour.formatted(.number.locale(L10n.locale)), title))
            .help(title)
    }
}
