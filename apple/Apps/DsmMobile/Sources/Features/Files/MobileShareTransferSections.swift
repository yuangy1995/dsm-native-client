import DsmLocalization
import SwiftUI

struct MobileShareTransferSections: View {
    @Bindable var model: MobileShareTransferRecovery
    let filter: MobileActivityFilter

    var body: some View {
        if let error = model.error { Section { Text(error).foregroundStyle(.secondary) } }
        ForEach(model.jobs) { job in
            if let queue = job.queue {
                if queue.batches.isEmpty && !queue.isConfiguring && queue.recoveryError == nil && filter.includes(active: false) {
                    Section {
                        Text(L10n.string("mobile.share.empty-transfer")).foregroundStyle(.secondary)
                        Button(L10n.string("mobile.share.remove")) { model.removeEmpty(job) }.frame(minHeight: 44)
                    } header: { Text(L10n.string("mobile.share.activity-title")) }
                } else {
                    MobileFileUploadSections(queue: queue, filter: filter,
                        sourceTitle: L10n.string("mobile.share.activity-title"), onEmpty: { model.removeEmpty(job) })
                }
            } else if filter.includes(active: true) {
                Section {
                    Label(L10n.string("mobile.share.active-elsewhere"), systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                } header: { Text(L10n.string("mobile.share.activity-title")) }
            }
        }
    }
}
