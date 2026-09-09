import AppKit
import DsmCore
import DsmLocalization
import SwiftUI
import UniformTypeIdentifiers

struct DesktopDriveDiagnosticExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: String
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("desktopDrive.diagnostics.title"))
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(MacGlassSurface(role: .toolbar).clipShape(RoundedRectangle(cornerRadius: 12)))

            Text(L10n.string("desktopDrive.diagnostics.description"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .macThemedScrollContent()
            .background(MacGlassSurface(role: .content))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .accessibilityLabel(
                L10n.string("desktopDrive.diagnostics.preview")
            )

            if let statusMessage {
                Label(
                    statusMessage,
                    systemImage: statusIsError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(statusIsError ? .red : .secondary)
            }

            HStack {
                Spacer()
                Button(L10n.string("desktopDrive.diagnostics.close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    export()
                } label: {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(L10n.string("desktopDrive.diagnostics.export"))
                    }
                }
                .disabled(isExporting)
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(MacToolbarButtonStyle())
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 460)
        .background(MacGlassSurface(role: .sidebar))
    }

    private func export() {
        isExporting = true
        defer { isExporting = false }

        let panel = NSSavePanel()
        panel.title = L10n.string("desktopDrive.diagnostics.saveTitle")
        panel.nameFieldStringValue = "LanStash-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(preview.utf8).write(to: url, options: .atomic)
            statusMessage = L10n.string(
                "desktopDrive.diagnostics.exported"
            )
            statusIsError = false
        } catch {
            statusMessage = L10n.string(
                "desktopDrive.diagnostics.exportFailed"
            )
            statusIsError = true
        }
    }
}

private struct CommunityReportDraftResult: Identifiable {
    let id: String
    var status: CommunityCompatibilitySubmission.Status = .skipped
    var stage: CommunityCompatibilitySubmission.FailureStage = .unknown
    var category: CommunityCompatibilitySubmission.ErrorCategory = .unknown
    var apiName = "unknown"
    var apiVersion = "unknown"
    var httpStatus = ""
    var retryPerformed = false
}

struct CommunityCompatibilitySubmissionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var nasModel = ""
    @State private var architecture: CommunityCompatibilitySubmission.Architecture = .unknown
    @State private var dsmVersion = ""
    @State private var dsmBuild = ""
    @State private var dsmUpdate = "unknown"
    @State private var packageID = ""
    @State private var packageVersion = ""
    @State private var connectionType: CommunityCompatibilitySubmission.ConnectionType = .unknown
    @State private var accountRole: CommunityCompatibilitySubmission.AccountRole = .unknown
    @State private var certificateType: CommunityCompatibilitySubmission.CertificateType = .unknown
    @State private var results = CommunityCompatibilitySubmissionValidator
        .version2CapabilityIDs.map { CommunityReportDraftResult(id: $0) }
    @State private var privacyAttestation = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isPreparing = true
    @State private var isExporting = false
    @State private var showsPreview = false

    private static let statuses: [CommunityCompatibilitySubmission.Status] = [
        .passed, .failed, .partial, .skipped, .notSupported,
    ]
    private static let architectures: [CommunityCompatibilitySubmission.Architecture] = [
        .x86_64, .aarch64, .armv7, .unknown,
    ]
    private static let connections: [CommunityCompatibilitySubmission.ConnectionType] = [
        .lan, .quickConnectDirect, .quickConnectRelay, .reverseProxy, .unknown,
    ]
    private static let roles: [CommunityCompatibilitySubmission.AccountRole] = [
        .standard, .administrator, .unknown,
    ]
    private static let certificates: [CommunityCompatibilitySubmission.CertificateType] = [
        .publicCA, .privateCA, .selfSigned, .unknown,
    ]
    private static let stages: [CommunityCompatibilitySubmission.FailureStage] = [
        .setup, .discovery, .authentication, .request, .submission, .readback,
        .finalState, .cleanup, .unknown,
    ]
    private static let categories: [CommunityCompatibilitySubmission.ErrorCategory] = [
        .permissionDenied, .operationFailed, .connectionFailed,
        .unexpectedResult, .appCrashed, .unknown,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("communityReport.title"))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(MacGlassSurface(role: .toolbar).clipShape(RoundedRectangle(cornerRadius: 12)))
            Text(L10n.string("communityReport.description"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isPreparing {
                Spacer()
                ProgressView(L10n.string("communityReport.preparing"))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if results.isEmpty {
                ContentUnavailableView(
                    L10n.string("communityReport.empty.title"),
                    systemImage: "checklist",
                    description: Text(L10n.string("communityReport.empty.message"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        environmentSection
                        resultSection(
                            title: L10n.string("communityReport.group.connection"),
                            range: 0..<4
                        )
                        resultSection(
                            title: L10n.string("communityReport.group.files"),
                            range: 4..<14
                        )
                        resultSection(
                            title: L10n.string("communityReport.group.desktopDrive"),
                            range: 14..<19
                        )
                        privacySection
                        previewSection
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()
            if let statusMessage {
                Label(
                    statusMessage,
                    systemImage: statusIsError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(statusIsError ? .red : .secondary)
            }
            ViewThatFits {
                HStack {
                    Spacer()
                    actionButtons
                }
                VStack(alignment: .trailing) { actionButtons }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(MacToolbarButtonStyle())
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 560)
        .background(MacGlassSurface(role: .sidebar))
        .task {
            await Task.yield()
            isPreparing = false
        }
    }

    private var environmentSection: some View {
        GroupBox(L10n.string("communityReport.environment")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    labeledField("communityReport.nasModel", text: $nasModel)
                    Picker(L10n.string("communityReport.architecture"), selection: $architecture) {
                        ForEach(Self.architectures, id: \.rawValue) {
                            Text(option("architecture", $0.rawValue)).tag($0)
                        }
                    }
                }
                HStack {
                    labeledField("communityReport.dsmVersion", text: $dsmVersion)
                    labeledField("communityReport.dsmBuild", text: $dsmBuild)
                    labeledField("communityReport.dsmUpdate", text: $dsmUpdate)
                }
                HStack {
                    labeledField("communityReport.packageID", text: $packageID)
                    labeledField("communityReport.packageVersion", text: $packageVersion)
                }
                Text(L10n.string("communityReport.packageHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.string("communityReport.connection"), selection: $connectionType) {
                        ForEach(Self.connections, id: \.rawValue) {
                            Text(option("connection", $0.rawValue)).tag($0)
                        }
                    }
                    Picker(L10n.string("communityReport.accountRole"), selection: $accountRole) {
                        ForEach(Self.roles, id: \.rawValue) {
                            Text(option("accountRole", $0.rawValue)).tag($0)
                        }
                    }
                    Picker(L10n.string("communityReport.certificate"), selection: $certificateType) {
                        ForEach(Self.certificates, id: \.rawValue) {
                            Text(option("certificate", $0.rawValue)).tag($0)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func resultSection(title: String, range: Range<Int>) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(range), id: \.self) { index in
                    resultRow(index: index)
                    if index != range.last { Divider().opacity(0.4) }
                }
            }
            .padding(8)
        }
    }

    private func resultRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(capabilityTitle(results[index].id))
                Spacer()
                Picker(
                    L10n.string("communityReport.result"),
                    selection: $results[index].status
                ) {
                    ForEach(Self.statuses, id: \.rawValue) {
                        Text(option("status", $0.rawValue)).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .accessibilityLabel(
                    capabilityTitle(results[index].id)
                )
            }
            if results[index].status == .failed || results[index].status == .partial {
                DisclosureGroup(L10n.string("communityReport.failureDetails")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker(L10n.string("communityReport.failureStage"), selection: $results[index].stage) {
                                ForEach(Self.stages, id: \.rawValue) {
                                    Text(option("failureStage", $0.rawValue)).tag($0)
                                }
                            }
                            Picker(L10n.string("communityReport.failureCategory"), selection: $results[index].category) {
                                ForEach(Self.categories, id: \.rawValue) {
                                    Text(option("failureCategory", $0.rawValue)).tag($0)
                                }
                            }
                        }
                        HStack {
                            labeledField("communityReport.apiName", text: $results[index].apiName)
                            labeledField("communityReport.apiVersion", text: $results[index].apiVersion)
                            labeledField("communityReport.httpStatus", text: $results[index].httpStatus)
                        }
                        Toggle(
                            L10n.string("communityReport.retryPerformed"),
                            isOn: $results[index].retryPerformed
                        )
                        Text(L10n.string("communityReport.failurePrivacy"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private var privacySection: some View {
        GroupBox(L10n.string("communityReport.privacy.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("communityReport.privacy.message"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Toggle(
                    L10n.string("communityReport.privacy.confirm"),
                    isOn: $privacyAttestation
                )
                .accessibilityHint(L10n.string("communityReport.privacy.hint"))
            }
            .padding(8)
        }
    }

    private var previewSection: some View {
        DisclosureGroup(
            L10n.string("communityReport.preview"),
            isExpanded: $showsPreview
        ) {
            ScrollView(.horizontal) {
                Text(previewText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .macThemedScrollContent()
            .background(MacGlassSurface(role: .content))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(L10n.string("communityReport.previewAccessibility"))
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(L10n.string("communityReport.close")) { dismiss() }
            .keyboardShortcut(.cancelAction)
        Button {
            export()
        } label: {
            if isExporting {
                ProgressView().controlSize(.small)
            } else {
                Text(L10n.string("communityReport.export"))
            }
        }
        .disabled(isPreparing || isExporting || !privacyAttestation)
        .buttonStyle(MacToolbarButtonStyle(prominent: true))
        .keyboardShortcut(.defaultAction)
    }

    private func labeledField(_ key: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(key)).font(.caption).foregroundStyle(.secondary)
            TextField(L10n.string(key), text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func option(_ group: String, _ value: String) -> String {
        switch (group, value) {
        case ("architecture", "x86_64"): L10n.string("communityReport.option.architecture.x86_64")
        case ("architecture", "aarch64"): L10n.string("communityReport.option.architecture.aarch64")
        case ("architecture", "armv7"): L10n.string("communityReport.option.architecture.armv7")
        case ("architecture", "unknown"): L10n.string("communityReport.option.architecture.unknown")
        case ("connection", "lan"): L10n.string("communityReport.option.connection.lan")
        case ("connection", "quickconnect-direct"): L10n.string("communityReport.option.connection.quickconnect-direct")
        case ("connection", "quickconnect-relay"): L10n.string("communityReport.option.connection.quickconnect-relay")
        case ("connection", "reverse-proxy"): L10n.string("communityReport.option.connection.reverse-proxy")
        case ("connection", "unknown"): L10n.string("communityReport.option.connection.unknown")
        case ("accountRole", "standard"): L10n.string("communityReport.option.accountRole.standard")
        case ("accountRole", "administrator"): L10n.string("communityReport.option.accountRole.administrator")
        case ("accountRole", "unknown"): L10n.string("communityReport.option.accountRole.unknown")
        case ("certificate", "public-ca"): L10n.string("communityReport.option.certificate.public-ca")
        case ("certificate", "private-ca"): L10n.string("communityReport.option.certificate.private-ca")
        case ("certificate", "self-signed"): L10n.string("communityReport.option.certificate.self-signed")
        case ("certificate", "unknown"): L10n.string("communityReport.option.certificate.unknown")
        case ("status", "passed"): L10n.string("communityReport.option.status.passed")
        case ("status", "failed"): L10n.string("communityReport.option.status.failed")
        case ("status", "partial"): L10n.string("communityReport.option.status.partial")
        case ("status", "skipped"): L10n.string("communityReport.option.status.skipped")
        case ("status", "not-supported"): L10n.string("communityReport.option.status.not-supported")
        case ("failureStage", "setup"): L10n.string("communityReport.option.failureStage.setup")
        case ("failureStage", "discovery"): L10n.string("communityReport.option.failureStage.discovery")
        case ("failureStage", "authentication"): L10n.string("communityReport.option.failureStage.authentication")
        case ("failureStage", "request"): L10n.string("communityReport.option.failureStage.request")
        case ("failureStage", "submission"): L10n.string("communityReport.option.failureStage.submission")
        case ("failureStage", "readback"): L10n.string("communityReport.option.failureStage.readback")
        case ("failureStage", "final-state"): L10n.string("communityReport.option.failureStage.final-state")
        case ("failureStage", "cleanup"): L10n.string("communityReport.option.failureStage.cleanup")
        case ("failureStage", "unknown"): L10n.string("communityReport.option.failureStage.unknown")
        case ("failureCategory", "permission-denied"): L10n.string("communityReport.option.failureCategory.permission-denied")
        case ("failureCategory", "operation-failed"): L10n.string("communityReport.option.failureCategory.operation-failed")
        case ("failureCategory", "connection-failed"): L10n.string("communityReport.option.failureCategory.connection-failed")
        case ("failureCategory", "unexpected-result"): L10n.string("communityReport.option.failureCategory.unexpected-result")
        case ("failureCategory", "app-crashed"): L10n.string("communityReport.option.failureCategory.app-crashed")
        case ("failureCategory", "unknown"): L10n.string("communityReport.option.failureCategory.unknown")
        default: value
        }
    }

    private func capabilityTitle(_ identifier: String) -> String {
        switch identifier {
        case "connection.resolve": L10n.string("communityReport.capability.connection.resolve")
        case "authentication.password": L10n.string("communityReport.capability.authentication.password")
        case "authentication.otp": L10n.string("communityReport.capability.authentication.otp")
        case "authentication.restore-session": L10n.string("communityReport.capability.authentication.restore-session")
        case "files.list-shares": L10n.string("communityReport.capability.files.list-shares")
        case "files.browse": L10n.string("communityReport.capability.files.browse")
        case "files.search": L10n.string("communityReport.capability.files.search")
        case "files.download": L10n.string("communityReport.capability.files.download")
        case "files.upload": L10n.string("communityReport.capability.files.upload")
        case "files.create-folder": L10n.string("communityReport.capability.files.create-folder")
        case "files.rename": L10n.string("communityReport.capability.files.rename")
        case "files.copy-move": L10n.string("communityReport.capability.files.copy-move")
        case "files.recycle": L10n.string("communityReport.capability.files.recycle")
        case "files.restore": L10n.string("communityReport.capability.files.restore")
        case "desktop-drive.mount": L10n.string("communityReport.capability.desktop-drive.mount")
        case "desktop-drive.browse": L10n.string("communityReport.capability.desktop-drive.browse")
        case "desktop-drive.download-resume": L10n.string("communityReport.capability.desktop-drive.download-resume")
        case "desktop-drive.keep-offline": L10n.string("communityReport.capability.desktop-drive.keep-offline")
        case "desktop-drive.upgrade-restore": L10n.string("communityReport.capability.desktop-drive.upgrade-restore")
        default: identifier
        }
    }

    private var previewText: String {
        guard let data = try? makeData(),
              let text = String(data: data, encoding: .utf8) else {
            return L10n.string("communityReport.previewUnavailable")
        }
        return text
    }

    private func makeData() throws -> Data {
        let packageValues: [CommunityCompatibilitySubmission.Package]
        if packageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           packageVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            packageValues = []
        } else {
            packageValues = [.init(id: packageID, version: packageVersion)]
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let platformVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let submission = CommunityCompatibilitySubmission(
            generatedAt: Date(),
            app: .init(
                version: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown",
                commit: Bundle.main.object(forInfoDictionaryKey: "GitCommit")
                    as? String ?? "unknown",
                platform: .macOS,
                platformVersion: platformVersion
            ),
            nas: .init(model: nasModel, architecture: architecture),
            dsm: .init(version: dsmVersion, build: dsmBuild, update: dsmUpdate),
            packages: packageValues,
            connectionType: connectionType,
            accountRole: accountRole,
            certificateType: certificateType,
            testSuiteVersion: .version2,
            results: results.map { row in
                let failure: CommunityCompatibilitySubmission.Failure?
                if row.status == .failed || row.status == .partial {
                    let apiVersion: CommunityCompatibilitySubmission.APIVersion =
                        Int(row.apiVersion).map { .version($0) } ?? .unknown
                    failure = .init(
                        stage: row.stage,
                        errorCategory: row.category,
                        apiName: row.apiName,
                        apiVersion: apiVersion,
                        httpStatus: Int(row.httpStatus),
                        retryPerformed: row.retryPerformed
                    )
                } else {
                    failure = nil
                }
                return .init(
                    capabilityId: row.id,
                    status: row.status,
                    failure: failure
                )
            },
            privacyAttestation: privacyAttestation
        )
        return try CommunityCompatibilitySubmissionExporter.makeData(submission)
    }

    private func export() {
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try makeData()
            let panel = NSSavePanel()
            panel.title = L10n.string("communityReport.saveTitle")
            panel.nameFieldStringValue = "LanStash-Compatibility-Submission.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusMessage = L10n.string("communityReport.exported")
            statusIsError = false
        } catch {
            statusMessage = L10n.string("communityReport.exportFailed")
            statusIsError = true
        }
    }
}
