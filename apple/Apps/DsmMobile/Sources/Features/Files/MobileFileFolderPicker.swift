import DsmCore
import DsmLocalization
import SwiftUI

/// 复用文件浏览的分页与迟到响应门禁；选择器不改变主页面的当前位置。
struct MobileFileFolderPicker: View {
    let repository: any MobileFileBrowsing
    let choose: (String) -> Void
    @State private var browser = MobileFileBrowserModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if browser.state.pageState == .loading {
                    ProgressView(L10n.string("mobile.files.loading"))
                } else if browser.state.pageState == .error {
                    ContentUnavailableView {
                        Label(L10n.string("mobile.files.load-error"), systemImage: "exclamationmark.circle")
                    } description: {
                        Text(L10n.string("ui.5448ceb91a80e260"))
                    } actions: {
                        Button(L10n.string("ui.b8784c8dd5636ff2")) { Task { await browser.refresh(repository: repository) } }
                    }
                } else {
                    List {
                        if browser.state.page.items.filter(\.isDirectory).isEmpty {
                            Text(L10n.string(browser.state.currentPath.isEmpty
                                ? "mobile.files.folder-picker.empty-root" : "mobile.files.copy-move.empty.message"))
                                .foregroundStyle(.secondary)
                            if browser.state.currentPath.isEmpty {
                                Button(L10n.string("ui.aee88743413144a2")) {
                                    Task { await browser.refresh(repository: repository) }
                                }
                            }
                        }
                        ForEach(browser.state.page.items.filter(\.isDirectory)) { folder in
                            Button {
                                Task { await browser.openDirectory(folder, repository: repository) }
                            } label: {
                                Label(folder.name, systemImage: "folder")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("files.folder-picker.folder." + folder.path)
                        }
                        if browser.state.loadMoreFailed {
                            Text(L10n.string("mobile.files.load-more-error"))
                        }
                        if browser.state.isLoadingMore {
                            ProgressView()
                        } else if browser.state.page.hasMore {
                            Button(L10n.string("mobile.files.load-more")) {
                                Task { await browser.loadMore(repository: repository) }
                            }
                        }
                    }
                    .refreshable { await browser.refresh(repository: repository) }
                }
            }
            .fillsAvailableContentArea(alignment: .topLeading)
            .navigationTitle(browser.state.currentPath.isEmpty
                ? L10n.string("mobile.files.choose-folder")
                : URL(fileURLWithPath: browser.state.currentPath).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                }
                if !browser.state.currentPath.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task { await browser.goUp(repository: repository) }
                        } label: {
                            Image(systemName: "chevron.backward").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(L10n.string("ui.2bab713fde4ebc53"))
                    }
                    ToolbarItem(placement: .principal) {
                        Text(browser.state.currentPath).lineLimit(2).truncationMode(.middle)
                            .font(.subheadline).accessibilityLabel(browser.state.currentPath)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.files.choose-this-folder")) {
                        choose(browser.state.currentPath); dismiss()
                    }
                    .disabled(browser.state.currentPath.isEmpty || browser.state.visibleKey?.path != browser.state.currentPath || browser.state.pageState == .error || browser.state.isRefreshing)
                }
            }
        }
        .task {
            await browser.activate(profileID: repository.profileID, repository: repository)
            if browser.state.visibleKey == nil { await browser.refresh(repository: repository) }
        }
        .onDisappear { browser.cancelRequest() }
    }
}
