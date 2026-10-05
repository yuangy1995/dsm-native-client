import DsmCore
import DsmLocalization
import SwiftUI

struct MobileDownloadCreateDraft: Identifiable {
    enum Source { case link(String), file(URL) }
    let id = UUID()
    let activation: UUID
    let source: Source
}

/// 所有来源共用一次性表单；关闭草稿不创建任务，也不保存链接或密码。
struct MobileDownloadCreateTaskView: View {
    @Bindable var model: MobileDownloadsModel
    let draft: MobileDownloadCreateDraft
    let fileRepository: (any MobileFileBrowsing)?
    @Environment(\.dismiss) private var dismiss
    @State private var uri: String
    @State private var destination: String?
    @State private var unzipPassword = ""
    @State private var choosingFolder = false
    @FocusState private var inputFocused: Bool

    init(model: MobileDownloadsModel, draft: MobileDownloadCreateDraft, fileRepository: (any MobileFileBrowsing)?) {
        self.model = model; self.draft = draft; self.fileRepository = fileRepository
        _uri = State(initialValue: { if case .link(let uri) = draft.source { uri } else { "" } }())
        _destination = State(initialValue: model.downloadCreateDefaultDestination)
    }
    private var isFile: Bool { if case .file = draft.source { true } else { false } }
    private var isEditing: Bool {
        draft.activation == model.editActivation && !model.isCreatingDownloadTask && model.downloadCreateFeedback == nil
    }
    private var canSubmit: Bool {
        isEditing && model.canCreateDownloadTask && (isFile || !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && destination.map(DownloadTaskDestinationChange.validDestination) != false
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        if case .file(let url) = draft.source {
                            Label(url.lastPathComponent, systemImage: "doc.badge.plus")
                                .accessibilityIdentifier("downloads.create.filename")
                            SecureField(L10n.string("ui.c2a29d7321f21fa1"), text: $unzipPassword)
                                .focused($inputFocused)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("downloads.create.password")
                        } else {
                            TextField(L10n.string("mobile.downloads.create.url.placeholder"), text: $uri, axis: .vertical)
                                .focused($inputFocused)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .accessibilityLabel(L10n.string("mobile.downloads.create.url.label"))
                                .accessibilityIdentifier("downloads.create.uri")
                        }
                    }
                    .disabled(!isEditing)

                    Section {
                        Button { inputFocused = false; choosingFolder = true } label: {
                            LabeledContent(L10n.string("mobile.downloads.create.destination.label"),
                                value: destination ?? L10n.string("mobile.downloads.create.destination.default"))
                        }
                        .disabled(fileRepository == nil)
                        .frame(minHeight: MobileMetrics.minimumTouchTarget)
                        .accessibilityIdentifier("downloads.create.destination")
                        if destination != nil {
                            Button(L10n.string("download.creation.use-default")) { destination = nil }
                                .frame(minHeight: MobileMetrics.minimumTouchTarget)
                                .accessibilityIdentifier("downloads.create.default")
                        }
                    }
                    .disabled(!isEditing)

                    if let feedback = model.downloadCreateFeedback {
                        Section { DownloadCreateFeedbackView(model: model, feedback: feedback) }.id("creation-feedback")
                    }
                }
                .accessibilityIdentifier("downloads.creation.form")
                .onChange(of: model.downloadCreateFeedback) { _, feedback in
                    if feedback != nil { proxy.scrollTo("creation-feedback", anchor: .center) }
                }
            }
            .navigationTitle(L10n.string(isFile ? "mobile.downloads.create.file.action" : "mobile.downloads.create.title"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.isCreatingDownloadTask)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string(model.downloadCreateFeedback == nil ? "mobile.downloads.create.cancel" : "files.common.close")) {
                        unzipPassword = ""; model.dismissDownloadCreateFeedback(); dismiss()
                    }
                    .accessibilityIdentifier("downloads.create.close")
                    .disabled(model.isCreatingDownloadTask)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.downloads.create.submit")) {
                        guard canSubmit else { return }
                        inputFocused = false
                        model.createDownloadTask(draft: draft, uri: uri, destination: destination, unzipPassword: unzipPassword)
                        unzipPassword = ""
                    }
                    .accessibilityIdentifier("downloads.create.submit")
                    .disabled(!canSubmit)
                }
            }
        }
        .sheet(isPresented: $choosingFolder) {
            if let fileRepository {
                MobileFileFolderPicker(repository: fileRepository) { path in
                    guard isEditing, path.hasPrefix("/"), path.count > 1 else { return }
                    let relative = String(path.dropFirst())
                    guard DownloadTaskDestinationChange.validDestination(relative) else { return }
                    destination = relative
                }
            }
        }
        .onChange(of: model.editActivation) { _, _ in choosingFolder = false; unzipPassword = ""; dismiss() }
        .onDisappear {
            unzipPassword = ""
            if !model.isCreatingDownloadTask { model.dismissDownloadCreateFeedback() }
        }
    }
}
