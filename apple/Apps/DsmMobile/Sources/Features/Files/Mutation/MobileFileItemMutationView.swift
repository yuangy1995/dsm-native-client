import DsmLocalization
import SwiftUI

struct MobileFileItemMutationView: View {
    @Bindable var mutation: MobileFileItemMutationModel
    let repository: any MobileFileItemMutating
    let didConfirm: (MobileFileItemMutationSuccess) async -> Void
    @State private var showsRenameConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if let presentation = mutation.presentation {
                    if presentation.phase == .review {
                        reviewView(feedback: presentation.feedback)
                    } else {
                        mutationForm(presentation)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { mutationToolbar }
            .confirmationDialog(
                L10n.string("mobile.files.mutation.rename.confirm.title", sourceName),
                isPresented: $showsRenameConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.string("mobile.files.mutation.rename.confirm.action")) {
                    performSubmit()
                }
                Button(L10n.string("mobile.files.mutation.cancel"), role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(mutation.presentation?.phase == .submitting)
    }

    private func mutationForm(_ presentation: MobileFileItemMutationPresentation) -> some View {
        Form {
            Section {
                TextField(placeholder, text: nameBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .accessibilityLabel(L10n.string("mobile.files.mutation.name.label"))
                    .onSubmit { requestSubmit() }
            } header: {
                Text(L10n.string("mobile.files.mutation.name.label"))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("mobile.files.mutation.name.help"))
                    if let feedback = presentation.feedback {
                        Label(feedbackMessage(feedback), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .accessibilityLabel(feedbackMessage(feedback))
                    }
                }
            }

            Section {
                Text(presentation.parentPath)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel(
                        L10n.string("mobile.files.mutation.path.accessibility", presentation.parentPath)
                    )
            }

            if presentation.phase == .submitting {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.string("mobile.files.mutation.working"))
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }

    private func reviewView(feedback: MobileFileItemMutationFeedback?) -> some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.files.mutation.review.title"),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(reviewMessage(feedback))
        } actions: {
            Button(L10n.string("mobile.files.mutation.review.dismiss")) {
                mutation.dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(minWidth: 44, minHeight: 44)
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    @ToolbarContentBuilder
    private var mutationToolbar: some ToolbarContent {
        if mutation.presentation?.phase == .review {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string("mobile.files.mutation.review.dismiss")) {
                    mutation.dismiss()
                }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string("mobile.files.mutation.cancel")) {
                    if mutation.presentation?.phase == .submitting {
                        mutation.requestCancellation()
                    } else {
                        mutation.dismiss()
                    }
                }
                .frame(minHeight: 44)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(submitTitle) { requestSubmit() }
                    .disabled(!canSubmit)
                    .frame(minHeight: 44)
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { mutation.presentation?.name ?? "" },
            set: { value in mutation.setName(value) }
        )
    }

    private var title: String {
        switch mutation.presentation?.kind {
        case .createFolder:
            L10n.string("mobile.files.mutation.create.title")
        case .rename:
            L10n.string("mobile.files.mutation.rename.title")
        case nil:
            ""
        }
    }

    private var placeholder: String {
        mutation.presentation?.kind == .rename
            ? L10n.string("mobile.files.mutation.rename.placeholder")
            : L10n.string("mobile.files.mutation.create.placeholder")
    }

    private var submitTitle: String {
        mutation.presentation?.kind == .rename
            ? L10n.string("mobile.files.mutation.rename.action")
            : L10n.string("mobile.files.mutation.create.submit")
    }

    private var sourceName: String {
        mutation.presentation?.sourceItem?.name ?? ""
    }

    private var canSubmit: Bool {
        guard let presentation = mutation.presentation else { return false }
        return presentation.phase == .editing &&
            !presentation.requiresNameChange &&
            MobileFileItemMutationModel.isValidName(presentation.name)
    }

    private func requestSubmit() {
        guard canSubmit else { return }
        if mutation.presentation?.kind == .rename {
            showsRenameConfirmation = true
        } else {
            performSubmit()
        }
    }

    private func performSubmit() {
        Task {
            if let success = await mutation.submit(repository: repository) {
                await didConfirm(success)
            }
        }
    }

    private func feedbackMessage(_ feedback: MobileFileItemMutationFeedback) -> String {
        switch feedback {
        case .invalidName:
            L10n.string("mobile.files.mutation.error.invalid-name")
        case .unavailable:
            L10n.string("mobile.files.mutation.error.unavailable")
        case .permission:
            L10n.string("mobile.files.mutation.error.permission")
        case .conflict:
            L10n.string("mobile.files.mutation.error.conflict")
        case .authentication:
            L10n.string("mobile.files.mutation.error.authentication")
        case .unknown:
            L10n.string("mobile.files.mutation.error.unknown")
        }
    }

    private func reviewMessage(_ feedback: MobileFileItemMutationFeedback?) -> String {
        guard let feedback, feedback != .unknown else {
            return L10n.string("mobile.files.mutation.review.message")
        }
        return feedbackMessage(feedback)
    }
}
