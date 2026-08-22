import DsmCore
import DsmLocalization
import SwiftUI

struct MobileTextInputSheet: View {
    let title: String
    let label: String
    let initialValue: String
    let actionTitle: String
    let action: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: String

    init(
        title: String,
        label: String,
        initialValue: String = "",
        actionTitle: String,
        action: @escaping (String) -> Void
    ) {
        self.title = title
        self.label = label
        self.initialValue = initialValue
        self.actionTitle = actionTitle
        self.action = action
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(label, text: $value)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        action(value.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct MobileEmptyView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}

struct MobileSummaryCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }
}

extension View {
    func deleteConfirmation<Item>(
        title: String,
        message: String,
        item: Binding<Item?>,
        action: @escaping (Item) -> Void
    ) -> some View {
        confirmationDialog(
            title,
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.2f9daa828907b93f"), role: .destructive) {
                if let value = item.wrappedValue {
                    action(value)
                }
                item.wrappedValue = nil
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {
                item.wrappedValue = nil
            }
        } message: {
            Text(message)
        }
    }
}

@MainActor
func resourceList<Item: Identifiable>(
    _ items: [Item],
    title: @escaping (Item) -> String,
    detail: @escaping (Item) -> String
) -> some View {
    Group {
        if items.isEmpty {
            MobileEmptyView(
                title: L10n.string("ui.193f5172b1a610e3"),
                message: L10n.string("ui.8a5055f70e40226c"),
                systemImage: "tray"
            )
        } else {
            List(items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(item))
                            .foregroundStyle(.primary)
                        Text(detail(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }
}

@MainActor
func summaryLine(_ label: String, _ value: String) -> some View {
    HStack {
        Text(label)
            .foregroundStyle(.secondary)
        Spacer()
        Text(value)
            .fontWeight(.medium)
            .multilineTextAlignment(.trailing)
    }
}

func fileIcon(_ item: FileItem) -> String {
    switch item.fileExtension {
    case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp":
        "photo"
    case "mov", "mp4", "mkv":
        "film"
    case "mp3", "m4a", "flac", "wav":
        "music.note"
    case "pdf":
        "doc.richtext"
    case "zip", "7z", "rar", "tar", "gz":
        "archivebox"
    default:
        "doc"
    }
}

@MainActor
func statusIcon(_ status: String) -> some View {
    let normalized = status.lowercased()
    let image = if normalized.contains("down") || normalized.contains("seed") {
        "arrow.down.circle.fill"
    } else if normalized.contains("pause") {
        "pause.circle.fill"
    } else if normalized.contains("error") {
        "exclamationmark.circle.fill"
    } else {
        "clock.fill"
    }
    return Image(systemName: image)
        .font(.title2)
        .foregroundStyle(normalized.contains("error") ? Color.red : Color.blue)
}
