import DsmCore
import DsmLocalization
import SwiftUI

struct MobileSynologyPhotoFilters: View {
    @Bindable var model: SynologyPhotosModel
    @State var draft: SynologyPhotoFilter
    @State private var usesDate = false
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        NavigationStack {
            Form {
                if model.isLoadingFilterOptions { ProgressView() }
                if let error = model.filterOptionsErrorMessage {
                    Text(error).foregroundStyle(.secondary)
                    Button(L10n.string("photos.retry")) { Task { await model.loadFilterOptions() } }
                }
                Section(L10n.string("photos.filters.content")) {
                    choice("photos.filters.type", values: [
                        .init(id: 0, name: L10n.string("photos.filters.images")),
                        .init(id: 1, name: L10n.string("photos.filters.videos"))
                    ], selection: $draft.mediaType)
                    choice("photos.category.person", values: model.options.people.map { .init(id: $0.id, name: $0.name) }, selection: $draft.personID)
                    choice("photos.category.location", values: locations(model.options.locations), selection: $draft.locationID)
                    choice("photos.category.tags", values: model.options.tags, selection: $draft.tagID)
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
                    choice("photos.detail.camera", values: model.options.cameras, selection: $draft.cameraID)
                    choice("photos.detail.lens", values: model.options.lenses, selection: $draft.lensID)
                    Picker(L10n.string("photos.detail.focal"), selection: $draft.focalRange) {
                        Text(L10n.string("photos.filters.all")).tag(SynologyPhotoFocalRange?.none)
                        ForEach(model.options.focalRanges, id: \.self) { value in
                            Text(focal(value)).tag(Optional(value))
                        }
                    }
                    Picker(L10n.string("photos.detail.shutter"), selection: $draft.exposureRange) {
                        Text(L10n.string("photos.filters.all")).tag(SynologyPhotoExposureRange?.none)
                        ForEach(model.options.exposureRanges, id: \.self) { value in
                            Text(exposure(value)).tag(Optional(value))
                        }
                    }
                    choice("photos.detail.aperture", values: model.options.apertures, selection: $draft.apertureID)
                    choice("photos.detail.iso", values: model.options.isoValues, selection: $draft.isoID)
                }
                Button(L10n.string("photos.filters.clear")) { draft = SynologyPhotoFilter(); usesDate = false }
            }
            .navigationTitle(L10n.string("photos.filters"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.media.close")) { model.showsFilters = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("photos.filters.apply"), action: apply)
                        .disabled(usesDate && Calendar.current.startOfDay(for: start) > Calendar.current.startOfDay(for: end))
                }
            }
        }
        .task {
            if let from = draft.startTime, let to = draft.endTime {
                usesDate = true
                start = Date(timeIntervalSince1970: Double(from))
                end = Date(timeIntervalSince1970: Double(to))
            }
            await model.loadFilterOptions()
        }
    }

    private func choice(_ key: String, values: [SynologyPhotoFilterChoice], selection: Binding<Int?>) -> some View {
        Picker(L10n.string(key), selection: selection) {
            Text(L10n.string(values.isEmpty ? "photos.filters.noOptions" : "photos.filters.all")).tag(Int?.none)
            ForEach(values) { Text($0.name).tag(Optional($0.id)) }
        }.disabled(model.isLoadingFilterOptions || values.isEmpty)
    }

    private func locations(_ entries: [SynologyPhotoLocation], prefix: String = "") -> [SynologyPhotoFilterChoice] {
        entries.flatMap { entry in
            let title = prefix.isEmpty ? entry.name : prefix + " / " + entry.name
            return [.init(id: entry.id, name: title)] + locations(entry.children, prefix: title)
        }
    }

    private func focal(_ value: SynologyPhotoFocalRange) -> String {
        let from = value.start.formatted(.number.locale(L10n.locale))
        let to = value.end.formatted(.number.locale(L10n.locale))
        if value.start == 0 { return L10n.string("photos.filters.focalBelow", to) }
        if value.end == 0 { return L10n.string("photos.filters.focalAbove", from) }
        return L10n.string("photos.filters.focalRange", from, to)
    }

    private func fraction(_ value: SynologyPhotoFraction) -> String {
        let number = value.num.formatted(.number.locale(L10n.locale))
        return value.den == 1 ? number : number + "/" + value.den.formatted(.number.locale(L10n.locale))
    }

    private func exposure(_ value: SynologyPhotoExposureRange) -> String {
        if value.start.num == 0 { return L10n.string("photos.filters.exposureBelow", fraction(value.end)) }
        if value.end.num == 0 { return L10n.string("photos.filters.exposureAbove", fraction(value.start)) }
        return L10n.string("photos.filters.exposureRange", fraction(value.start), fraction(value.end))
    }

    private func apply() {
        let calendar = Calendar(identifier: .gregorian)
        draft.startTime = usesDate ? Int(calendar.startOfDay(for: start).timeIntervalSince1970) : nil
        draft.endTime = usesDate ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))
            .map { Int($0.timeIntervalSince1970) - 1 } : nil
        model.showsFilters = false
        let value = draft
        Task { await model.applyFilter(value) }
    }
}
