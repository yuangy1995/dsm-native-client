import DsmCore
import DsmLocalization
import SwiftUI

struct MobileSynologyPhotoFilterView: View {
    let model: MobileSynologyPhotosModel
    @State var draft: SynologyPhotoFilter
    @State private var usesDate = false
    @State private var start = Date()
    @State private var end = Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if model.isLoadingFilterOptions { ProgressView() }
                if let error = model.filterOptionsErrorMessage {
                    Section {
                        Text(error)
                        Button(L10n.string("photos.retry")) { Task { await model.loadFilterOptions() } }
                    }
                }
                Section(L10n.string("photos.filters.content")) {
                    choice("photos.filters.type", values: [
                        .init(id: 0, name: L10n.string("photos.filters.images")),
                        .init(id: 1, name: L10n.string("photos.filters.videos"))
                    ], selection: $draft.mediaType)
                    choice("photos.category.person", values: model.options.people.map { .init(id: $0.id, name: $0.name) }, selection: $draft.personID)
                    choice("photos.category.location", values: locations, selection: $draft.locationID)
                    choice("photos.category.tags", values: model.options.tags, selection: $draft.tagID)
                    choice("photos.detail.rating", values: (0...5).map {
                        .init(id: $0, name: L10n.string($0 == 0 ? "photos.filters.unrated" : "photos.stars", $0))
                    }, selection: $draft.rating)
                }
                Section(L10n.string("photos.filters.timeSection")) {
                    Toggle(L10n.string("photos.filters.date"), isOn: $usesDate)
                    if usesDate {
                        DatePicker(L10n.string("photos.filters.from"), selection: $start, in: Date(timeIntervalSince1970: 0)..., displayedComponents: .date)
                        DatePicker(L10n.string("photos.filters.to"), selection: $end, in: Date(timeIntervalSince1970: 0)..., displayedComponents: .date)
                    }
                }
                Section(L10n.string("photos.filters.capture")) {
                    choice("photos.detail.camera", values: model.options.cameras, selection: $draft.cameraID)
                    choice("photos.detail.lens", values: model.options.lenses, selection: $draft.lensID)
                    Picker(L10n.string("photos.detail.focal"), selection: $draft.focalRange) {
                        Text(L10n.string("photos.filters.all")).tag(Optional<SynologyPhotoFocalRange>.none)
                        ForEach(model.options.focalRanges, id: \.self) { range in
                            Text(focalLabel(range)).tag(Optional(range))
                        }
                    }.disabled(model.options.focalRanges.isEmpty || model.isLoadingFilterOptions)
                    Picker(L10n.string("photos.detail.shutter"), selection: $draft.exposureRange) {
                        Text(L10n.string("photos.filters.all")).tag(Optional<SynologyPhotoExposureRange>.none)
                        ForEach(model.options.exposureRanges, id: \.self) { range in
                            Text(exposureLabel(range)).tag(Optional(range))
                        }
                    }.disabled(model.options.exposureRanges.isEmpty || model.isLoadingFilterOptions)
                    choice("photos.detail.aperture", values: model.options.apertures, selection: $draft.apertureID)
                    choice("photos.detail.iso", values: model.options.isoValues, selection: $draft.isoID)
                }
                Section {
                    Button(L10n.string("photos.filters.clear")) {
                        draft = SynologyPhotoFilter()
                        usesDate = false
                    }.frame(minHeight: 44)
                }
            }
            .navigationTitle(L10n.string("photos.filters"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.media.close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("photos.filters.apply"), action: apply)
                        .disabled(usesDate && Calendar.current.startOfDay(for: start) > Calendar.current.startOfDay(for: end))
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
    }

    private func choice(_ key: String, values: [SynologyPhotoFilterChoice], selection: Binding<Int?>) -> some View {
        Picker(L10n.string(key), selection: selection) {
            Text(L10n.string(values.isEmpty ? "photos.filters.noOptions" : "photos.filters.all")).tag(Optional<Int>.none)
            ForEach(values) { value in Text(value.name).tag(Optional(value.id)) }
        }
        .disabled(values.isEmpty || model.isLoadingFilterOptions)
        .frame(minHeight: 44)
    }

    private var locations: [SynologyPhotoFilterChoice] {
        func flatten(_ values: [SynologyPhotoLocation], parents: [String] = []) -> [SynologyPhotoFilterChoice] {
            values.flatMap { location in
                let path = parents + [location.name]
                return [SynologyPhotoFilterChoice(id: location.id, name: path.joined(separator: " / "))]
                    + flatten(location.children, parents: path)
            }
        }
        return flatten(model.options.locations)
    }

    private func focalLabel(_ range: SynologyPhotoFocalRange) -> String {
        let lower = range.start.formatted(.number.locale(L10n.locale))
        let upper = range.end.formatted(.number.locale(L10n.locale))
        if range.start == 0 { return L10n.string("photos.filters.focalBelow", upper) }
        if range.end == 0 { return L10n.string("photos.filters.focalAbove", lower) }
        return L10n.string("photos.filters.focalRange", lower, upper)
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

    private func apply() {
        var filter = draft
        let calendar = Calendar(identifier: .gregorian)
        filter.startTime = usesDate ? Int(calendar.startOfDay(for: start).timeIntervalSince1970) : nil
        filter.endTime = usesDate ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)).map { Int($0.timeIntervalSince1970) - 1 } : nil
        dismiss()
        model.navigate { await model.applyFilter(filter) }
    }
}
