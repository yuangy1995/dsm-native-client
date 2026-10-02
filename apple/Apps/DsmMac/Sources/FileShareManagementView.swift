import AppKit
import CoreImage.CIFilterBuiltins
import DsmCore
import DsmLocalization
import SwiftUI

struct FileShareManagementItem: Identifiable {
    let link: FileShareLink
    let status: MutationResultStatus
    var id: String { link.id }
    var message: String {
        switch status {
        case .confirmedSuccess: L10n.string("files.sharing.updated")
        case .confirmedFailure: L10n.string("files.sharing.changeFailed")
        case .permissionDenied: L10n.string("files.sharing.denied")
        case .unsupported: L10n.string("files.sharing.manageUnsupported")
        case .cancelledBeforeSubmission: L10n.string("files.sharing.cancelled")
        default: L10n.string("files.sharing.changeUnverified")
        }
    }
}

enum FileShareQRCode {
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

struct ShareLinksView: View {
    @Bindable var model: WorkspaceModel
    @State private var selection = Set<String>()
    @State private var filter = ""
    @State private var deleteTargets: [FileShareLink] = []
    @State private var editTargets: [FileShareLink] = []
    @State private var qrLink: FileShareLink?
    @State private var advancedLink: FileShareLink?
    private var visible: [FileShareLink] { model.shareLinks.filter { filter.isEmpty || $0.name.localizedStandardContains(filter) } }
    private var selected: [FileShareLink] { model.shareLinks.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField(L10n.string("files.sharing.filter"), text: $filter).textFieldStyle(.roundedBorder)
                Button(L10n.string("files.sharing.refresh")) { Task { await model.loadShareLinks() } }
                Menu(L10n.string("files.sharing.selectedActions")) {
                    Button(L10n.string("files.sharing.copySelected")) { copy(selected) }
                    Button(L10n.string("files.sharing.edit")) { editTargets = selected }
                    Button(L10n.string("ui.21d728b6664ca9bc"), role: .destructive) { deleteTargets = selected }
                }.disabled(selected.isEmpty || model.isManagingShareLinks)
            }.padding(16)
            if model.isLoadingShareLinks {
                ProgressView(L10n.string("ui.fe59090f0d4bc698")).fillsAvailableContentArea()
            } else if let error = model.shareLinksError {
                ContentUnavailableView(L10n.string("files.sharing.loadFailed"), systemImage: "exclamationmark.triangle", description: Text(error))
                    .fillsAvailableContentArea()
            } else if model.shareLinks.isEmpty {
                ContentUnavailableView(L10n.string("ui.a4a471232364a4e3"), systemImage: "link",
                    description: Text(L10n.string("ui.9b90b76e744938f2"))).fillsAvailableContentArea()
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: filter).fillsAvailableContentArea()
            } else {
                List(selection: $selection) {
                    ForEach(visible) { link in
                        HStack(spacing: 12) {
                            Image(systemName: "link.circle.fill").foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(link.name)
                                Text(statusTitle(link.status ?? .unknown))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let date = link.availableAt { Text(L10n.string("files.sharing.availableOn", localizedDate(date))).font(.caption) }
                                if let date = link.expiresAt { Text(L10n.string("ui.f491436ed3a96c9c", localizedDate(date))).font(.caption) }
                                if link.hasPassword { Label(L10n.string("ui.8aa0da83b66e54f0"), systemImage: "lock.fill").font(.caption) }
                                if link.advanced?.isFileRequest == true {
                                    Text(L10n.string("files.request.title")).font(.caption)
                                } else if link.advanced?.protection == .users {
                                    Text(L10n.string("files.sharing.namedAudience")).font(.caption)
                                }
                            }
                            Spacer()
                            ShareLink(item: link.url) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel(L10n.string("files.sharing.systemShare"))
                            Button { qrLink = link } label: { Image(systemName: "qrcode") }
                                .accessibilityLabel(L10n.string("files.sharing.qr"))
                            Menu(L10n.string("workspace.actions.more")) {
                                Button(L10n.string("ui.8e86f9b1d54f2c51")) { copy([link]) }
                                Button(L10n.string("files.sharing.edit")) { editTargets = [link] }
                                if link.advanced != nil {
                                    Button(L10n.string("files.sharing.accessSettings")) { advancedLink = link }
                                }
                                Button(L10n.string("ui.21d728b6664ca9bc"), role: .destructive) { deleteTargets = [link] }
                            }.disabled(model.isManagingShareLinks)
                        }.tag(link.id).macDataRowSurface()
                    }
                }
            }
            if model.isManagingShareLinks { ProgressView().padding() }
            if !model.shareManagementResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.shareManagementResults) { item in Text(L10n.string("files.sharing.itemResult", item.link.name, item.message)) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120).padding(16)
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .navigationTitle(L10n.string("ui.76cdc4a13d1eecc0"))
        .task { await model.loadShareLinks() }
        .alert(L10n.string("ui.0c1777d6b7a70cc7"), isPresented: Binding(get: { !deleteTargets.isEmpty }, set: { if !$0 { deleteTargets = [] } })) {
            Button(L10n.string("ui.670ec25af8419f48"), role: .cancel) { deleteTargets = [] }
            Button(L10n.string("ui.21d728b6664ca9bc"), role: .destructive) {
                let ids = deleteTargets.map(\.id); deleteTargets = []
                Task { await model.deleteShareLinks(ids: ids) }
            }
        } message: { Text(L10n.string("ui.0fefbd857362afbe")) }
        .macSheet(isPresented: Binding(get: { !editTargets.isEmpty }, set: { if !$0 { editTargets = [] } })) {
            FileShareEditView(model: model, links: editTargets) { editTargets = [] }
        }
        .macSheet(item: $qrLink) { link in
            VStack(spacing: 16) {
                Text(link.name).font(.headline)
                if let image = FileShareQRCode.image(for: link.url) {
                    Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                        .frame(width: 250, height: 250).padding(24).background(.white)
                        .accessibilityLabel(L10n.string("files.sharing.qr"))
                } else { Text(L10n.string("files.sharing.qrFailed")) }
                Text(link.url).textSelection(.enabled)
                Button(L10n.string("files.common.close")) { qrLink = nil }
            }.padding(24).frame(width: 380)
        }
        .macSheet(item: $advancedLink) { link in
            FileShareAdvancedView(model: model, link: link) { advancedLink = nil }
        }
    }
    private func statusTitle(_ status: FileShareLinkStatus) -> String {
        switch status {
        case .valid: L10n.string("files.sharing.status.valid")
        case .invalid: L10n.string("files.sharing.status.invalid")
        case .inactive: L10n.string("files.sharing.status.inactive")
        case .expired: L10n.string("files.sharing.status.expired")
        case .broken: L10n.string("files.sharing.status.broken")
        case .unknown: L10n.string("files.sharing.status.unknown")
        }
    }
    private func copy(_ links: [FileShareLink]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.map(\.url).joined(separator: "\n"), forType: .string)
    }
    private func localizedDate(_ value: String) -> String {
        guard let day = try? FileShareLinkCalendarDate(iso8601: String(value.prefix(10))),
              let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return value }
        return date.formatted(.dateTime.year().month().day().locale(L10n.locale)) + (value.count == 19 ? " " + value.suffix(8) : "")
    }
}

struct FileShareEditView: View {
    @Bindable var model: WorkspaceModel
    let links: [FileShareLink]
    let onClose: () -> Void
    @State private var passwordMode = 0
    @State private var password = ""
    @State private var startMode = 0
    @State private var endMode = 0
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var submitted = false
    @State private var confirmsRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("files.sharing.edit")).font(.title2.bold())
            Text(links.map(\.name).joined(separator: "\n")).lineLimit(4)
            Form {
                Picker(L10n.string("files.sharing.password"), selection: $passwordMode) {
                    Text(L10n.string("files.sharing.keep")).tag(0)
                    Text(L10n.string("files.sharing.setPassword")).tag(1)
                    Text(L10n.string("files.sharing.removePassword")).tag(2)
                }
                if passwordMode == 1 { SecureField(L10n.string("files.sharing.newPassword"), text: $password) }
                if passwordMode == 2 { Toggle(L10n.string("files.sharing.confirmRemovePassword"), isOn: $confirmsRemoval) }
                dateMode(L10n.string("files.sharing.startDate"), mode: $startMode, date: $startDate,
                         clearTitle: L10n.string("files.sharing.immediate"))
                dateMode(L10n.string("files.sharing.endDate"), mode: $endMode, date: $endDate,
                         clearTitle: L10n.string("ui.824fe235445dd1be"))
            }.disabled(submitted)
            if !submitted && hasChanges && requests == nil { Text(L10n.string("files.sharing.checkChanges")).foregroundStyle(.red) }
            if submitted && !model.isManagingShareLinks {
                ForEach(model.shareManagementResults) { result in Text(L10n.string("files.sharing.itemResult", result.link.name, result.message)) }
            }
            HStack {
                Spacer()
                Button(L10n.string("files.common.close"), action: onClose)
                    .keyboardShortcut(.cancelAction).disabled(model.isManagingShareLinks)
                if !submitted {
                    Button(L10n.string("files.sharing.save")) {
                        guard let requests else { return }
                        submitted = true; password = ""
                        Task { await model.editShareLinks(requests) }
                    }.buttonStyle(.borderedProminent)
                        .disabled(requests == nil || model.isManagingShareLinks || (passwordMode == 2 && !confirmsRemoval))
                }
                if model.isManagingShareLinks { ProgressView().controlSize(.small) }
            }
        }.padding(24).frame(width: 540)
            .interactiveDismissDisabled(model.isManagingShareLinks)
    }
    private func dateMode(_ title: String, mode: Binding<Int>, date: Binding<Date>, clearTitle: String) -> some View {
        VStack(alignment: .leading) {
            Picker(title, selection: mode) {
                Text(L10n.string("files.sharing.keep")).tag(0)
                Text(clearTitle).tag(1)
                Text(L10n.string("files.sharing.customDate")).tag(2)
            }
            if mode.wrappedValue == 2 { DatePicker(title, selection: date, displayedComponents: .date) }
        }
    }
    private var hasChanges: Bool { passwordMode != 0 || startMode != 0 || endMode != 0 }
    private var requests: [FileShareLinkEditRequest]? {
        if passwordMode == 1 && (password.isEmpty || password.count > 16) { return nil }
        if passwordMode == 0 && startMode == 0 && endMode == 0 { return nil }
        let change: FileShareLinkPasswordChange = passwordMode == 0 ? .keep : passwordMode == 2 ? .remove : .set(password)
        return try? links.map { link in
            guard startMode != 0 || link.availabilityDateKnown == true else { throw FileShareLinkContractError.invalidDate }
            let start = startMode == 0 ? try link.availableAt.map { try FileShareLinkCalendarDate(iso8601: String($0.prefix(10))) }
                : startMode == 1 ? nil : ShareCreationView.calendarDate(startDate)
            let end = endMode == 0 ? try link.expiresAt.map { try FileShareLinkCalendarDate(iso8601: String($0.prefix(10))) }
                : endMode == 1 ? nil : ShareCreationView.calendarDate(endDate)
            return try .init(baseline: link, password: change, availableOn: start, expiresOn: end,
                             keepsAvailableDate: startMode == 0, keepsExpirationDate: endMode == 0)
        }
    }
}
