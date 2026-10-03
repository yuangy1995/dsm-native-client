import DsmCore
import DsmLocalization
import SwiftUI

struct PowerScheduleEntryEditor: View {
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
        _startup = State(initialValue: entry.action == .startup)
        _enabled = State(initialValue: entry.isEnabled ?? true)
        _hour = State(initialValue: entry.hour); _minute = State(initialValue: entry.minute)
        _weekdays = State(initialValue: Set(entry.scheduledWeekdays ?? Array(0...6)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("power-schedule.edit.title")).font(.title2.bold())
            Form {
                Picker(L10n.string("power-schedule.edit.action"), selection: $startup) {
                    Text(L10n.string("power-schedule.action-startup")).tag(true)
                    Text(L10n.string("power-schedule.action-shutdown")).tag(false)
                }
                Toggle(L10n.string("power-schedule.status-enabled"), isOn: $enabled)
                HStack {
                    Picker(L10n.string("power-schedule.edit.hour"), selection: $hour) {
                        ForEach(0..<24) { Text($0, format: .number).tag($0) }
                    }
                    Picker(L10n.string("power-schedule.edit.minute"), selection: $minute) {
                        ForEach(0..<60) { Text($0, format: .number).tag($0) }
                    }
                }
                Text(L10n.string("power-schedule.edit.nas-time")).foregroundStyle(.secondary)
                ForEach(NasWeekday.allCases, id: \.rawValue) { day in
                    Toggle(weekdayLabel(day), isOn: Binding(
                        get: { weekdays.contains(day.rawValue % 7) },
                        set: { selected in
                            if selected { weekdays.insert(day.rawValue % 7) }
                            else { weekdays.remove(day.rawValue % 7) }
                        }
                    ))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L10n.string("nas.edit.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("nas.edit.done")) {
                    let days = NasWeekday.allCases.filter { weekdays.contains($0.rawValue % 7) }
                    onApply(NasPowerScheduleEntry(id: entry.id, action: startup ? .startup : .shutdown,
                        isEnabled: enabled, hour: hour, minute: minute,
                        recurrence: days.count == 7 ? .daily : .weekly(days)))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(weekdays.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 610)
        .environment(\.locale, AppLanguageStore.shared.locale)
    }

    private func weekdayLabel(_ day: NasWeekday) -> String {
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
}
