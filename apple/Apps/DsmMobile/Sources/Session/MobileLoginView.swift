import DsmCore
import DsmLocalization
import SwiftUI

struct MobileLoginView: View {
    @Bindable var model: MobileAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var profileToRemove: NasProfile?
    @State private var showsAdvancedConnectionSettings = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    if horizontalSizeClass == .regular {
                        HStack(alignment: .top, spacing: 36) {
                            savedProfiles
                                .frame(width: min(340, proxy.size.width * 0.34))
                            loginForm
                                .frame(maxWidth: 520)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(32)
                    } else {
                        VStack(spacing: 24) {
                            brandHeader
                            if !model.profiles.isEmpty {
                                savedProfiles
                            }
                            loginForm
                        }
                        .padding(20)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(L10n.string("ui.4aeb6d92cbbff699"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AppLanguagePicker()
                        .labelsHidden()
                        .pickerStyle(.menu)
                }
            }
        }
        .confirmationDialog(
            L10n.string(
                "profile.remove.confirm",
                profileToRemove?.displayName ?? ""
            ),
            isPresented: Binding(
                get: { profileToRemove != nil },
                set: { if !$0 { profileToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.6135d4159e892541"), role: .destructive) {
                if let profileToRemove {
                    model.removeProfile(profileToRemove)
                }
                profileToRemove = nil
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {
                profileToRemove = nil
            }
        } message: {
            Text(L10n.string("ui.1a6ef7d4ed0db37d"))
        }
        .sheet(item: $model.pendingCertificate) { prompt in
            MobileCertificateReviewView(
                prompt: prompt,
                onCancel: model.cancelCertificateReview,
                onTrust: model.acceptPendingCertificate
            )
            .interactiveDismissDisabled()
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 16) {
            Image("BrandLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 68, height: 68)
                .clipShape(.rect(cornerRadius: 18))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("ui.4aeb6d92cbbff699"))
                    .font(.largeTitle.bold())
                Text(L10n.string("app.name"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var savedProfiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            if horizontalSizeClass == .regular {
                brandHeader
                    .padding(.bottom, 8)
            }
            HStack {
                Text(L10n.string("ui.df2b9b2dc2e69cf5"))
                    .font(.headline)
                Spacer()
                Button {
                    model.newProfile()
                } label: {
                    Label(L10n.string("ui.7a8a11ead50742a2"), systemImage: "plus")
                }
            }
            ForEach(model.profiles) { profile in
                Button {
                    model.selectProfile(profile)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.title3)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            Text(profile.usernameHint ?? profile.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.restore(profile)
                        } label: {
                            Image(systemName: "play.fill")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.string("ui.d2bf10e7bab2699a"))
                        Button(role: .destructive) {
                            profileToRemove = profile
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.string("ui.06a972a9c2683c33"))
                    }
                    .padding(12)
                    .background(
                        model.selectedProfileID == profile.id
                            ? Color.blue.opacity(0.12)
                            : Color.secondary.opacity(0.08),
                        in: .rect(cornerRadius: 14)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("ui.3b0927418e9ca90b"))
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            TextField(L10n.string("ui.a98585871c5313ff"), text: $model.displayName)
                .textContentType(.organizationName)
                .textFieldStyle(.roundedBorder)
            TextField(
                L10n.string("ui.add3d846c43e6f54"),
                text: $model.host,
                prompt: Text(L10n.string("ui.0eb5bf18b9814bd1"))
            )
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            TextField(L10n.string("ui.311bb313fdeca6aa"), text: $model.username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField(L10n.string("ui.a621ab606db2a11f"), text: $model.password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.connect() }
            if model.needsOTP || !model.otpCode.isEmpty {
                TextField(L10n.string("ui.0c00c2f57088c5fa"), text: $model.otpCode)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle(
                L10n.string("ui.9327bc0813de581c"),
                isOn: Binding(
                    get: { model.rememberPassword },
                    set: { enabled in
                        model.rememberPassword = enabled
                        if !enabled {
                            model.autoLoginEnabled = false
                        }
                    }
                )
            )
            Text(L10n.string("ui.b7a6112dd90ce389"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                L10n.string("ui.afe5b2261f44779b"),
                isOn: Binding(
                    get: { model.autoLoginEnabled },
                    set: { enabled in
                        model.autoLoginEnabled = enabled
                        if enabled {
                            model.rememberPassword = true
                        }
                    }
                )
            )
            Text(L10n.string("ui.4eb0633bb44abe01"))
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup(
                isExpanded: $showsAdvancedConnectionSettings
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L10n.string("ui.9aa2d5f46c68bf78"), text: $model.port)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Text(L10n.string("ui.7ea0491272acd294"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } label: {
                Label(L10n.string("ui.c6d9285846a8f1b4"), systemImage: "gearshape")
            }
            if let connectionStatus = model.connectionStatus {
                Label(connectionStatus, systemImage: "network")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
            }
            if let loginError = model.loginError {
                Label(loginError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.1), in: .rect(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
            }
            if model.isConnecting {
                Button(role: .cancel) {
                    model.cancelConnection()
                } label: {
                    Label(L10n.string("ui.2cd0f3be8738a86c"), systemImage: "xmark")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button {
                    model.connect()
                } label: {
                    Text(L10n.string("ui.a5574109f0208e89"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
    }
}

private struct MobileCertificateReviewView: View {
    let prompt: MobileCertificatePrompt
    let onCancel: () -> Void
    let onTrust: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    Text(
                        prompt.isCertificateChange
                            ? L10n.string("ui.5eb8087116363084")
                            : L10n.string("ui.e0ce767ce95e74bd")
                    )
                    .font(.body)

                    certificateDetails

                    if let previous = prompt.formattedPreviousFingerprint,
                       prompt.isCertificateChange {
                        fingerprintGroup(
                            title: L10n.string("ui.ea17b7b4598882f4"),
                            value: previous
                        )
                    }

                    if !prompt.allowsPinning {
                        Label(
                            L10n.string("ui.59d36149bb6463e0"),
                            systemImage: "xmark.octagon.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                actions
            }
            .navigationTitle(
                prompt.isCertificateChange
                    ? L10n.string("ui.df63652c91aaa224")
                    : L10n.string("ui.fe279c5bb7ff4c0e")
            )
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(
                systemName: prompt.isCertificateChange
                    ? "exclamationmark.shield.fill"
                    : "checkmark.shield.fill"
            )
            .font(.system(size: 34))
            .foregroundStyle(prompt.isCertificateChange ? .red : .orange)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    prompt.isCertificateChange
                        ? L10n.string("ui.df63652c91aaa224")
                        : L10n.string("ui.fe279c5bb7ff4c0e")
                )
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                Text(prompt.review.host)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var certificateDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("ui.a248168e2ac8ff7f"))
                .font(.headline)
            LabeledContent(L10n.string("ui.8b858fd6348847c3")) {
                Text(prompt.review.host)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(L10n.string("ui.42f5efe784424e46")) {
                Text(prompt.review.subjectSummary)
                    .multilineTextAlignment(.trailing)
            }
            fingerprintGroup(
                title: L10n.string("ui.3f8ac393c2bd409d"),
                value: prompt.review.formattedFingerprint
            )
        }
        .padding(16)
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 16))
    }

    private func fingerprintGroup(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if prompt.allowsPinning {
                Button(action: onTrust) {
                    Text(
                        prompt.isCertificateChange
                            ? L10n.string("ui.ad322e611f3195f0")
                            : L10n.string("ui.1f30f490b6eb4a19")
                    )
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Button(role: .cancel, action: onCancel) {
                Text(L10n.string("ui.2cd0f3be8738a86c"))
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
