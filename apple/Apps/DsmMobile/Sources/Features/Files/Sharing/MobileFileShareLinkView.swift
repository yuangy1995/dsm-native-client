import DsmCore
import DsmLocalization
import Foundation
import SwiftUI

struct MobileFileShareLinkView: View {
    @Bindable var model: MobileFileShareLinkModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Group {
                switch model.state.phase {
                case .form: form
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
                    ) { dismissButton }
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
                        message: L10n.string("mobile.files.share-link.management.empty.message")
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
        .interactiveDismissDisabled(model.state.phase == .creating || model.state.phase == .deleting)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: sharePresentationBinding) { presentation in
            MobileShareSheet(url: presentation.url) { model.shareDidDismiss() }
        }
    }

    private var navigationTitle: String {
        switch model.state.phase {
        case .managementLoading, .managementEmpty, .managementContent, .managementError,
             .managementUnsupported, .deletionConfirm, .deleting, .deletionConfirmed,
             .deletionReviewRequired, .deletionFailure:
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
                Text(L10n.string("mobile.files.share-link.target", model.state.target?.name ?? ""))
                Text(L10n.string("mobile.files.share-link.access-note"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                SecureField(L10n.string("mobile.files.share-link.password.label"), text: passwordBinding)
                    .textContentType(.newPassword)
                Text(L10n.string("mobile.files.share-link.password.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker(L10n.string("mobile.files.share-link.expiration.label"), selection: expirationBinding) {
                    ForEach(MobileFileShareLinkExpiration.allCases) { expiration in
                        Text(L10n.string(expiration.resourceKey)).tag(expiration)
                    }
                }
            }
            Section {
                Button {
                    model.submit()
                } label: {
                    Text(L10n.string("mobile.files.share-link.action.submit"))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmit)
            }
        }
    }

    private var success: some View {
        statusView(
            systemImage: "checkmark.circle.fill",
            title: L10n.string("mobile.files.share-link.success.title"),
            message: L10n.string("mobile.files.share-link.success.message")
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
                Button(L10n.string("mobile.files.share-link.action.done")) { model.dismiss() }
                    .frame(minHeight: 44)
            }
        }
    }

    private var managementList: some View {
        List {
            Section {
                Text(L10n.string("mobile.files.share-link.management.target", model.state.target?.name ?? ""))
                Text(L10n.string("mobile.files.share-link.management.access-note"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(model.state.managedLinks) { link in
                    managedLinkRow(link)
                }
                if model.state.managedLinksTruncated {
                    Label(
                        L10n.string("mobile.files.share-link.management.truncated"),
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    model.showCreateFormFromManagement()
                } label: {
                    Label(
                        L10n.string("mobile.files.share-link.action.create"),
                        systemImage: "link.badge.plus"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
    }

    private func managedLinkRow(_ link: FileShareLink) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.string("mobile.files.share-link.management.row.title"), systemImage: "link")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
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
            Button(role: .destructive) {
                model.beginDeleteManagedLink(link)
            } label: {
                Label(L10n.string("mobile.files.share-link.delete.action"), systemImage: "trash")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
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
                Button(L10n.string("mobile.files.share-link.action.retry")) { model.submit() }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 44, minHeight: 44)
            }
            dismissButton
        }
    }

    @ViewBuilder private var managementEmptyActions: some View {
        VStack(spacing: 12) {
            Button {
                model.showCreateFormFromManagement()
            } label: {
                Label(
                    L10n.string("mobile.files.share-link.action.create"),
                    systemImage: "link.badge.plus"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
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
        case .generic, nil: L10n.string("mobile.files.share-link.failure.generic")
        }
    }

    private var deletionFailureMessage: String {
        switch model.state.deletionFailure {
        case .permission: L10n.string("mobile.files.share-link.delete.failure.permission")
        case .changed: L10n.string("mobile.files.share-link.delete.failure.changed")
        case .unsupported: L10n.string("mobile.files.share-link.delete.failure.unsupported")
        case .duplicate: L10n.string("mobile.files.share-link.delete.failure.duplicate")
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
        return date.formatted(.dateTime.year().month().day())
    }

    private func localizedExpiration(for link: FileShareLink) -> String? {
        guard let value = link.expiresAt,
              let date = Self.expirationDate(value, timeZone: .current) else { return nil }
        return date.formatted(.dateTime.year().month().day())
    }

    private func canUseManagedLink(_ link: FileShareLink) -> Bool {
        guard let target = model.state.target,
              link.path == target.path,
              let url = URL(string: link.url) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
            url.host != nil &&
            url.user == nil &&
            url.password == nil
    }

    static func expirationDate(_ value: String, timeZone: TimeZone) -> Date? {
        guard let calendarDate = try? FileShareLinkCalendarDate(iso8601: value) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: calendarDate.year,
            month: calendarDate.month,
            day: calendarDate.day
        ))
    }
}
