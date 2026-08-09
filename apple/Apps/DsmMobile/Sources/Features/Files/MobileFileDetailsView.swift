import DsmCore
import DsmLocalization
import SwiftUI

struct MobileFileDetailsView: View {
    let item: FileItem

    var body: some View {
        List {
            Section(L10n.string("mobile.files.details.section.general")) {
                detailRow(L10n.string("mobile.files.details.name"), item.name)
                detailRow(L10n.string("mobile.files.details.type"), kindLabel)
                if !item.isDirectory, let size = item.sizeBytes {
                    detailRow(L10n.string("mobile.files.details.size"), formattedSize(size))
                }
                detailRow(L10n.string("mobile.files.details.location"), item.path)
                if let mimeType = item.mimeType, !mimeType.isEmpty {
                    detailRow(L10n.string("mobile.files.details.mime"), mimeType)
                }
                if let fileExtension = item.fileExtension, !fileExtension.isEmpty {
                    detailRow(L10n.string("mobile.files.details.extension"), fileExtension)
                }
                if item.isRecyclePath {
                    Label(
                        L10n.string("mobile.files.details.recycle-location"),
                        systemImage: "trash"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            if let times = item.times,
               times.modifiedAt != nil || times.createdAt != nil || times.accessedAt != nil {
                Section(L10n.string("mobile.files.details.section.dates")) {
                    if let date = times.modifiedAt {
                        detailRow(L10n.string("mobile.files.details.modified"), formattedDate(date))
                    }
                    if let date = times.createdAt {
                        detailRow(L10n.string("mobile.files.details.created"), formattedDate(date))
                    }
                    if let date = times.accessedAt {
                        detailRow(L10n.string("mobile.files.details.accessed"), formattedDate(date))
                    }
                }
            }

            if hasOwnership {
                Section(L10n.string("mobile.files.details.section.ownership")) {
                    if let owner = item.owner, !owner.isEmpty {
                        detailRow(L10n.string("mobile.files.details.owner"), owner)
                    }
                    if let group = item.group, !group.isEmpty {
                        detailRow(L10n.string("mobile.files.details.group"), group)
                    }
                }
            }

            if let permissions = item.permissions {
                Section(L10n.string("mobile.files.details.section.permissions")) {
                    permissionRow(L10n.string("mobile.files.details.view"), allowed: permissions.canRead)
                    permissionRow(L10n.string("mobile.files.details.edit"), allowed: permissions.canWrite)
                    permissionRow(L10n.string("mobile.files.details.delete"), allowed: permissions.canDelete)
                }
            }
        }
        .listStyle(.insetGrouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private var hasOwnership: Bool {
        item.owner?.isEmpty == false || item.group?.isEmpty == false
    }

    private var kindLabel: String {
        switch item.kind {
        case .file: L10n.string("mobile.files.details.value.file")
        case .directory: L10n.string("mobile.files.details.value.folder")
        case .symlink: L10n.string("mobile.files.details.value.link")
        case .unknown: L10n.string("mobile.files.details.value.item")
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func permissionRow(_ label: String, allowed: Bool) -> some View {
        LabeledContent(label) {
            Label(
                L10n.string(
                    allowed
                        ? "mobile.files.details.value.allowed"
                        : "mobile.files.details.value.not-allowed"
                ),
                systemImage: allowed ? "checkmark.circle.fill" : "xmark.circle"
            )
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatStyle(style: .file)
            .locale(L10n.locale)
            .format(bytes)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
