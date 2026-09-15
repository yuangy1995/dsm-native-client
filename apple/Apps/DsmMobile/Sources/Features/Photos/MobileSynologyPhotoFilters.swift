import DsmCore
import DsmLocalization
import SwiftUI

/// 与 Mac 相同的筛选字段；小屏改为系统表单与日期选择器，不移植桌面弹出菜单。
struct MobileSynologyPhotoFilters: View {
    @Bindable var library: SynologyPhotosModel
    @State var draft: SynologyPhotoFilter
    @State private var usesDate = false
    @State private var start = Date()
    @State private var end = Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if library.isLoadingFilterOptions { ProgressView() }
                if let error = library.filterOptionsErrorMessage {
                    Section {
                        Text(error).foregroundStyle(.secondary)
                        Button(L10n.string("photos.retry")) { Task { await library.loadFilterOptions() } }.frame(minHeight: 44)
                    }
                }
                Section(L10n.string("photos.filters.content")) {
                    choices("photos.filters.type", values: [
                        .init(id: 0, name: L10n.string("photos.filters.images")),
                        .init(id: 1, name: L10n.string("photos.filters.videos"))
                    ], selection: $draft.mediaType)
                    choices("photos.category.person", values: library.options.people.map { .init(id: $0.id, name: $0.name) }, selection: $draft.personID)
                    choices("photos.category.location", values: locations, selection: $draft.locationID)
                    choices("photos.category.tags", values: library.options.tags, selection: $draft.tagID)
                    choices("photos.detail.rating", values: (0...5).map { .init(id: $0, name: $0 == 0 ? L10n.string("photos.filters.unrated") : L10n.string("photos.stars", $0)) }, selection: $draft.rating)
                }
                Section(L10n.string("photos.filters.timeSection")) {
                    Toggle(L10n.string("photos.filters.date"), isOn: $usesDate)
                    if usesDate {
                        DatePicker(L10n.string("photos.filters.from"), selection: $start, displayedComponents: .date)
                        DatePicker(L10n.string("photos.filters.to"), selection: $end, displayedComponents: .date)
                        if !datesValid {
                            Text(L10n.string("native.photos.filter.date.invalid")).foregroundStyle(.red)
                        }
                    }
                }
                Section(L10n.string("photos.filters.capture")) {
                    choices("photos.detail.camera", values: library.options.cameras, selection: $draft.cameraID)
                    choices("photos.detail.lens", values: library.options.lenses, selection: $draft.lensID)
                    Picker(L10n.string("photos.detail.focal"), selection: $draft.focalRange) {
                        Text(L10n.string("photos.filters.all")).tag(nil as SynologyPhotoFocalRange?)
                        ForEach(library.options.focalRanges, id: \.self) { range in
                            Text(focalLabel(range)).tag(Optional(range))
                        }
                    }.disabled(library.options.focalRanges.isEmpty)
                    Picker(L10n.string("photos.detail.shutter"), selection: $draft.exposureRange) {
                        Text(L10n.string("photos.filters.all")).tag(nil as SynologyPhotoExposureRange?)
                        ForEach(library.options.exposureRanges, id: \.self) { range in
                            Text(exposureLabel(range)).tag(Optional(range))
                        }
                    }.disabled(library.options.exposureRanges.isEmpty)
                    choices("photos.detail.aperture", values: library.options.apertures, selection: $draft.apertureID)
                    choices("photos.detail.iso", values: library.options.isoValues, selection: $draft.isoID)
                }
                Section {
                    Button(L10n.string("photos.filters.clear")) { draft = SynologyPhotoFilter(); usesDate = false }
                        .frame(minHeight: 44)
                }
            }
            .mobileGlassWorkspace()
            .navigationTitle(L10n.string("photos.filters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.media.close")) { dismiss() }.frame(minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("photos.filters.apply")) { apply() }.frame(minHeight: 44)
                        .disabled(!datesValid)
                }
            }
            .task {
                if let from = draft.startTime, let to = draft.endTime {
                    usesDate = true
                    start = Date(timeIntervalSince1970: Double(from))
                    end = Date(timeIntervalSince1970: Double(to))
                }
                await library.loadFilterOptions()
            }
        }
    }
    private var datesValid: Bool {
        !usesDate || Calendar(identifier: .gregorian).startOfDay(for: start) <= Calendar(identifier: .gregorian).startOfDay(for: end)
    }
    private func choices(_ key: String, values: [SynologyPhotoFilterChoice], selection: Binding<Int?>) -> some View {
        Picker(L10n.string(key), selection: selection) {
            Text(L10n.string(values.isEmpty ? "photos.filters.noOptions" : "photos.filters.all")).tag(nil as Int?)
            ForEach(values) { choice in Text(choice.name).tag(Optional(choice.id)) }
        }.disabled(values.isEmpty)
    }
    private var locations: [SynologyPhotoFilterChoice] {
        func flatten(_ entries: [SynologyPhotoLocation], parents: [String] = []) -> [SynologyPhotoFilterChoice] {
            entries.flatMap { entry in
                let path = parents + [entry.name]
                return [SynologyPhotoFilterChoice(id: entry.id, name: path.joined(separator: " / "))]
                    + flatten(entry.children, parents: path)
            }
        }
        return flatten(library.options.locations)
    }
    private func apply() {
        guard datesValid else { return }
        let calendar = Calendar(identifier: .gregorian)
        draft.startTime = usesDate ? Int(calendar.startOfDay(for: start).timeIntervalSince1970) : nil
        draft.endTime = usesDate ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)).map { Int($0.timeIntervalSince1970) - 1 } : nil
        let selected = draft
        dismiss()
        Task { await library.applyFilter(selected) }
    }
    private func focalLabel(_ range: SynologyPhotoFocalRange) -> String {
        let start = range.start.formatted(.number.locale(L10n.locale))
        let end = range.end.formatted(.number.locale(L10n.locale))
        if range.start == 0 { return L10n.string("photos.filters.focalBelow", end) }
        if range.end == 0 { return L10n.string("photos.filters.focalAbove", start) }
        return L10n.string("photos.filters.focalRange", start, end)
    }
    private func fraction(_ value: SynologyPhotoFraction) -> String {
        let numerator = value.num.formatted(.number.locale(L10n.locale))
        return value.den == 1 ? numerator : numerator + "/" + value.den.formatted(.number.locale(L10n.locale))
    }
    private func exposureLabel(_ range: SynologyPhotoExposureRange) -> String {
        if range.start.num == 0 { return L10n.string("photos.filters.exposureBelow", fraction(range.end)) }
        if range.end.num == 0 { return L10n.string("photos.filters.exposureAbove", fraction(range.start)) }
        return L10n.string("photos.filters.exposureRange", fraction(range.start), fraction(range.end))
    }
}
