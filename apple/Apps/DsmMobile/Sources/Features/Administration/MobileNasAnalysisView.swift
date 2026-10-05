import Charts
import DsmCore
import DsmFileFeature
import DsmLocalization
import SwiftUI

struct MobileNasAnalysisView: View {
    @Bindable var model: MobileNasStorageModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope = Scope.shares
    @State private var query = ""

    private enum Scope: String, CaseIterable, Identifiable {
        case shares, categories, owners, large, recent, accessed, duplicates
        var id: Self { self }
        var title: String {
            switch self {
            case .shares: L10n.string("mobile.nas.analysis.shares")
            case .categories: L10n.string("mobile.nas.analysis.categories")
            case .owners: L10n.string("mobile.nas.analysis.owners")
            case .large: L10n.string("mobile.nas.analysis.large")
            case .recent: L10n.string("mobile.nas.analysis.recent")
            case .accessed: L10n.string("mobile.nas.analysis.accessed")
            case .duplicates: L10n.string("mobile.nas.analysis.duplicates")
            }
        }
    }
    private struct UsageRow: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let missing: Int
        let count: Int
    }

    var body: some View {
        List {
            Section {
                if model.isAnalyzing {
                    Text(model.analysisProgress?.title ?? L10n.string("mobile.nas.analysis.loading"))
                    if let fraction = model.analysisProgress?.fraction { ProgressView(value: fraction) }
                    else { ProgressView() }
                    Button(L10n.string("mobile.nas.analysis.cancel"), role: .cancel) { model.cancelAnalysis() }
                        .accessibilityIdentifier("mobile.nas.analysis.cancel")
                } else {
                    Button(L10n.string("mobile.nas.analysis.start"), systemImage: "chart.bar.xaxis") { model.startAnalysis() }
                        .disabled(!model.canAnalyze)
                        .accessibilityIdentifier("mobile.nas.analysis.start")
                }
                if let error = model.analysisError {
                    Text(error.message).foregroundStyle(.secondary).accessibilityIdentifier("mobile.nas.analysis.error")
                }
            }
            if let snapshot = model.analysis {
                Section {
                    LabeledContent(L10n.string("mobile.nas.analysis.files"), value: snapshot.scannedFileCount.formatted(.number.locale(L10n.locale)))
                    LabeledContent(L10n.string("mobile.nas.analysis.size"), value: size(snapshot.scannedBytes, missing: snapshot.unmeasuredFileCount))
                    if snapshot.unmeasuredFileCount > 0 {
                        Text(L10n.string("mobile.nas.analysis.incompleteSize")).foregroundStyle(.secondary)
                    }
                    LabeledContent(L10n.string("mobile.nas.analysis.date"), value: date(snapshot.generatedAt))
                }
                Section {
                    Picker(L10n.string("mobile.nas.analysis.results"), selection: $scope) {
                        ForEach(Scope.allCases) { scope in Text(scope.title).tag(scope) }
                    }
                    .accessibilityIdentifier("mobile.nas.analysis.scope")
                    if scope != .categories {
                        TextField(L10n.string("mobile.nas.analysis.search"), text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("mobile.nas.analysis.search")
                    }
                }
                switch scope {
                case .shares:
                    usage(snapshot.shares.map { .init(id: $0.id, name: $0.name, bytes: $0.usedBytes, missing: $0.unmeasuredFileCount, count: $0.fileCount) })
                case .categories:
                    usage(snapshot.categories.map { .init(id: $0.id, name: $0.name, bytes: $0.usedBytes, missing: $0.unmeasuredFileCount, count: $0.fileCount) })
                case .owners:
                    usage(snapshot.owners.map { .init(id: $0.id, name: $0.name, bytes: $0.usedBytes, missing: $0.unmeasuredFileCount, count: $0.fileCount) })
                case .large: files(snapshot.largeFiles)
                case .recent: files(snapshot.recentlyModifiedFiles)
                case .accessed: files(snapshot.leastRecentlyAccessedFiles)
                case .duplicates: duplicates(snapshot)
                }
            } else if !model.isAnalyzing && model.analysisError == nil {
                ContentUnavailableView(L10n.string("mobile.nas.analysis.empty"), systemImage: "chart.bar.xaxis",
                                       description: Text(L10n.string("mobile.nas.analysis.begin")))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.string("mobile.nas.analysis.open"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(L10n.string("mobile.nas.logs.done")) { dismiss() } }
        }
        .onChange(of: scope) { _, _ in query = "" }
        .onDisappear { model.cancelAnalysis() }
        .fillsAvailableContentArea(alignment: .topLeading)
    }

    @ViewBuilder private func usage(_ rows: [UsageRow]) -> some View {
        let rows = rows.filter { scope == .categories || MobileNasReadFormatting.matches(query, values: [$0.name]) }
        Section(scope.title) {
            if rows.isEmpty { emptyResults }
            else {
                let measured = Array(rows.filter { $0.missing == 0 }.prefix(12))
                if !measured.isEmpty {
                    Chart(measured) { row in
                        BarMark(x: .value(L10n.string("mobile.nas.analysis.size"), row.bytes),
                                y: .value(scope.title, row.name))
                    }
                    .chartXAxis { AxisMarks(format: .byteCount(style: .file).locale(L10n.locale)) }
                    .frame(height: max(160, CGFloat(measured.count) * 32))
                    .accessibilityLabel(scope.title)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.name).font(.headline).textSelection(.enabled)
                        LabeledContent(L10n.string("mobile.nas.analysis.files"), value: row.count.formatted(.number.locale(L10n.locale)))
                        LabeledContent(L10n.string("mobile.nas.analysis.size"), value: size(row.bytes, missing: row.missing))
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
    @ViewBuilder private func files(_ values: [FileItem]) -> some View {
        let values = values.filter { MobileNasReadFormatting.matches(query, values: [$0.name, $0.path]) }
        Section {
            if values.isEmpty { emptyResults }
            ForEach(values) { file in
                VStack(alignment: .leading, spacing: 6) {
                    Text(file.name).font(.headline)
                    Text(file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(MobileNasReadFormatting.bytes(file.sizeBytes))
                    if scope == .recent, let value = file.times?.modifiedAt { Text(date(value)) }
                    if scope == .accessed, let value = file.times?.accessedAt { Text(date(value)) }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        } header: { Text(scope.title) } footer: { Text(L10n.string("mobile.nas.analysis.fileLimit")) }
    }
    @ViewBuilder private func duplicates(_ snapshot: StorageAnalysisSnapshot) -> some View {
        Section {
            if snapshot.duplicateCheckWasLimited || snapshot.duplicateCheckUnavailable || snapshot.failedDuplicateChecks > 0 {
                Text(L10n.string("mobile.nas.analysis.duplicatesPartial")).foregroundStyle(.secondary)
            }
            let groups = snapshot.duplicateGroups.filter { group in
                query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || group.files.contains { MobileNasReadFormatting.matches(query, values: [$0.name, $0.path]) }
            }
            if groups.isEmpty { emptyResults }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(L10n.string("mobile.nas.analysis.duplicateSize"), value: MobileNasReadFormatting.bytes(group.reclaimableBytes))
                    ForEach(group.files) { file in
                        Text(file.path).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: { Text(scope.title) }
    }
    private var emptyResults: some View {
        ContentUnavailableView(L10n.string("mobile.nas.filter.empty"), systemImage: "doc.text.magnifyingglass",
            description: Text(query.isEmpty ? L10n.string("mobile.nas.analysis.noResults") : L10n.string("mobile.nas.filter.retry")))
            .accessibilityIdentifier("mobile.nas.analysis.emptyResults")
    }
    private func size(_ bytes: Int64, missing: Int) -> String {
        missing == 0 ? MobileNasReadFormatting.bytes(bytes) : L10n.string("mobile.nas.analysis.unknownSize")
    }
    private func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))
    }
}
