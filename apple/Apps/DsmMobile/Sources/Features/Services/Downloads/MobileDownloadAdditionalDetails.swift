import DsmCore
import DsmLocalization
import SwiftUI

struct MobileDownloadAdditionalDetails: View {
    let details: DownloadStationTaskDetails

    var body: some View {
        Section(L10n.string("download.workspace.details")) {
            if let kind = details.kind {
                LabeledContent(L10n.string("mobile.downloads.details.kind"), value: kind.uppercased())
            }
            if let owner = details.owner {
                LabeledContent(L10n.string("mobile.downloads.details.owner"), value: owner)
            }
            if let date = details.createdAt {
                LabeledContent(L10n.string("mobile.downloads.details.created"), value:
                    date.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale)))
            }
            if let priority = details.priority {
                LabeledContent(L10n.string("mobile.downloads.details.priority"), value: priorityTitle(priority))
            }
            if let seeds = details.connectedSeeders {
                LabeledContent(L10n.string("mobile.downloads.details.connected-seeds"), value: seeds.formatted(.number.locale(L10n.locale)))
            }
            if let peers = details.totalPeers {
                LabeledContent(L10n.string("mobile.downloads.details.total-peers"), value: peers.formatted(.number.locale(L10n.locale)))
            }
        }
        if let files = details.files {
            Section {
                DisclosureGroup(L10n.string("mobile.downloads.details.files", files.count)) {
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(file.name).textSelection(.enabled)
                            LabeledContent(L10n.string("download.workspace.size"), value: MobileDownloadPresentation.bytes(file.sizeBytes))
                            LabeledContent(L10n.string("download.workspace.downloaded"), value: MobileDownloadPresentation.bytes(file.downloadedBytes))
                            if let priority = file.priority {
                                LabeledContent(L10n.string("mobile.downloads.details.priority"), value: priorityTitle(priority))
                            }
                        }
                    }
                }
                .accessibilityIdentifier("downloads.details.files")
            }
        }
        if let trackers = details.trackers {
            Section {
                DisclosureGroup(L10n.string("mobile.downloads.details.trackers", trackers.count)) {
                    ForEach(Array(trackers.enumerated()), id: \.offset) { _, tracker in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tracker.displayAddress).textSelection(.enabled)
                            if let seeds = tracker.seeds {
                                LabeledContent(L10n.string("download.workspace.seeds"), value: seeds.formatted(.number.locale(L10n.locale)))
                            }
                            if let peers = tracker.peers {
                                LabeledContent(L10n.string("mobile.downloads.details.total-peers"), value: peers.formatted(.number.locale(L10n.locale)))
                            }
                        }
                    }
                }
                .accessibilityIdentifier("downloads.details.trackers")
            }
        }
        if let peers = details.peers {
            Section {
                DisclosureGroup(L10n.string("mobile.downloads.details.peers", peers.count)) {
                    ForEach(Array(peers.enumerated()), id: \.offset) { _, peer in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(peer.address).textSelection(.enabled)
                            if let client = peer.client { Text(client).foregroundStyle(.secondary) }
                            if let progress = peer.progress { ProgressView(value: progress)
                                .accessibilityLabel(L10n.string("download.workspace.progress"))
                                .accessibilityValue(progress.formatted(.percent.locale(L10n.locale))) }
                            LabeledContent(L10n.string("download.workspace.download-speed"), value: MobileDownloadPresentation.speed(peer.downloadBytesPerSecond))
                            LabeledContent(L10n.string("download.workspace.upload-speed"), value: MobileDownloadPresentation.speed(peer.uploadBytesPerSecond))
                        }
                    }
                }
                .accessibilityIdentifier("downloads.details.peers")
            }
        }
    }

    private func priorityTitle(_ priority: String) -> String {
        switch priority {
        case "auto": return L10n.string("mobile.downloads.priority.auto")
        case "low": return L10n.string("mobile.downloads.priority.low")
        case "normal": return L10n.string("mobile.downloads.priority.normal")
        case "high": return L10n.string("mobile.downloads.priority.high")
        case "skip": return L10n.string("mobile.downloads.priority.skip")
        default: return L10n.string("download.workspace.unknown")
        }
    }
}
