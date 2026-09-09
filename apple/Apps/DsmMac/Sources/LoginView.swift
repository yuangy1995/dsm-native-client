import DsmCore
import DsmLocalization
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let workspace = model.workspace {
                WorkspaceView(
                    model: workspace,
                    profiles: model.profiles,
                    selectedProfileID: model.selectedProfileID,
                    connectedWorkspaces: model.connectedWorkspaces,
                    connectionRoute: model.currentConnectionRoute,
                    onAddNAS: {
                        model.newProfile()
                    },
                    onSelectNAS: { profileID in
                        model.selectProfile(id: profileID)
                    },
                    onMoveProfiles: { source, destination in
                        model.moveProfile(from: source, to: destination)
                    },
                    hasFileClipboard: model.fileClipboard != nil && !model.isPreparingPaste,
                    onCopy: { items in model.placeOnClipboard(items, moveSource: false) },
                    onCut: { items in model.placeOnClipboard(items, moveSource: true) },
                    onPaste: model.pasteClipboardIntoCurrentFolder,
                    onRenameNAS: { name in model.renameCurrentNAS(to: name) },
                    onLogout: {
                        await model.logout()
                    },
                    onSessionExpired: { message in
                        await model.returnToLoginAfterSessionIssue(message: message, from: workspace)
                    }
                )
                .id(ObjectIdentifier(workspace))
            } else {
                LoginView(model: model)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .alert(L10n.string("ui.ca990601036ccf0f"), isPresented: Binding(
            get: { model.pendingPasteConflict != nil },
            set: { if !$0 { model.cancelPendingPaste() } }
        )) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {
                model.cancelPendingPaste()
            }
            Button(L10n.string("ui.d4641f3877665e85")) {
                model.resolvePendingPaste(replaceExisting: false)
            }
            Button(L10n.string("ui.0da1fcb3db46922e"), role: .destructive) {
                model.resolvePendingPaste(replaceExisting: true)
            }
        } message: {
            if let prompt = model.pendingPasteConflict {
                Text(pasteConflictMessage(prompt))
            }
        }
    }

    private func pasteConflictMessage(_ prompt: PasteConflictPrompt) -> String {
        let count = prompt.conflictingNames.count
        let examples = prompt.conflictingNames.prefix(3).map { "“\($0)”" }.joined(separator: "、")
        let suffix = count > 3
            ? L10n.string("items.more_total", String(count))
            : ""
        return L10n.string("ui.d135edaf7bff82c2", String(describing: examples), String(describing: suffix))
    }
}

struct LoginView: View {
    enum Field: Hashable {
        case displayName
        case host
        case port
        case account
        case password
        case otp
    }

    @Bindable var model: AppModel
    @FocusState private var focusedField: Field?
    @State private var confirmsProfileDeletion = false
    @State private var showsAdvancedConnectionSettings = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var palette: MacAppearancePalette {
        MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.string("app.name"))
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .allowsHitTesting(false)
            HStack(spacing: 12) {
                profileSidebar.frame(width: 241)
                connectionForm
                    .fillsAvailableContentArea(alignment: .topLeading)
                    .background(MacGlassSurface(role: .content))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(palette.edge, lineWidth: 1))
                    .padding(.trailing, 12)
            }
            .environment(\.macUsesContentBackground, true)
            .padding(.bottom, 12)
        }
        .background(MacGlassSurface(role: .sidebar).ignoresSafeArea())
        .background(MacWorkspaceWindowChrome(fullSize: true))
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle("")
        .toolbar(.visible, for: .windowToolbar)
        .macSheet(item: $model.pendingCertificate) { prompt in
            CertificateReviewView(
                prompt: prompt,
                onCancel: model.cancelCertificateReview,
                onTrust: {
                    Task { await model.acceptPendingCertificate() }
                }
            )
        }
        .alert(L10n.string("ui.2f97b2d9801263d5"), isPresented: $confirmsProfileDeletion) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
            Button(L10n.string("ui.6135d4159e892541"), role: .destructive) {
                Task { await model.deleteSelectedProfile() }
            }
        } message: {
            Text(L10n.string("ui.1a6ef7d4ed0db37d"))
        }
        .onChange(of: model.requiresOTP) { _, required in
            if required {
                focusedField = .otp
            }
        }
    }

    private var profileSidebar: some View {
        VStack(spacing: 0) {
            Text(L10n.string("ui.4084e8707628b196"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            ScrollView {
                VStack(spacing: 10) {
                    if model.profiles.isEmpty {
                        Text(L10n.string("login.devices.empty"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(20)
                    }
                    ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
                        let selected = profile.id == model.selectedProfileID
                        Button { model.selectedProfileID = profile.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "externaldrive.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                                    .frame(width: 38, height: 44)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(profile.displayName).font(.system(size: 14, weight: .medium))
                                    Text(profile.portOverride.map { "\(profile.host):\($0)" } ?? profile.host)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(MacSelectionSurface(isSelected: selected, cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? palette.selectionBorder : palette.separator.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .contextMenu {
                            Button(L10n.string("workspace.device.moveUp")) {
                                model.moveProfile(from: IndexSet(integer: index), to: index - 1)
                            }
                            .disabled(index == 0)
                            Button(L10n.string("workspace.device.moveDown")) {
                                model.moveProfile(from: IndexSet(integer: index), to: index + 2)
                            }
                            .disabled(index == model.profiles.count - 1)
                            Divider()
                            Button(L10n.string("ui.937455cd6b3ade37"), role: .destructive) {
                                model.selectedProfileID = profile.id
                                model.selectProfile(id: profile.id)
                                confirmsProfileDeletion = true
                            }
                        }
                        .draggable(profile.id.uuidString)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let value = ids.first, let id = UUID(uuidString: value),
                                  let source = model.profiles.firstIndex(where: { $0.id == id }),
                                  source != index else { return false }
                            model.moveProfile(from: IndexSet(integer: source), to: source < index ? index + 1 : index)
                            return true
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .onChange(of: model.selectedProfileID) { _, id in
                model.selectProfile(id: id)
            }
            .onMoveCommand { direction in
                guard let selectedID = model.selectedProfileID,
                      let currentIndex = model.profiles.firstIndex(where: { $0.id == selectedID }) else { return }
                let destination: Int
                switch direction {
                case .up:
                    destination = max(0, currentIndex - 1)
                case .down:
                    destination = min(model.profiles.count, currentIndex + 2)
                default:
                    return
                }
                model.moveProfile(from: IndexSet(integer: currentIndex), to: destination)
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    model.newProfile()
                    focusedField = .displayName
                } label: {
                    Label(L10n.string("ui.8249cd04be30c505"), systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(MacToolbarButtonStyle())
                AppLanguagePicker()
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .macThemedMenu()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
            .padding(12)
        }
    }

    private var connectionForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image("BrandLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 48, height: 48)
                            .clipShape(.rect(cornerRadius: 12))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.string("ui.4aeb6d92cbbff699"))
                                .font(.largeTitle.weight(.semibold))
                        }
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                            formRow(L10n.string("ui.65d8f92232ae77b0")) {
                                TextField(L10n.string("ui.f7fbaa6885cef77f"), text: $model.displayName)
                                    .focused($focusedField, equals: .displayName)
                            }
                            formRow(L10n.string("ui.43556f7a25fa8a40")) {
                                TextField(
                                    L10n.string("ui.69134ccb69402771"),
                                    text: $model.host
                                )
                                .textContentType(.URL)
                                .accessibilityLabel(L10n.string("ui.43556f7a25fa8a40"))
                                .accessibilityHint(L10n.string("ui.dbafdf9f504024ca"))
                                .focused($focusedField, equals: .host)
                            }
                            formRow(L10n.string("ui.1a3f0617d6de8e52")) {
                                TextField(L10n.string("ui.f15e1db7f812e8f6"), text: $model.account)
                                    .textContentType(.username)
                                    .focused($focusedField, equals: .account)
                            }
                            formRow(L10n.string("ui.a621ab606db2a11f")) {
                                VStack(alignment: .leading, spacing: 6) {
                                    SecureField(
                                        model.rememberPassword ? L10n.string("ui.54d0d38482318246") : L10n.string("ui.9582b20c3033f7e7"),
                                        text: $model.password
                                    )
                                    .textContentType(.password)
                                    .focused($focusedField, equals: .password)
                                    HStack(spacing: 18) {
                                        Toggle(
                                            L10n.string("ui.bdc9de6d5b27252a"),
                                            isOn: Binding(
                                                get: { model.rememberPassword },
                                                set: { model.setRememberPassword($0) }
                                            )
                                        )
                                        .help(L10n.string("ui.9160329adfe46deb"))

                                        Toggle(
                                            L10n.string("ui.afe5b2261f44779b"),
                                            isOn: Binding(
                                                get: { model.autoLoginEnabled },
                                                set: { model.setAutoLoginEnabled($0) }
                                            )
                                        )
                                        .help(L10n.string("ui.de77ca440f384385"))
                                    }
                                    .toggleStyle(.checkbox)
                                    .font(.callout)
                                }
                            }
                            if model.requiresOTP {
                                formRow(L10n.string("ui.bb015c60bafc8a96")) {
                                    SecureField(L10n.string("ui.a8d7dd5511095e27"), text: $model.otpCode)
                                        .textContentType(.oneTimeCode)
                                        .focused($focusedField, equals: .otp)
                                }
                            }
                        }

                        Divider()

                        DisclosureGroup(isExpanded: $showsAdvancedConnectionSettings) {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                                formRow(L10n.string("ui.7f7683678a7b89c7")) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        TextField(L10n.string("ui.7eb336e42cb5076b"), text: $model.port)
                                            .frame(maxWidth: 140)
                                            .focused($focusedField, equals: .port)
                                    }
                                }
                            }
                            .padding(.top, 10)
                        } label: {
                            Label(L10n.string("ui.c6d9285846a8f1b4"), systemImage: "gearshape")
                        }
                    }
                    .textFieldStyle(.plain)
                    .disabled(model.isBusy)
                    .padding(8)
                } label: {
                    Label(L10n.string("ui.878a54914634ff30"), systemImage: "lock.shield")
                }

                StatusBanner(
                    message: model.statusMessage,
                    isError: model.statusIsError,
                    isBusy: model.isBusy
                )

                HStack(spacing: 12) {
                    if model.isBusy {
                        Button(L10n.string("ui.531c764f9b4eea01"), role: .cancel) {
                            model.cancelLogin()
                        }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)

                        Spacer()
                    } else {
                        Button {
                            Task { await model.connect() }
                        } label: {
                            Label(
                                model.requiresOTP ? L10n.string("ui.f7b3ea5623b03787") : L10n.string("ui.a5574109f0208e89"),
                                systemImage: "arrow.right.circle.fill"
                            )
                            .frame(minWidth: 112)
                        }
                        .buttonStyle(MacToolbarButtonStyle(prominent: true))
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            model.host.isEmpty || model.account.isEmpty || model.password.isEmpty
                                || (model.requiresOTP && model.otpCode.isEmpty)
                        )

                        Spacer()

                        if model.selectedProfileID != nil {
                            Button(L10n.string("ui.937455cd6b3ade37"), role: .destructive) {
                                confirmsProfileDeletion = true
                            }
                        }
                    }
                }

                Label(
                    L10n.string("ui.3659936f4893e4e0"),
                    systemImage: "checkmark.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(MacGlassSurface(role: .content))
    }

    private func formRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.callout).foregroundStyle(.secondary)
                content()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.searchField, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.separator, lineWidth: 1))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StatusBanner: View {
    let message: String
    let isError: Bool
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(isError ? .red : .blue)
                    .accessibilityHidden(true)
            }
            Text(message)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(12)
        .background(isError ? Color.red.opacity(0.08) : Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.string(
                "status.accessibility",
                isBusy
                    ? L10n.string("status.connection")
                    : (isError ? L10n.string("status.connection_failed") : L10n.string("status.notice")),
                message
            )
        )
    }
}

struct CertificateReviewView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let prompt: CertificatePrompt
    let onCancel: () -> Void
    let onTrust: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: prompt.isCertificateChange ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(prompt.isCertificateChange ? .red : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.isCertificateChange ? L10n.string("ui.df63652c91aaa224") : L10n.string("ui.fe279c5bb7ff4c0e"))
                        .font(.title2.weight(.semibold))
                    Text(prompt.review.host)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(MacGlassSurface(role: .toolbar).clipShape(RoundedRectangle(cornerRadius: 12)))

            Text(
                prompt.isCertificateChange
                    ? L10n.string("ui.5eb8087116363084")
                    : L10n.string("ui.e0ce767ce95e74bd")
            )

            GroupBox(L10n.string("ui.a248168e2ac8ff7f")) {
                LabeledContent(L10n.string("ui.8b858fd6348847c3"), value: prompt.review.host)
                LabeledContent(L10n.string("ui.42f5efe784424e46"), value: prompt.review.subjectSummary)
                LabeledContent(L10n.string("ui.3f8ac393c2bd409d")) {
                    Text(prompt.review.formattedFingerprint)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let previous = prompt.formattedPreviousFingerprint, prompt.isCertificateChange {
                GroupBox(L10n.string("ui.ea17b7b4598882f4")) {
                    Text(previous)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if !prompt.review.canBePinned {
                Label(L10n.string("ui.59d36149bb6463e0"), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if prompt.review.canBePinned {
                    Button(prompt.isCertificateChange ? L10n.string("ui.ad322e611f3195f0") : L10n.string("ui.1f30f490b6eb4a19"), action: onTrust)
                        .buttonStyle(MacToolbarButtonStyle(prominent: true))
                }
            }
            .buttonStyle(MacToolbarButtonStyle())
        }
        .padding(28)
        .frame(width: 620)
        .background(MacGlassSurface(role: .content))
    }
}
