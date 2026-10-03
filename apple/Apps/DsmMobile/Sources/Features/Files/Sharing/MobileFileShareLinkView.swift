import DsmCore
import DsmLocalization
import Foundation
import SwiftUI

struct MobileFileShareLinkView: View {
    @Bindable var model: MobileFileShareLinkModel
    @State private var filter = ""
    @State private var selection: Set<String> = []
    @State private var editSelection: MobileFileShareEditSelection?
    @State private var qrLink: FileShareLink?
    @State private var confirmsFileRequest = false
    @State private var deleteSelection: [FileShareLink] = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Group {
                switch model.state.phase {
                case .form: form
                case .managing:
                    statusView(systemImage: "link", title: L10n.string("mobile.sharing.saving")) { ProgressView() }
                case .batchResults: batchResults
                case .creating:
                    statusView(systemImage: "link.badge.plus", title: L10n.string("mobile.files.share-link.creating")) {
                        VStack(spacing: 16) {
                            ProgressView()
                            Button(L10n.string("mobile.files.share-link.action.cancel")) {
                                model.requestCancellation()
                            }
                            .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                case .confirmedSuccess: success
                case .reviewRequired:
                    statusView(
                        systemImage: "arrow.clockwise.circle.fill",
                        title: L10n.string("mobile.files.share-link.review.title"),
                        message: L10n.string("mobile.files.share-link.review.message")
                    ) {
                        VStack {
                            Button(L10n.string("mobile.files.share-link.management.return")) { model.returnToManagement() }
                            dismissButton
                        }
                    }
                case .confirmedFailure:
                    statusView(
                        systemImage: "exclamationmark.triangle.fill",
                        title: L10n.string("mobile.files.share-link.failure.title"),
                        message: failureMessage
                    ) { failureActions }
                case .managementLoading:
                    statusView(
                        systemImage: "link",
                        title: L10n.string("mobile.files.share-link.management.loading")
                    ) { ProgressView() }
                case .managementEmpty:
                    statusView(
                        systemImage: "link",
                        title: L10n.string("mobile.files.share-link.management.empty.title"),
                        message: L10n.string(model.state.target == nil ? "mobile.sharing.empty-all" : "mobile.files.share-link.management.empty.message")
                    ) { managementEmptyActions }
                case .managementContent:
                    managementList
                case .managementError:
                    statusView(
                        systemImage: "exclamationmark.circle.fill",
                        title: L10n.string("mobile.files.share-link.management.error.title"),
                        message: L10n.string("mobile.files.share-link.management.error.message")
                    ) { managementErrorActions }
                case .managementUnsupported:
                    statusView(
                        systemImage: "link.slash",
                        title: L10n.string("mobile.files.share-link.management.unsupported.title"),
                        message: L10n.string("mobile.files.share-link.management.unsupported.message")
                    ) { dismissButton }
                case .deletionConfirm:
                    statusView(
                        systemImage: "trash",
                        title: L10n.string("mobile.files.share-link.delete.confirm.title"),
                        message: L10n.string("mobile.files.share-link.delete.confirm.message")
                    ) { deleteConfirmActions }
                case .deleting:
                    statusView(
                        systemImage: "trash",
                        title: L10n.string("mobile.files.share-link.delete.deleting")
                    ) { ProgressView() }
                case .deletionConfirmed:
                    statusView(
                        systemImage: "checkmark.circle.fill",
                        title: L10n.string("mobile.files.share-link.delete.success.title"),
                        message: L10n.string("mobile.files.share-link.delete.success.message")
                    ) { returnToManagementButton }
                case .deletionReviewRequired:
                    statusView(
                        systemImage: "arrow.clockwise.circle.fill",
                        title: L10n.string("mobile.files.share-link.delete.review.title"),
                        message: L10n.string("mobile.files.share-link.delete.review.message")
                    ) { returnToManagementButton }
                case .deletionFailure:
                    statusView(
                        systemImage: "exclamationmark.triangle.fill",
                        title: L10n.string("mobile.files.share-link.delete.failure.title"),
                        message: deletionFailureMessage
                    ) { returnToManagementButton }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.state.phase == .form {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("mobile.files.share-link.action.cancel")) { model.dismiss() }
                    }
                }
                if showsManagementClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("mobile.files.share-link.action.dismiss")) { model.dismiss() }
                    }
                }
                if model.canRefreshManagement {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.refreshManagement()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(L10n.string("mobile.files.share-link.management.refresh"))
                    }
                }
            }
        }
        .interactiveDismissDisabled([.creating, .deleting, .managing].contains(model.state.phase))
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: sharePresentationBinding) { presentation in
            MobileShareSheet(url: presentation.url) { model.shareDidDismiss() }
        }
        .sheet(item: $editSelection) { edit in
            if edit.advanced, let link = edit.links.first {
                MobileFileShareAdvancedView(link: link, model: model)
            } else { MobileFileShareEditView(links: edit.links, model: model) }
        }
        .sheet(item: $qrLink) { MobileFileShareQRCodeView(link: $0) }
        .alert(L10n.string("files.request.create"), isPresented: $confirmsFileRequest) {
            Button(L10n.string("mobile.files.share-link.action.cancel"), role: .cancel) {}
            Button(L10n.string("mobile.files.share-link.action.submit")) { model.submit() }
        } message: { Text(L10n.string("mobile.sharing.request-risk")) }
        .alert(L10n.string("mobile.files.share-link.delete.confirm.title"),
               isPresented: Binding(get: { !deleteSelection.isEmpty }, set: { if !$0 { deleteSelection = [] } })) {
            Button(L10n.string("mobile.files.share-link.action.cancel"), role: .cancel) { deleteSelection = [] }
            Button(L10n.string("mobile.files.share-link.delete.confirm.action"), role: .destructive) {
                let links = deleteSelection; deleteSelection = []; selection = []; model.deleteManagedLinks(links)
            }
        } message: { Text(L10n.string("mobile.files.share-link.delete.confirm.message")) }
    }

    private var navigationTitle: String {
        switch model.state.phase {
        case .managementLoading, .managementEmpty, .managementContent, .managementError,
             .managementUnsupported, .deletionConfirm, .deleting, .deletionConfirmed,
             .deletionReviewRequired, .deletionFailure, .managing, .batchResults:
            L10n.string("mobile.files.share-link.management.title")
        default:
            L10n.string("mobile.files.share-link.title")
        }
    }

    private var showsManagementClose: Bool {
        switch model.state.phase {
        case .managementLoading, .managementEmpty, .managementContent, .managementError,
             .managementUnsupported:
            true
        default:
            false
        }
    }

    private var form: some View {
        Form {
            Section {
                ForEach(model.state.targets) { Text($0.name) }
            }
            if model.canCreateFileRequest {
                Section {
                    Toggle(L10n.string("files.request.create"), isOn: Binding(get: { model.state.isFileRequest }, set: { model.setFileRequest($0) }))
                    if model.state.isFileRequest {
                        TextField(L10n.string("files.request.name"), text: Binding(get: { model.state.requestName }, set: { model.setRequestName($0) }))
                        TextField(L10n.string("files.request.message"), text: Binding(get: { model.state.requestMessage }, set: { model.setRequestMessage($0) }), axis: .vertical)
                    }
                }
            }
            Section {
                SecureField(L10n.string("mobile.files.share-link.password.label"), text: passwordBinding)
                    .textContentType(.newPassword)
                Text(L10n.string("mobile.files.share-link.password.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(L10n.string("files.sharing.startDate"), isOn: Binding(get: { model.state.availableOn != nil },
                    set: { model.setAvailableOn($0 ? Date() : nil) }))
                if model.state.availableOn != nil {
                    DatePicker(L10n.string("files.sharing.startDate"), selection: Binding(get: { model.state.availableOn ?? Date() },
                        set: { model.setAvailableOn($0) }), displayedComponents: .date)
                }
                Picker(L10n.string("mobile.files.share-link.expiration.label"), selection: expirationBinding) {
                    ForEach(MobileFileShareLinkExpiration.allCases) { expiration in
                        Text(L10n.string(expiration.resourceKey)).tag(expiration)
                    }
                }
                if model.state.expiration == .custom {
                    DatePicker(L10n.string("files.sharing.endDate"), selection: Binding(get: { model.state.customExpiration },
                        set: { model.setCustomExpiration($0) }), displayedComponents: .date)
                }
            }
            if model.recoveryFailed { Text(L10n.string("mobile.activity.recovery-error")).foregroundStyle(.red) }
            Section {
                Button {
                    if model.state.isFileRequest { confirmsFileRequest = true } else { model.submit() }
                } label: {
                    Text(L10n.string("mobile.files.share-link.action.submit"))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("sharing.create.submit")
            }
        }
    }

    private var success: some View {
        statusView(
            systemImage: "checkmark.circle.fill",
            title: L10n.string("mobile.files.share-link.success.title")
        ) {
            VStack(spacing: 12) {
                if model.state.confirmedLink?.hasPassword == true {
                    Label(L10n.string("mobile.files.share-link.protected"), systemImage: "lock.fill")
                }
                if let formattedExpiration = localizedExpiration {
                    Label(
                        L10n.string("mobile.files.share-link.expires", formattedExpiration),
                        systemImage: "calendar"
                    )
                }
                Button {
                    model.copyConfirmedLink()
                } label: {
                    Label(L10n.string("mobile.files.share-link.action.copy"), systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    model.presentSystemShare()
                } label: {
                    Label(L10n.string("mobile.files.share-link.action.share"), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                if model.state.copied {
                    Text(L10n.string("mobile.files.share-link.copied"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits([.isStaticText, .updatesFrequently])
                }
                if let link = model.state.confirmedLink {
                    Button(L10n.string("files.sharing.qr")) { qrLink = link }.frame(minHeight: 44)
                }
                Button(L10n.string("mobile.files.share-link.management.return")) { model.returnToManagement() }.frame(minHeight: 44)
                Button(L10n.string("mobile.files.share-link.action.done")) { model.dismiss() }
                    .frame(minHeight: 44)
            }
        }
    }

    private var selectedLinks: [FileShareLink] { model.state.managedLinks.filter { selection.contains($0.id) } }
    private var filteredLinks: [FileShareLink] {
        model.state.managedLinks.filter { filter.isEmpty || $0.name.localizedStandardContains(filter) || $0.path.localizedStandardContains(filter) }
    }
    private var managementList: some View {
        List {
            if let target = model.state.target { Section { Text(target.name) } }
            if !selectedLinks.isEmpty {
                Section {
                    Button(L10n.string("files.sharing.copySelected")) { model.copyLinks(selectedLinks) }
                    Button(L10n.string("files.sharing.edit")) { editSelection = .init(links: selectedLinks) }
                        .disabled(selectedLinks.contains { model.state.blockedLinkIDs.contains($0.id) } || model.recoveryFailed)
                    Button(L10n.string("mobile.files.share-link.delete.action"), role: .destructive) { deleteSelection = selectedLinks }
                        .disabled(selectedLinks.contains { model.state.blockedLinkIDs.contains($0.id) } || model.recoveryFailed)
                }
            }
            if filteredLinks.isEmpty { ContentUnavailableView.search(text: filter) }
            Section {
                ForEach(filteredLinks) { link in
                    HStack(alignment: .top) {
                        Button {
                            if selection.contains(link.id) { selection.remove(link.id) } else { selection.insert(link.id) }
                        } label: {
                            Image(systemName: selection.contains(link.id) ? "checkmark.circle.fill" : "circle").frame(width: 44, height: 44)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(L10n.string("mobile.sharing.select-link", link.name))
                            .accessibilityAddTraits(selection.contains(link.id) ? .isSelected : [])
                        managedLinkRow(link)
                    }
                }
                if model.state.managedLinksTruncated {
                    Label(L10n.string("mobile.files.share-link.management.truncated"), systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.state.copied { Text(L10n.string("mobile.files.share-link.copied")) }
                if model.recoveryFailed { Text(L10n.string("mobile.activity.recovery-error")).foregroundStyle(.red) }
            }
            if model.state.target != nil {
                Section {
                    Button { model.showCreateFormFromManagement() } label: {
                        Label(L10n.string("mobile.files.share-link.action.create"), systemImage: "link.badge.plus")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
        }.searchable(text: $filter, prompt: L10n.string("files.sharing.filter"))
            .refreshable { model.refreshManagement() }
    }

    private var batchResults: some View {
        List {
            if model.recoveryFailed { Text(L10n.string("mobile.activity.recovery-error")).foregroundStyle(.red) }
            ForEach(model.state.itemResults) { result in
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.name).font(.headline)
                    Text(L10n.string(Self.resultKey(result.status))).foregroundStyle(.secondary)
                    if let link = result.link, model.trustedManagedURL(link) != nil {
                        Button(L10n.string("mobile.files.share-link.action.copy")) { model.copyLinks([link]) }
                        Button(L10n.string("mobile.files.share-link.action.share")) { model.presentManagedLinkShare(link) }
                        Button(L10n.string("files.sharing.qr")) { qrLink = link }
                    }
                }
            }
            if model.state.itemResults.contains(where: { $0.link != nil }) {
                Button(L10n.string("files.sharing.copySelected")) { model.copyLinks(model.state.itemResults.compactMap(\.link)) }
            }
            if model.state.copied { Text(L10n.string("mobile.files.share-link.copied")) }
            Button(L10n.string("mobile.files.share-link.management.return")) { model.returnToManagement() }
            Button(L10n.string("mobile.files.share-link.action.done")) { model.dismiss() }
        }.accessibilityIdentifier("sharing.results")
    }

    static func statusKey(_ status: FileShareLinkStatus) -> String {
        switch status {
        case .valid: "files.sharing.status.valid"
        case .invalid: "files.sharing.status.invalid"
        case .inactive: "files.sharing.status.inactive"
        case .expired: "files.sharing.status.expired"
        case .broken: "files.sharing.status.broken"
        case .unknown: "files.sharing.status.unknown"
        }
    }

    static func resultKey(_ status: MutationResultStatus) -> String {
        switch status {
        case .confirmedSuccess: "mobile.sharing.result-success"
        case .confirmedFailure: "files.sharing.changeFailed"
        case .permissionDenied: "files.sharing.denied"
        case .unsupported: "files.sharing.manageUnsupported"
        case .cancelledBeforeSubmission: "files.sharing.cancelled"
        default: "mobile.sharing.result-unavailable"
        }
    }

    private func managedLinkRow(_ link: FileShareLink) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(link.name, systemImage: link.advanced?.isFileRequest == true ? "tray.and.arrow.down" : "link")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(Self.statusKey(link.status ?? .unknown)))
                if let value = link.availableAt, let date = Self.expirationDate(String(value.prefix(10)), timeZone: .current) {
                    Text(L10n.string("files.sharing.availableOn", date.formatted(.dateTime.year().month().day().locale(L10n.locale))))
                }
                if model.state.blockedLinkIDs.contains(link.id) { Text(L10n.string("mobile.sharing.result-unavailable")) }
                if link.hasPassword {
                    Label(L10n.string("mobile.files.share-link.protected"), systemImage: "lock.fill")
                }
                if let formattedExpiration = localizedExpiration(for: link) {
                    Label(
                        L10n.string("mobile.files.share-link.expires", formattedExpiration),
                        systemImage: "calendar"
                    )
                } else {
                    Label(L10n.string("mobile.files.share-link.expiration.never"), systemImage: "calendar")
                }
                if model.state.copiedManagedLinkID == link.id {
                    Text(L10n.string("mobile.files.share-link.copied"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits([.isStaticText, .updatesFrequently])
                }
            }
            .font(.callout)
            ViewThatFits(in: .horizontal) {
                managedLinkActions(link, horizontal: true)
                managedLinkActions(link, horizontal: false)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func managedLinkActions(_ link: FileShareLink, horizontal: Bool) -> some View {
        let content = Group {
            Button {
                model.copyManagedLink(link)
            } label: {
                Label(L10n.string("mobile.files.share-link.action.copy"), systemImage: "doc.on.doc")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!canUseManagedLink(link))
            Button {
                model.presentManagedLinkShare(link)
            } label: {
                Label(L10n.string("mobile.files.share-link.action.share"), systemImage: "square.and.arrow.up")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!canUseManagedLink(link))
            Menu {
                Button(L10n.string("files.sharing.edit")) { editSelection = .init(links: [link]) }
                    .disabled(model.state.blockedLinkIDs.contains(link.id) || model.recoveryFailed)
                if link.advanced != nil {
                    Button(L10n.string("files.sharing.accessSettings")) { editSelection = .init(links: [link], advanced: true) }
                        .disabled(model.state.blockedLinkIDs.contains(link.id) || model.recoveryFailed)
                }
                Button(L10n.string("files.sharing.qr")) { qrLink = link }.disabled(!canUseManagedLink(link))
                Button(role: .destructive) { model.beginDeleteManagedLink(link) } label: {
                    Label(L10n.string("mobile.files.share-link.delete.action"), systemImage: "trash")
                }.disabled(model.state.blockedLinkIDs.contains(link.id) || model.recoveryFailed)
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.bordered).accessibilityLabel(L10n.string("workspace.actions.more"))
                .accessibilityIdentifier("sharing.row.more." + link.id)
        }
        if horizontal {
            HStack(spacing: 8) { content }
        } else {
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }

    private func statusView<Actions: View>(
        systemImage: String,
        title: String,
        message: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title).font(.headline).multilineTextAlignment(.center)
                if let message {
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                actions()
            }
            .padding(24)
            .frame(maxWidth: 520, minHeight: 320)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var failureActions: some View {
        VStack(spacing: 12) {
            if model.state.canRetry {
                Button(L10n.string("mobile.files.share-link.action.retry")) { model.retryCreation() }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 44, minHeight: 44)
            }
            dismissButton
        }
    }

    @ViewBuilder private var managementEmptyActions: some View {
        VStack(spacing: 12) {
            if model.state.target != nil { Button {
                model.showCreateFormFromManagement()
            } label: {
                Label(
                    L10n.string("mobile.files.share-link.action.create"),
                    systemImage: "link.badge.plus"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent) }
            dismissButton
        }
    }

    @ViewBuilder private var managementErrorActions: some View {
        VStack(spacing: 12) {
            Button {
                model.refreshManagement()
            } label: {
                Label(
                    L10n.string("mobile.files.share-link.management.refresh"),
                    systemImage: "arrow.clockwise"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            dismissButton
        }
    }

    @ViewBuilder private var deleteConfirmActions: some View {
        VStack(spacing: 12) {
            Button(role: .destructive) {
                model.confirmDeleteManagedLink()
            } label: {
                Label(L10n.string("mobile.files.share-link.delete.confirm.action"), systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            Button(L10n.string("mobile.files.share-link.action.cancel")) {
                model.cancelDeleteManagedLink()
            }
            .frame(minWidth: 44, minHeight: 44)
        }
    }

    private var returnToManagementButton: some View {
        Button(L10n.string("mobile.files.share-link.management.return")) {
            model.dismissDeletionFeedback()
        }
        .frame(minWidth: 44, minHeight: 44)
    }

    private var dismissButton: some View {
        Button(L10n.string("mobile.files.share-link.action.dismiss")) { model.dismiss() }
            .frame(minWidth: 44, minHeight: 44)
    }

    private var failureMessage: String {
        switch model.state.failure {
        case .permission: L10n.string("mobile.files.share-link.failure.permission")
        case .changed: L10n.string("mobile.files.share-link.failure.changed")
        case .unsupported: L10n.string("mobile.files.share-link.failure.unsupported")
        case .duplicate: L10n.string("mobile.files.share-link.failure.duplicate")
        case .recovery: L10n.string("mobile.activity.recovery-error")
        case .generic, nil: L10n.string("mobile.files.share-link.failure.generic")
        }
    }

    private var deletionFailureMessage: String {
        switch model.state.deletionFailure {
        case .permission: L10n.string("mobile.files.share-link.delete.failure.permission")
        case .changed: L10n.string("mobile.files.share-link.delete.failure.changed")
        case .unsupported: L10n.string("mobile.files.share-link.delete.failure.unsupported")
        case .duplicate: L10n.string("mobile.files.share-link.delete.failure.duplicate")
        case .recovery: L10n.string("mobile.activity.recovery-error")
        case .generic, nil: L10n.string("mobile.files.share-link.delete.failure.generic")
        }
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { model.state.password },
            set: { value in model.setPassword(value) }
        )
    }

    private var expirationBinding: Binding<MobileFileShareLinkExpiration> {
        Binding(
            get: { model.state.expiration },
            set: { value in model.setExpiration(value) }
        )
    }

    private var sharePresentationBinding: Binding<MobileFileSharePresentation?> {
        Binding(get: { model.state.sharePresentation }, set: { if $0 == nil { model.shareDidDismiss() } })
    }

    private var localizedExpiration: String? {
        guard let value = model.state.confirmedLink?.expiresAt,
              let date = Self.expirationDate(value, timeZone: .current) else { return nil }
        return date.formatted(.dateTime.year().month().day().locale(L10n.locale))
    }

    private func localizedExpiration(for link: FileShareLink) -> String? {
        guard let value = link.expiresAt,
              let date = Self.expirationDate(value, timeZone: .current) else { return nil }
        return date.formatted(.dateTime.year().month().day().locale(L10n.locale))
    }

    private func canUseManagedLink(_ link: FileShareLink) -> Bool { model.trustedManagedURL(link) != nil }

    static func expirationDate(_ value: String, timeZone: TimeZone) -> Date? {
        guard let calendarDate = try? FileShareLinkCalendarDate(iso8601: String(value.prefix(10))) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: calendarDate.year,
            month: calendarDate.month,
            day: calendarDate.day
        ))
    }
}
