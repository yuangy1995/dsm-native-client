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
                }
            }
            .navigationTitle(L10n.string("mobile.files.share-link.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.state.phase == .form {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("mobile.files.share-link.action.cancel")) { model.dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.state.phase == .creating)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: sharePresentationBinding) { presentation in
            MobileShareSheet(url: presentation.url) { model.shareDidDismiss() }
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
