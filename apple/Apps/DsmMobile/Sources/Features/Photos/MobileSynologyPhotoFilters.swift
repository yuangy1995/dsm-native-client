import DsmCore
import DsmLocalization
import SwiftUI

struct MobileSynologyPhotoFilters: View {
    @Bindable var library: MobileSynologyPhotosModel
    @State var draft: SynologyPhotoFilter
    @State private var usesDate = false
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        NavigationStack {
            Form {
                if library.isLoadingFilterOptions { ProgressView() }
                if let error = library.filterOptionsErrorMessage {
                    Section {
                        Text(error).foregroundStyle(.secondary)
                        Button(L10n.string("photos.retry")) { Task { await library.loadFilterOptions() } }
                    }
                }
                Section(L10n.string("photos.filters.content")) {
                    choice("photos.filters.type", values: [
                        .init(id: 0, name: L10n.string("photos.filters.images")),
                        .init(id: 1, name: L10n.string("photos.filters.videos"))
                    ], selection: $draft.mediaType)
                    choice("photos.category.person", values: library.options.people.map { .init(id: $0.id, name: $0.name) }, selection: $draft.personID)
                    choice("photos.category.location", values: locations, selection: $draft.locationID)
                    choice("photos.category.tags", values: library.options.tags, selection: $draft.tagID)
                    choice("photos.detail.rating", values: (0...5).map {
                        .init(id: $0, name: $0 == 0 ? L10n.string("photos.filters.unrated") : L10n.string("photos.stars", $0))
                    }, selection: $draft.rating)
                }
                Section(L10n.string("photos.filters.timeSection")) {
                    Toggle(L10n.string("photos.filters.date"), isOn: $usesDate)
                    if usesDate {
                        DatePicker(L10n.string("photos.filters.from"), selection: $start, displayedComponents: .date)
                        DatePicker(L10n.string("photos.filters.to"), selection: $end, displayedComponents: .date)
                    }
                }
                Section(L10n.string("photos.filters.capture")) {
                    choice("photos.detail.camera", values: library.options.cameras, selection: $draft.cameraID)
                    choice("photos.detail.lens", values: library.options.lenses, selection: $draft.lensID)
                    picker("photos.detail.focal", values: library.options.focalRanges, selection: $draft.focalRange, label: focalLabel)
                    picker("photos.detail.shutter", values: library.options.exposureRanges, selection: $draft.exposureRange, label: exposureLabel)
                    choice("photos.detail.aperture", values: library.options.apertures, selection: $draft.apertureID)
                    choice("photos.detail.iso", values: library.options.isoValues, selection: $draft.isoID)
                }
                Section {
                    Button(L10n.string("photos.filters.clear")) { draft = SynologyPhotoFilter(); usesDate = false }
                        .frame(minHeight: 44)
                }
            }
            .navigationTitle(L10n.string("photos.filters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.media.close")) { library.showsFilters = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("photos.filters.apply"), action: apply)
                        .disabled(usesDate && Calendar.current.startOfDay(for: start) > Calendar.current.startOfDay(for: end))
                }
            }
        }
        .task {
            if let from = draft.startTime, let to = draft.endTime {
                usesDate = true; start = Date(timeIntervalSince1970: Double(from)); end = Date(timeIntervalSince1970: Double(to))
            }
            await library.loadFilterOptions()
        }
    }

    private var locations: [SynologyPhotoFilterChoice] {
        func flatten(_ entries: [SynologyPhotoLocation], prefix: String = "") -> [SynologyPhotoFilterChoice] {
            entries.flatMap { entry in
                let name = prefix.isEmpty ? entry.name : prefix + " / " + entry.name
                return [.init(id: entry.id, name: name)] + flatten(entry.children, prefix: name)
            }
        }
        return flatten(library.options.locations)
    }
    private func choice(_ key: String, values: [SynologyPhotoFilterChoice], selection: Binding<Int?>) -> some View {
        picker(key, values: values.map(\.id), selection: selection) { id in
            values.first(where: { $0.id == id })?.name ?? L10n.string("photos.filters.noOptions")
        }
    }
    private func picker<Value: Hashable>(_ key: String, values: [Value], selection: Binding<Value?>,
                                        label: @escaping (Value) -> String) -> some View {
        Picker(L10n.string(key), selection: selection) {
            Text(L10n.string(values.isEmpty ? "photos.filters.noOptions" : "photos.filters.all")).tag(Optional<Value>.none)
            ForEach(values, id: \.self) { value in Text(label(value)).tag(Optional(value)) }
        }.disabled(values.isEmpty).frame(minHeight: 44)
    }
    private func focalLabel(_ range: SynologyPhotoFocalRange) -> String {
        let start = range.start.formatted(.number.locale(L10n.locale))
        let end = range.end.formatted(.number.locale(L10n.locale))
        if range.start == 0 { return L10n.string("photos.filters.focalBelow", end) }
        if range.end == 0 { return L10n.string("photos.filters.focalAbove", start) }
        return L10n.string("photos.filters.focalRange", start, end)
    }
    private func fraction(_ value: SynologyPhotoFraction) -> String {
        let num = value.num.formatted(.number.locale(L10n.locale))
        return value.den == 1 ? num : num + "/" + value.den.formatted(.number.locale(L10n.locale))
    }
    private func exposureLabel(_ range: SynologyPhotoExposureRange) -> String {
        if range.start.num == 0 { return L10n.string("photos.filters.exposureBelow", fraction(range.end)) }
        if range.end.num == 0 { return L10n.string("photos.filters.exposureAbove", fraction(range.start)) }
        return L10n.string("photos.filters.exposureRange", fraction(range.start), fraction(range.end))
    }
    private func apply() {
        var filter = draft
        let calendar = Calendar(identifier: .gregorian)
        filter.startTime = usesDate ? Int(calendar.startOfDay(for: start).timeIntervalSince1970) : nil
        filter.endTime = usesDate ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))
            .map { Int($0.timeIntervalSince1970) - 1 } : nil
        library.showsFilters = false
        Task { await library.applyFilter(filter) }
    }
}
