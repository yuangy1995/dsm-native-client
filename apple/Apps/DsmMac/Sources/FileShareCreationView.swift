import AppKit
import DsmCore
import DsmLocalization
import SwiftUI

struct ShareCreationView: View {
    @Bindable var model: WorkspaceModel
    let targets: [FileItem]
    let onClose: () -> Void
    @State private var password = ""
    @State private var expirationDays = 0
    @State private var hasStartDate = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var results: [FileShareBatchItem] = []
    @State private var hasSubmitted = false
    @State private var creationTask: Task<Void, Never>?
    @State private var fileRequest = false
    @State private var requestName = ""
    @State private var requestMessage = ""
    @State private var confirmsUpload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("ui.4c4f2eb53c85407b")).font(.title2.weight(.semibold))
            Text(targets.count == 1 ? L10n.string("item.share.named", targets[0].name)
                 : L10n.string("ui.e1b60edbc9502ad7", String(targets.count)))
                .foregroundStyle(.secondary)
            if !hasSubmitted {
                Form {
                    if targets.allSatisfy({ $0.isDirectory && $0.permissions?.canWrite == true }) {
                        Toggle(L10n.string("files.request.create"), isOn: $fileRequest)
                        if fileRequest {
                            TextField(L10n.string("files.request.name"), text: $requestName)
                            TextField(L10n.string("files.request.message"), text: $requestMessage, axis: .vertical).lineLimit(3...5)
                            Toggle(L10n.string("files.request.confirmUpload"), isOn: $confirmsUpload)
                        }
                    }
                    SecureField(L10n.string("ui.145ffb632a72ddbd"), text: $password)
                    if password.count > 16 {
                        Text(L10n.string("files.sharing.passwordLength")).foregroundStyle(.red)
                    }
                    Toggle(L10n.string("files.sharing.startDate"), isOn: $hasStartDate)
                    if hasStartDate {
                        DatePicker(L10n.string("files.sharing.startDate"), selection: $startDate,
                                   displayedComponents: .date)
                    }
                    Picker(L10n.string("ui.9c2a28e8f98fb5df"), selection: $expirationDays) {
                        Text(L10n.string("ui.824fe235445dd1be")).tag(0)
                        Text(L10n.string("ui.38eefacbb326e37f")).tag(7)
                        Text(L10n.string("ui.84ad2952a3089ce7")).tag(30)
                        Text(L10n.string("ui.cb82f419192b0423")).tag(90)
                        Text(L10n.string("files.sharing.customDate")).tag(-1)
                    }
                    if expirationDays == -1 {
                        DatePicker(L10n.string("files.sharing.endDate"), selection: $endDate,
                                   displayedComponents: .date)
                    }
                    if !datesAreValid {
                        Text(L10n.string("files.sharing.invalidDates")).foregroundStyle(.red)
                    }
                }
            } else if model.isCreatingShareLinks {
                ProgressView(L10n.string("files.sharing.creating"))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.target.name).font(.headline)
                        Text(result.message).foregroundStyle(.secondary)
                        if let link = result.link {
                            Text(link.url).textSelection(.enabled)
                            ShareLink(item: link.url) { Text(L10n.string("files.sharing.systemShare")) }
                        }
                    }.padding(.vertical, 4)
                }.frame(minHeight: 180, maxHeight: 320)
            }
            HStack {
                if !results.compactMap(\.link).isEmpty {
                    Button(L10n.string("files.sharing.copyAll")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(results.compactMap(\.link).map(\.url).joined(separator: "\n"), forType: .string)
                    }
                }
                Spacer()
                Button(L10n.string("files.common.close"), role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCreatingShareLinks)
                if !hasSubmitted {
                    Button(L10n.string("ui.a71bf6df75763893"), action: createLinks)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isCreatingShareLinks || targets.isEmpty || password.count > 16 || !datesAreValid || (fileRequest && !confirmsUpload))
                }
                if model.isCreatingShareLinks {
                    Button(L10n.string("files.sharing.stopRemaining")) { creationTask?.cancel() }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(model.isCreatingShareLinks)
    }

    private var expiration: FileShareLinkCalendarDate? {
        if expirationDays == 0 { return nil }
        let date = expirationDays == -1 ? endDate
            : Calendar.current.date(byAdding: .day, value: expirationDays, to: Date()) ?? Date()
        return Self.calendarDate(date)
    }

    private var datesAreValid: Bool {
        guard hasStartDate, let start = Self.calendarDate(startDate), let end = expiration else { return true }
        return start <= end
    }

    static func calendarDate(_ date: Date) -> FileShareLinkCalendarDate? {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return try? FileShareLinkCalendarDate(year: year, month: month, day: day)
    }

    private func createLinks() {
        guard !hasSubmitted else { return }
        hasSubmitted = true
        let requestPassword = password.isEmpty ? nil : password
        let availableOn = hasStartDate ? Self.calendarDate(startDate) : nil
        let expiresOn = expiration
        password = ""
        creationTask = Task {
            results = await model.createShareLinks(targets: targets, password: requestPassword,
                availableOn: availableOn, expiresOn: expiresOn,
                fileRequest: fileRequest ? .init(name: requestName, message: requestMessage) : nil)
            let links = results.compactMap(\.link).map(\.url)
            if !links.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
            }
        }
    }
}
