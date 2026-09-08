import AppKit
import DsmCore
import SwiftUI
import DsmLocalization

/// 在时间轴或文件夹视图中移动照片时，供用户选择目标文件夹。
/// 使用独立的 PhotoLibraryModel 实例，避免影响主照片库状态。
struct PhotoFolderDestinationPicker: View {
    @State private var pickerModel: PhotoLibraryModel
    let sourcePath: String
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    init(
        repository: any PhotoLibraryRepository,
        profileID: UUID?,
        sourcePath: String,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._pickerModel = State(
            initialValue: PhotoLibraryModel(
                repository: repository,
                profileID: profileID
            )
        )
        self.sourcePath = sourcePath
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("ui.0bee1672c6d4a3a9"))
                    .font(.headline)
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))

            Divider()

            HStack(spacing: 6) {
                Button {
                    Task { await pickerModel.goBack() }
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(MacToolbarButtonStyle())
                .disabled(!pickerModel.canGoBack)
                .accessibilityLabel(L10n.string("ui.572cf45ba43634b3"))

                Button {
                    Task { await pickerModel.goUp() }
                } label: {
                    Image(systemName: "arrow.turn.up.left")
                }
                .buttonStyle(MacToolbarButtonStyle())
                .disabled(!pickerModel.canGoUp)
                .accessibilityLabel(L10n.string("ui.8e7847be62b68c2b"))

                Text(pickerModel.locationTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(MacGlassSurface(role: .toolbar))

            if pickerModel.isLoading && pickerModel.displayedItems.isEmpty {
                ProgressView(L10n.string("ui.038b9263cfd8c1a8"))
                    .fillsAvailableContentArea()
            } else if let errorMessage = pickerModel.errorMessage {
                ContentUnavailableView(
                    L10n.string("ui.c7046f4c767b4d60"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .fillsAvailableContentArea()
            } else if availableFolders.isEmpty {
                ContentUnavailableView(
                    L10n.string("ui.2e3012c9f8d17867"),
                    systemImage: "folder",
                    description: Text(L10n.string("ui.8ed1c0e8bd363f97"))
                )
                .fillsAvailableContentArea()
            } else {
                folderList
            }

            Divider()

            HStack(spacing: 12) {
                Button(L10n.string("ui.21493a0f78021d9b")) {
                    onSelect(pickerModel.currentPath)
                }
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(pickerModel.currentPath.isEmpty)

                Spacer()

                Button(L10n.string("ui.2cd0f3be8738a86c")) { onCancel() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))
        }
        .frame(minWidth: 480, minHeight: 400)
        .scrollContentBackground(.hidden)
        .background(MacGlassSurface(role: .sidebar))
        .task { await setupPicker() }
    }

    private var availableFolders: [PhotoLibraryItem] {
        pickerModel.displayedItems.filter(\.isFolder)
    }

    private var folderList: some View {
        List(availableFolders) { folder in
            Button {
                Task { await pickerModel.open(folder) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                    Text(folder.name)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
    }

    private func setupPicker() async {
        // 选择器只需要文件夹浏览；albums 模式在根目录只显示文件夹，进入子目录后由视图再过滤为文件夹。
        pickerModel.browseMode = .albums
        await pickerModel.loadIfNeeded()

        guard let space = pickerModel.spaces.first(where: { sourcePath.hasPrefix($0.rootPath) }) ?? pickerModel.spaces.first else {
            return
        }
        pickerModel.selectedSpaceID = space.id
        await pickerModel.setBrowseMode(.albums)

        let parentPath = (sourcePath as NSString).deletingLastPathComponent
        let initialPath = parentPath.count >= space.rootPath.count ? parentPath : space.rootPath

        let folderItem = PhotoLibraryItem(
            id: initialPath,
            profileID: pickerModel.activeProfileID ?? UUID(),
            name: (initialPath as NSString).lastPathComponent,
            path: initialPath,
            kind: .folder,
            sizeBytes: nil,
            createdAt: nil,
            modifiedAt: nil,
            fileExtension: nil,
            thumbnailAvailable: nil
        )
        await pickerModel.open(folderItem)
    }
}
