import DsmCore
import DsmLocalization
import Foundation
import SwiftUI

struct FileSortMenu: View {
    @Binding var sortOrder: [KeyPathComparator<FileItem>]

    var body: some View {
        Menu {
            Picker(L10n.string("workspace.sort.title"), selection: Binding(
                get: { FileSortCriterion.resolve(sortOrder.first) },
                set: { criterion in sortOrder = [criterion.comparator(order: sortOrder.first?.order ?? .forward)] }
            )) {
                ForEach(FileSortCriterion.allCases) { criterion in
                    Text(criterion.title).tag(criterion)
                }
            }
            Divider()
            Picker(L10n.string("workspace.sort.direction"), selection: Binding(
                get: { sortOrder.first?.order == .reverse },
                set: { reversed in
                    sortOrder = [FileSortCriterion.resolve(sortOrder.first).comparator(order: reversed ? .reverse : .forward)]
                }
            )) {
                Text(L10n.string("workspace.sort.ascending")).tag(false)
                Text(L10n.string("workspace.sort.descending")).tag(true)
            }
        } label: {
            Text(FileSortCriterion.resolve(sortOrder.first).title)
        }
        .menuStyle(.borderlessButton)
        .tint(.primary)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help(L10n.string("workspace.sort.title"))
    }
}

/// 两处下载菜单使用同一组选择规则，保留单文件、文件夹和批量下载的既有语义。
struct FileDownloadActions: View {
    let items: [FileItem]
    let onDownload: (FileItem, WorkspaceModel.FolderDownloadMode) -> Void
    let onDownloadBatch: ([FileItem]) -> Void

    var body: some View {
        if items.count > 1 {
            Button(L10n.string("ui.b97cad08035a15e2")) { onDownloadBatch(items) }
        } else if let item = items.first {
            if item.isDirectory {
                Button(L10n.string("ui.f956089b945b92cf")) { onDownload(item, .archive) }
                Button(L10n.string("ui.0f50ddf3fa8bb870")) { onDownload(item, .directory) }
            } else {
                Button(L10n.string("ui.29610562f4b1c377")) { onDownload(item, .archive) }
            }
        } else {
            Button(L10n.string("ui.4673a23061656125")) {}
                .disabled(true)
        }
    }
}

struct FileSelectionActionBar<MoreActions: View>: View {
    let items: [FileItem]
    let onDownload: (FileItem, WorkspaceModel.FolderDownloadMode) -> Void
    let onDownloadBatch: ([FileItem]) -> Void
    let onShare: ([FileItem]) -> Void
    let onClear: () -> Void
    @ViewBuilder let moreActions: () -> MoreActions
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(compact: false).frame(minWidth: 520)
            controls(compact: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background {
            MacGlassSurface(role: .selectionBar)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased).edge, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("workspace.selectionBar")
        .tint(.primary)
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 16) {
            Text(L10n.string("workspace.selection.count", items.count))
                .font(.system(size: 14))
                .lineLimit(1)
                .fixedSize()
            Divider().frame(height: 18)
            Group {
                Menu {
                    FileDownloadActions(items: items, onDownload: onDownload, onDownloadBatch: onDownloadBatch)
                } label: {
                    Label(L10n.string("ui.4673a23061656125"), systemImage: "arrow.down.to.line")
                }
                .help(L10n.string("ui.4673a23061656125"))
                .accessibilityLabel(L10n.string("ui.4673a23061656125"))
                Button { onShare(items) } label: {
                    Label(L10n.string("ui.7e564575eb7d5eb2"), systemImage: "square.and.arrow.up")
                }
                .help(L10n.string("ui.7e564575eb7d5eb2"))
                .accessibilityLabel(L10n.string("ui.7e564575eb7d5eb2"))
                Menu(content: moreActions) {
                    Label(L10n.string("workspace.actions.more"), systemImage: "ellipsis")
                }
                .help(L10n.string("workspace.actions.more"))
                .accessibilityLabel(L10n.string("workspace.actions.more"))
            }
            .labelStyle(AdaptiveFileActionLabelStyle(compact: compact))
            .buttonStyle(.borderless)
            Button(action: onClear) {
                Label(L10n.string("workspace.selection.clear"), systemImage: "xmark")
                    .labelStyle(AdaptiveFileActionLabelStyle(compact: compact))
            }
            .buttonStyle(.borderless)
            .help(L10n.string("workspace.selection.clear"))
        }
    }
}

private struct AdaptiveFileActionLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 6) { configuration.icon; configuration.title }
                .fixedSize()
        }
    }
}

struct FileSelectionInspector: View {
    let items: [FileItem]
    let profileName: String
    let onShowProperties: (FileItem) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.string("workspace.inspector.selection"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .accessibilityAddTraits(.isHeader)
            if items.isEmpty {
                ContentUnavailableView(
                    L10n.string("workspace.inspector.empty.title"),
                    systemImage: "cursorarrow.click.2",
                    description: Text(L10n.string("workspace.inspector.empty.detail"))
                )
                .fillsAvailableContentArea()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Spacer()
                            if let item = items.first {
                                ZStack {
                                    if items.count > 1 {
                                        FileLargeIcon(item: item)
                                            .frame(width: 86, height: 78)
                                            .offset(x: -26, y: -5)
                                    }
                                    FileLargeIcon(item: item)
                                        .frame(width: 86, height: 78)
                                        .offset(x: items.count > 1 ? 22 : 0)
                                }
                                .frame(height: 100)
                            }
                            Spacer()
                        }
                        .padding(.top, 8)
                        Text(items.count == 1 ? items[0].name : L10n.string(items.allSatisfy(\.isDirectory) ? "workspace.inspector.folderCount" : "workspace.selection.count", items.count))
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if items.count > 1 {
                            Text(items.prefix(5).map(\.name).formatted(.list(type: .and).locale(L10n.locale)))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 14) {
                            Text(L10n.string("workspace.inspector.location")).foregroundStyle(.secondary)
                            Label(profileName, systemImage: "externaldrive")
                        }
                        if items.count == 1, let item = items.first {
                            valueRow("ui.ba40014ff496f64e", value: item.fileTypeDisplay)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.string("workspace.inspector.location"))
                                    .foregroundStyle(.secondary)
                                Text(item.path)
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                                    .truncationMode(.middle)
                                    .help(item.path)
                            }
                            if let size = item.sizeBytes, !item.isDirectory {
                                valueRow("ui.50db7447b966f5ef", value: size.formatted(.byteCount(style: .file).locale(L10n.locale)))
                            }
                            if let modifiedAt = item.times?.modifiedAt {
                                valueRow("ui.2cbced881b2df35a", value: modifiedAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale)))
                            }
                            Button(L10n.string("workspace.inspector.properties")) { onShowProperties(item) }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        } else {
                            if items.count > 5 {
                                Text(L10n.string("workspace.inspector.remaining", items.count - 5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .background(MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased).content)
        .accessibilityIdentifier("workspace.inspector")
    }

    private func valueRow(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string(key)).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

enum FileBrowserContentState: Equatable {
    case loading
    case empty
    case filteredEmpty
    case error
    case content

    static func resolve(hasItems: Bool, isBusy: Bool, hasError: Bool, hasQuery: Bool) -> Self {
        if hasItems { return .content }
        if isBusy { return .loading }
        if hasError { return .error }
        return hasQuery ? .filteredEmpty : .empty
    }
}

enum FileSortCriterion: CaseIterable, Identifiable, Hashable {
    case name, modified, size, kind, owner
    var id: Self { self }

    var title: String {
        switch self {
        case .name: L10n.string("ui.d44e9b3d3b31d37b")
        case .modified: L10n.string("ui.2cbced881b2df35a")
        case .size: L10n.string("ui.50db7447b966f5ef")
        case .kind: L10n.string("ui.ba40014ff496f64e")
        case .owner: L10n.string("ui.43a7f4b4c5c88a2a")
        }
    }

    func comparator(order: SortOrder) -> KeyPathComparator<FileItem> {
        switch self {
        case .name: KeyPathComparator(\.name, order: order)
        case .modified: KeyPathComparator(\.modifiedTimeForSort, order: order)
        case .size: KeyPathComparator(\.sizeForSort, order: order)
        case .kind: KeyPathComparator(\.fileTypeDisplay, order: order)
        case .owner: KeyPathComparator(\.ownerForSort, order: order)
        }
    }

    static func resolve(_ comparator: KeyPathComparator<FileItem>?) -> Self {
        guard let comparator else { return .name }
        return allCases.first { $0.comparator(order: .forward).keyPath == comparator.keyPath } ?? .name
    }
}
