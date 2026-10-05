import DsmLocalization
import SwiftUI

struct MobileNasLogsSection: View {
    @Bindable var model: MobileNasDetailsModel
    var showsSectionTitle = true
    @State private var query = ""
    @State private var level: MobileNasLogLevel?
    let onSelect: (MobileNasLogDetail) -> Void

    private var section: MobileNasDetailsSection<MobileNasLogPage> { model.state.logs }
    private var isLoading: Bool { section.phase == .loading || section.isRefreshing }

    var body: some View {
        Group {
        if let page = section.value { pagination(page) }
        Section {
            if section.value != nil {
                TextField(L10n.string("mobile.nas.logs.search"), text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("mobile.nas.logs.search")
                Picker(L10n.string("mobile.nas.logs.level"), selection: $level) {
                    Text(L10n.string("mobile.nas.logs.all")).tag(nil as MobileNasLogLevel?)
                    ForEach(MobileNasLogLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(Optional(level))
                    }
                }
                .accessibilityIdentifier("mobile.nas.logs.filter")
            }
            MobileNasDetailsSectionContent(section: section,
                loading: MobileNasAdministrationDestination.logs.loadingLabel,
                emptyTitle: L10n.string("mobile.nas-details.logs.empty.title"),
                emptyMessage: L10n.string("mobile.nas-details.logs.empty.message"),
                retry: { Task { await model.refresh(.logs) } }) { page in
                let entries = page.items.filter { item in
                    (level == nil || level == item.level)
                        && MobileNasReadFormatting.matches(query, values: [item.message, item.account, item.source])
                }
                if entries.isEmpty {
                    ContentUnavailableView(L10n.string("mobile.nas.filter.empty"), systemImage: "magnifyingglass",
                                           description: Text(L10n.string("mobile.nas.filter.retry")))
                        .accessibilityIdentifier("mobile.nas.logs.filteredEmpty")
                }
                ForEach(entries) { entry in
                    Button { onSelect(entry) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(entry.level.title, systemImage: entry.level.systemImage)
                                .font(.headline).foregroundStyle(entry.level.color)
                            Text(entry.message).lineLimit(3).foregroundStyle(.primary)
                            if let date = entry.date {
                                Text(Self.date(date)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let source = entry.source, !source.isEmpty {
                                Text(source).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mobile.nas.logs.entry.\(entry.id)")
                }
            }
        } header: {
            if showsSectionTitle { Text(MobileNasAdministrationDestination.logs.title) }
        }
        }
    }

    private func pagination(_ page: MobileNasLogPage) -> some View {
            Section {
                Picker(L10n.string("mobile.nas.logs.pageSize"), selection: Binding(
                    get: { page.limit },
                    set: { size in Task { await model.loadLogPage(1, pageSize: size) } }
                )) {
                    ForEach(MobileNasDetailsModel.logPageSizes, id: \.self) { size in
                        Text(size.formatted(.number.locale(L10n.locale))).tag(size)
                    }
                }
                .disabled(isLoading)
                .accessibilityIdentifier("mobile.nas.logs.pageSize")
                Text(page.total.flatMap { total -> String? in
                    guard page.offset == 0 || page.offset < total else { return nil }
                    return L10n.string("mobile.nas.logs.page", page.pageNumber.formatted(.number.locale(L10n.locale)),
                                max(1, total / page.limit + (total % page.limit == 0 ? 0 : 1)).formatted(.number.locale(L10n.locale)))
                } ?? L10n.string("mobile.nas.logs.pageUnknown", page.pageNumber.formatted(.number.locale(L10n.locale))))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("mobile.nas.logs.pageNumber")
                HStack {
                    Button(L10n.string("mobile.nas.logs.previous"), systemImage: "chevron.left") {
                        Task { await model.loadLogPage(page.pageNumber - 1) }
                    }
                    .disabled(isLoading || page.pageNumber <= 1)
                    .accessibilityIdentifier("mobile.nas.logs.previous")
                    Spacer(minLength: 8)
                    Button(L10n.string("mobile.nas.logs.next"), systemImage: "chevron.right") {
                        Task { await model.loadLogPage(page.pageNumber + 1) }
                    }
                    .disabled(isLoading || !page.hasNext)
                    .accessibilityIdentifier("mobile.nas.logs.next")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .labelStyle(.iconOnly)
                .frame(minHeight: 44)
            }
        }

    private static func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale))
    }
}

struct MobileNasLogDetailScreen: View {
    let entry: MobileNasLogDetail
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(L10n.string("mobile.nas.logs.level"), value: entry.level.title)
                    if let date = entry.date {
                        LabeledContent(L10n.string("mobile.nas-details.field.time"), value: date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale)))
                    }
                    if let source = entry.source, !source.isEmpty {
                        LabeledContent(L10n.string("mobile.nas-details.field.source"), value: source)
                    }
                    if let account = entry.account, !account.isEmpty {
                        LabeledContent(L10n.string("mobile.nas.logs.account"), value: account)
                    }
                }
                Section(L10n.string("mobile.nas.logs.message")) {
                    Text(entry.message).textSelection(.enabled).accessibilityIdentifier("mobile.nas.logs.message")
                }
            }
            .navigationTitle(L10n.string("mobile.nas.logs.detail"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.nas.logs.done")) { dismiss() }.accessibilityIdentifier("mobile.nas.logs.done")
                }
            }
            .fillsAvailableContentArea(alignment: .topLeading)
        }
    }
}
