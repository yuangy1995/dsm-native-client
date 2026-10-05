import DsmCore
import DsmLocalization
import SwiftUI

struct MobilePowerSettingsSummary: View {
    let value: NasServiceSettings
    var showsFilter = true
    @State private var filter = MobileNasScheduleFilter.all

    var body: some View {
        switch value {
        case .zram(let snapshot, let needsReboot):
            LabeledContent(L10n.string("zram.status-title"), value: MobileNasReadFormatting.enabled(snapshot.isEnabled))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.string("zram.status-title"))
                .accessibilityValue(MobileNasReadFormatting.enabled(snapshot.isEnabled))
                .accessibilityIdentifier("mobile.nas.zram.status")
            if let bytes = snapshot.configuredBytes { LabeledContent(L10n.string("zram.capacity-title"), value: MobileNasReadFormatting.bytes(bytes)) }
            if snapshot.algorithm != .unknown { LabeledContent(L10n.string("zram.algorithm-title"), value: MobileNasReadFormatting.algorithm(snapshot.algorithm)) }
            if needsReboot == true { Text(L10n.string("zram.edit.restart-note")).foregroundStyle(.secondary) }
            else if needsReboot == nil || snapshot.isEnabled == nil { Text(L10n.string("mobile.nas.power.compressionUnavailable")).foregroundStyle(.secondary) }
        case .powerSchedule(let snapshot):
            if showsFilter && !snapshot.entries.isEmpty {
                Picker(L10n.string("power-schedule.filter-title"), selection: $filter) {
                    ForEach(MobileNasScheduleFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("mobile.nas.powerSchedule.filter")
            }
            let entries = snapshot.entries.filter { !showsFilter || filter.includes($0.isEnabled) }
            if entries.isEmpty {
                ContentUnavailableView(L10n.string(snapshot.entries.isEmpty ? "power-schedule.empty-title" : "power-schedule.filtered-empty-title"),
                    systemImage: "calendar.badge.clock", description: Text(L10n.string(snapshot.entries.isEmpty ? "mobile.nas.power.empty" : "power-schedule.filtered-empty-description")))
                    .accessibilityIdentifier("mobile.nas.read.filteredEmpty")
            }
            ForEach(entries) { MobilePowerScheduleRow(entry: $0) }
            Text(snapshot.timeZoneIdentifier.map { L10n.string("power-schedule.time-zone", $0) }
                 ?? L10n.string("power-schedule.time-zone-unavailable")).foregroundStyle(.secondary)
            if snapshot.isTruncated { Text(L10n.string("power-schedule.truncated")).foregroundStyle(.secondary) }
            if !snapshot.canEdit { Text(L10n.string("power-schedule.edit.unavailable")).foregroundStyle(.secondary) }
        default: EmptyView()
        }
    }
}

private struct MobilePowerScheduleRow: View {
    let entry: NasPowerScheduleEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(MobileNasReadFormatting.action(entry.action), systemImage: "power").font(.headline)
            Text(MobileNasReadFormatting.time(hour: entry.hour, minute: entry.minute)).font(.title3.monospacedDigit())
            Text(MobileNasReadFormatting.recurrence(entry.recurrence))
            Text(MobileNasReadFormatting.enabled(entry.isEnabled)).foregroundStyle(.secondary)
        }.padding(.vertical, 4).accessibilityElement(children: .combine)
            .accessibilityIdentifier("mobile.nas.powerSchedule.entry")
    }
}

struct MobilePowerSettingsFields: View {
    @Binding var draft: NasServiceSettings
    let original: NasServiceSettings
    @Binding var editing: NasPowerScheduleEntry?
    @State private var filter = MobileNasScheduleFilter.all

    var body: some View {
        switch draft {
        case .zram(let value, _):
            Section {
                Toggle(L10n.string("zram.edit.enable"), isOn: Binding(get: { value.isEnabled == true }, set: {
                    draft = .zram(.init(isEnabled: $0, configuredBytes: value.configuredBytes, algorithm: value.algorithm), needsReboot: true)
                })).accessibilityIdentifier("mobile.nas.power.compression")
                Text(L10n.string("zram.edit.restart-note")).foregroundStyle(.secondary)
            }
        case .powerSchedule(let value):
            Section {
                Button(L10n.string("power-schedule.edit.add"), systemImage: "plus") {
                    editing = .init(id: UUID().uuidString, action: .startup, isEnabled: true, hour: 8, minute: 0, recurrence: .daily)
                }.disabled(value.entries.count >= 200).accessibilityIdentifier("mobile.nas.power.add")
                if !draft.hasSameConfiguration(as: original) {
                    Button(L10n.string("nas.edit.revert")) { draft = original }.accessibilityIdentifier("mobile.nas.power.revert")
                }
                Text(value.timeZoneIdentifier.map { L10n.string("power-schedule.time-zone", $0) }
                     ?? L10n.string("power-schedule.time-zone-unavailable")).foregroundStyle(.secondary)
            }
            Section {
                Picker(L10n.string("power-schedule.filter-title"), selection: $filter) {
                    ForEach(MobileNasScheduleFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("mobile.nas.power.draftFilter")
                let entries = value.entries.filter { filter.includes($0.isEnabled) }
                if entries.isEmpty {
                    ContentUnavailableView(L10n.string(value.entries.isEmpty ? "power-schedule.empty-title" : "power-schedule.filtered-empty-title"),
                        systemImage: "calendar.badge.clock", description: Text(L10n.string(value.entries.isEmpty ? "power-schedule.edit.empty" : "power-schedule.filtered-empty-description")))
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        MobilePowerScheduleRow(entry: entry)
                        Toggle(L10n.string("ui.f4f0ead1116b5b62"), isOn: Binding(get: { entry.isEnabled == true }, set: {
                            replace(.init(id: entry.id, action: entry.action, isEnabled: $0, hour: entry.hour, minute: entry.minute, recurrence: entry.recurrence))
                        })).accessibilityIdentifier("mobile.nas.power.enabled.\(entry.id)")
                        HStack {
                            Button(L10n.string("power-schedule.edit.edit")) { editing = entry }
                                .accessibilityIdentifier("mobile.nas.power.edit.\(entry.id)")
                            Button(L10n.string("power-schedule.edit.remove"), role: .destructive) { update(value.entries.filter { $0.id != entry.id }) }
                                .accessibilityIdentifier("mobile.nas.power.remove.\(entry.id)")
                        }.buttonStyle(.bordered).controlSize(.large)
                    }
                }
            }
        default: EmptyView()
        }
    }

    private func update(_ entries: [NasPowerScheduleEntry]) {
        guard case .powerSchedule(let value) = draft else { return }
        draft = .powerSchedule(.init(entries: entries, timeZoneIdentifier: value.timeZoneIdentifier, total: entries.count,
                                     isTruncated: false, supportsEditing: true))
    }
    private func replace(_ entry: NasPowerScheduleEntry) {
        guard case .powerSchedule(let value) = draft else { return }
        var entries = value.entries
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry } else { entries.append(entry) }
        update(entries)
    }
}

struct MobilePowerScheduleEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let entry: NasPowerScheduleEntry
    let onApply: (NasPowerScheduleEntry) -> Void
    @State private var startup: Bool
    @State private var enabled: Bool
    @State private var hour: Int
    @State private var minute: Int
    @State private var weekdays: Set<Int>

    init(entry: NasPowerScheduleEntry, onApply: @escaping (NasPowerScheduleEntry) -> Void) {
        self.entry = entry; self.onApply = onApply
        _startup = State(initialValue: entry.action == .startup); _enabled = State(initialValue: entry.isEnabled == true)
        _hour = State(initialValue: entry.hour); _minute = State(initialValue: entry.minute)
        _weekdays = State(initialValue: Set(entry.scheduledWeekdays ?? []))
    }
    var body: some View {
        Form {
            Section {
                Picker(L10n.string("power-schedule.edit.action"), selection: $startup) {
                    Text(L10n.string("power-schedule.action-startup")).tag(true)
                    Text(L10n.string("power-schedule.action-shutdown")).tag(false)
                }.accessibilityIdentifier("mobile.nas.power.action")
                Toggle(L10n.string("ui.f4f0ead1116b5b62"), isOn: $enabled).accessibilityIdentifier("mobile.nas.power.entryEnabled")
                Picker(L10n.string("power-schedule.edit.hour"), selection: $hour) {
                    ForEach(0..<24) { Text($0, format: .number.grouping(.never)).tag($0) }
                }.accessibilityIdentifier("mobile.nas.power.hour")
                Picker(L10n.string("power-schedule.edit.minute"), selection: $minute) {
                    ForEach(0..<60) { Text($0, format: .number.grouping(.never)).tag($0) }
                }.accessibilityIdentifier("mobile.nas.power.minute")
                Text(L10n.string("power-schedule.edit.nas-time")).foregroundStyle(.secondary)
            }
            Section {
                ForEach(NasWeekday.allCases, id: \.rawValue) { day in
                    Toggle(MobileNasReadFormatting.recurrence(.weekly([day])), isOn: Binding(
                        get: { weekdays.contains(day.rawValue % 7) }, set: {
                            if $0 { weekdays.insert(day.rawValue % 7) } else { weekdays.remove(day.rawValue % 7) }
                        })).accessibilityIdentifier("mobile.nas.power.day.\(day.rawValue % 7)")
                }
            }
        }
        .navigationTitle(L10n.string("power-schedule.edit.title")).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("mobile.nas.power.entryEditor")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string("nas.edit.cancel")) { dismiss() }.accessibilityIdentifier("mobile.nas.power.cancelEntry")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.string("nas.edit.done")) {
                    let days = NasWeekday.allCases.filter { weekdays.contains($0.rawValue % 7) }
                    onApply(.init(id: entry.id, action: startup ? .startup : .shutdown, isEnabled: enabled,
                                  hour: hour, minute: minute, recurrence: days.count == 7 ? .daily : .weekly(days)))
                }.disabled(weekdays.isEmpty).accessibilityIdentifier("mobile.nas.power.applyEntry")
            }
        }
        .environment(\.locale, L10n.locale).fillsAvailableContentArea(alignment: .topLeading)
    }
}
