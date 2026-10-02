import DsmCore
import DsmLocalization
import SwiftUI

struct FileBackgroundTaskActions: View {
    @Bindable var model: WorkspaceModel
    let task: FileBackgroundTaskSummary
    @State private var showsDetails = false
    @State private var confirmsControl = false
    private var canClear: Bool { task.state == .finished && task.createdAt != nil && task.method == "start" }
    var body: some View {
        HStack {
            Button(L10n.string("files.tasks.details")) { showsDetails = true }
            Spacer()
            if canClear || model.canStopServerTask(task) {
                Button(L10n.string(canClear ? "files.tasks.clear" : "files.tasks.stop")) { confirmsControl = true }
                    .disabled(model.controllingServerTaskIDs.contains(task.id))
            }
        }.padding(.horizontal, 12)
            .alert(L10n.string(canClear ? "files.tasks.clear" : "files.tasks.stop"), isPresented: $confirmsControl) {
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
                Button(L10n.string(canClear ? "files.tasks.clear" : "files.tasks.stop"), role: .destructive) {
                    Task { await model.controlServerTask(task, clearFinished: canClear) }
                }
            } message: { Text(L10n.string(canClear ? "files.tasks.clearNotice" : "files.tasks.stopNotice")) }
            .macSheet(isPresented: $showsDetails) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.string("files.tasks.details")).font(.title2.bold())
                    Text(model.profile.displayName)
                    if let date = task.createdAt {
                        LabeledContent(L10n.string("files.tasks.created"), value: date.formatted(.dateTime.year().month().day().hour().minute().second().locale(L10n.locale)))
                    }
                    Text(L10n.string(task.state == .finished ? "background-tasks.state-finished" : "background-tasks.state-active"))
                    if let progress = task.progress { ProgressView(value: progress) }
                    if let processed = task.processedItemCount { Text(L10n.string("background-tasks.items-processed", processed)) }
                    if let processed = task.processedBytes {
                        Text(L10n.string("background-tasks.bytes-processed", processed.formatted(.byteCount(style: .file).locale(L10n.locale))))
                    }
                    DisclosureGroup(L10n.string("files.tasks.reference")) { Text(task.id).textSelection(.enabled) }
                    Text(L10n.string("files.tasks.scope")).font(.caption).foregroundStyle(.secondary)
                    HStack { Spacer(); Button(L10n.string("files.common.close")) { showsDetails = false } }
                }.padding(24).frame(width: 480)
            }
    }
}
