import AppKit
import DsmCore
import DsmLocalization
import SwiftUI
import UniformTypeIdentifiers

struct PackageCenterView: View {
    @Bindable var model: NasSettingsModel
    enum Section: String, CaseIterable, Identifiable {
        case installed, all, updates, beta, community
        var id: String { rawValue }
        var title: String {
            switch self {
            case .installed: L10n.string("package.center.section.installed")
            case .all: L10n.string("package.center.section.all")
            case .updates: L10n.string("package.center.section.updates")
            case .beta: L10n.string("package.center.section.beta")
            case .community: L10n.string("package.center.section.community")
            }
        }
        var emptyTitle: String {
            switch self {
            case .installed: L10n.string("package.center.empty.installed")
            case .all: L10n.string("package.center.empty.all")
            case .updates: L10n.string("package.center.empty.updates")
            case .beta: L10n.string("package.center.empty.beta")
            case .community: L10n.string("package.center.empty.community")
            }
        }
    }
    private enum Sheet: Identifiable {
        case details(String), installation, settings
        var id: String { switch self { case .details(let id): "details:" + id; case .installation: "installation"; case .settings: "settings" } }
    }
    private struct Row: Identifiable {
        let id: String
        let installed: NasPackage?
        let available: NasPackageCatalogEntry?
        var name: String { available?.name ?? installed?.name ?? id }
        var description: String { packagePlainText(available?.description ?? installed?.packageDescription ?? "") }
    }
    @State private var section: Section = .installed
    @State private var search = ""
    @State private var category = ""
    @State private var sheet: Sheet?
    @State private var selectingFile = false
    @State private var actionError: String?
    @State private var pendingControl: (NasPackage, NasPackageAction)?
    @State private var pendingDetailsControl: (NasPackage, NasPackageAction)?
    @State private var pendingSheetError: String?
    @AppStorage("packageDisplayMode") private var displayMode = "grid"

    private var rows: [Row] {
        let catalog = model.packageCatalog?.entries ?? []
        let installed = Dictionary(uniqueKeysWithValues: model.packages.map { ($0.id, $0) })
        let result: [Row]
        if section == .installed {
            result = model.packages.map { package in
                let available = catalog.first { $0.packageID == package.id && $0.isUpdateAvailable }
                    ?? catalog.first { $0.packageID == package.id && !$0.isBeta }
                return Row(id: package.id, installed: package, available: available)
            }
        } else {
            result = catalog.filter { entry in
                switch section {
                case .installed: false
                case .all: !entry.isBeta && entry.isOfficial
                case .updates: entry.isUpdateAvailable
                case .beta: entry.isBeta
                case .community: !entry.isOfficial
                }
            }.map { Row(id: $0.id, installed: installed[$0.packageID], available: $0) }
        }
        return result.filter { row in
            (category.isEmpty || section == .installed || row.available?.categories.contains(category) == true)
                && (search.isEmpty || row.name.localizedCaseInsensitiveContains(search)
                    || row.description.localizedCaseInsensitiveContains(search)
                    || row.id.localizedCaseInsensitiveContains(search))
        }
    }
    private var updates: [NasPackageCatalogEntry] { model.packageCatalog?.entries.filter(\.isUpdateAvailable) ?? [] }
    private var busy: Bool { model.packageInstallationIsBusy || !model.packageOperationIDs.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MacPageTabs(options: Section.allCases, selection: $section, title: { $0.title })
                Spacer(minLength: 8)
                Button(L10n.string("package.center.settings")) { sheet = .settings }.disabled(busy)
                Button(L10n.string("package.center.manual")) { selectingFile = true }.disabled(busy)
                Button { Task { await refresh() } } label: {
                    Label(L10n.string("package.center.refresh"), systemImage: "arrow.clockwise")
                }.disabled(model.isLoading(.packages) || model.isLoadingPackageCatalog)
            }
            .buttonStyle(.bordered).controlSize(.regular)
            .padding(12)
            HStack(spacing: 10) {
                TextField(L10n.string("package.center.search"), text: $search).textFieldStyle(.roundedBorder)
                if section != .installed, let categories = model.packageCatalog?.categories, !categories.isEmpty {
                    Picker(L10n.string("package.center.category"), selection: $category) {
                        Text(L10n.string("package.center.all-categories")).tag("")
                        ForEach(categories) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 180)
                }
                if section == .updates, !updates.isEmpty {
                    Button(L10n.string("package.center.update-all")) { prepare(updates.map(\.id)) }.disabled(busy)
                }
                Picker(L10n.string("package.center.display"), selection: $displayMode) {
                    Image(systemName: "square.grid.2x2").help(L10n.string("ui.fb5640f8e12e3337")).tag("grid")
                    Image(systemName: "list.bullet").help(L10n.string("ui.aedd6814ff8c516c")).tag("list")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 75)
            }.padding(.horizontal, 12).padding(.bottom, 10)
            if model.isPreparingPackageInstallation {
                HStack { ProgressView().controlSize(.small); Text(L10n.string("package.center.preparing")); Spacer() }.padding(12)
            }
            if let progress = model.packageInstallProgress {
                Button { sheet = .installation } label: {
                    HStack(spacing: 8) {
                        Image(systemName: progress.phase == .completed ? "checkmark.circle" : "shippingbox")
                        Text(progress.packageName).lineLimit(1)
                        Text(progress.phase.packageCenterTitle)
                        Spacer()
                        if progress.phase.isActive { ProgressView(value: progress.fraction).frame(width: 120) }
                        Image(systemName: "chevron.right")
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(12).background(.quaternary)
            }
            Divider()
            content
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .navigationTitle(L10n.string("package.center.title"))
        .task { await model.loadPackageCatalog() }
        .onChange(of: section) { _, _ in category = "" }
        .fileImporter(isPresented: $selectingFile, allowedContentTypes: [UTType(filenameExtension: "spk") ?? .data]) { result in
            switch result {
            case .success(let url):
                sheet = .installation
                Task {
                    do { try await model.uploadPackageForInstallation(url) }
                    catch { pendingSheetError = safeMessage(error); sheet = nil }
                }
            case .failure(let error): actionError = safeMessage(error)
            }
        }
        .sheet(item: $sheet, onDismiss: {
            if let pending = pendingDetailsControl { pendingControl = pending; pendingDetailsControl = nil }
            if let message = pendingSheetError { actionError = message; pendingSheetError = nil }
        }) { item in
            switch item {
            case .details(let id):
                if let row = rows.first(where: { $0.id == id }) {
                    PackageDetailsView(installed: row.installed, available: row.available, isBusy: busy,
                        onInstall: { if let entry = row.available { prepare([entry.id]) } },
                        onControl: { if let package = row.installed { pendingDetailsControl = (package, $0); sheet = nil } },
                        onClose: { sheet = nil })
                }
            case .installation:
                PackageInstallationSheet(model: model, onClose: { sheet = nil })
            case .settings:
                PackageCenterSettingsView(loadSettings: { try await model.loadPackageCenterSettings() },
                    saveSettings: { try await model.savePackageCenterSettings($0, replacing: $1) },
                    loadSources: { try await model.loadPackageSources() },
                    saveSource: { try await model.savePackageSource($0, replacing: $1) },
                    deleteSource: { try await model.deletePackageSource($0) }, onClose: { sheet = nil })
            }
        }
        .alert(L10n.string("package.center.action-confirm"), isPresented: Binding(get: { pendingControl != nil }, set: { if !$0 { pendingControl = nil } })) {
            if let (package, action) = pendingControl {
                Button(controlTitle(action), role: action == .uninstall || action == .stop ? .destructive : nil) {
                    pendingControl = nil
                    Task {
                        do { _ = try await model.controlPackage(id: package.id, action: action); await model.loadPackageCatalog(force: true) }
                        catch { actionError = safeMessage(error) }
                    }
                }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { pendingControl = nil }
        } message: {
            if let (package, action) = pendingControl {
                Text(L10n.string(action == .uninstall ? "ui.f1ff4c701fff6787" : action == .stop ? "package.stop.confirm-message" : "package.start.confirm-message", package.name))
            }
        }
        .alert(L10n.string("package.center.error-title"), isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button(L10n.string("ui.fac2a67ad87807c4"), role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    @ViewBuilder private var content: some View {
        let loading = section == .installed ? model.isLoading(.packages) : model.isLoadingPackageCatalog
        let error = section == .installed ? model.errorMessage(for: .packages)
            : section == .community && model.packageCatalog?.communityAvailable == false
                ? L10n.string("package.center.community-unavailable") : model.packageCatalogError
        if loading && rows.isEmpty {
            ProgressView(L10n.string("package.center.loading")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error, rows.isEmpty {
            ContentUnavailableView {
                Label(L10n.string("package.center.load-failed"), systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button(L10n.string("package.center.refresh")) { Task { await refresh() } }
            }
        } else if rows.isEmpty {
            ContentUnavailableView(search.isEmpty ? section.emptyTitle : L10n.string("package.center.no-matches"),
                systemImage: "shippingbox", description: Text(L10n.string(search.isEmpty ? "package.center.empty-help" : "package.center.search-help")))
        } else {
            VStack(spacing: 0) {
                if let error { Text(error).font(.callout).foregroundStyle(.secondary).padding(10) }
                ScrollView {
                    if displayMode == "list" {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in packageRow(row, grid: false).padding(12); Divider() }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 265, maximum: 430), spacing: 12)], spacing: 12) {
                            ForEach(rows) { row in packageRow(row, grid: true).padding(14).background(MacGlassSurface(role: .selectionBar)).clipShape(RoundedRectangle(cornerRadius: 12)) }
                        }.padding(14)
                    }
                }
            }
        }
    }

    private func packageRow(_ row: Row, grid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let installed = row.installed { PackageIconView(package: installed) }
                else { Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.tint).frame(width: 40, height: 40).accessibilityHidden(true) }
                Button { sheet = .details(row.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name).font(.headline).lineLimit(2)
                        Text(row.installed?.version ?? row.available?.version ?? "").font(.caption).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint(L10n.string("package.center.details"))
                .accessibilityIdentifier("packageCenter.details." + row.id)
                Spacer(minLength: 0)
                if !grid { rowActions(row) }
            }
            Text(row.description).font(.caption).foregroundStyle(.secondary).lineLimit(grid ? 3 : 1)
                .frame(maxWidth: .infinity, minHeight: grid ? 42 : nil, alignment: .topLeading)
            if grid { HStack { status(row); Spacer(); rowActions(row) } }
            else { status(row) }
        }
        .contextMenu {
            Button(L10n.string("package.center.details")) { sheet = .details(row.id) }
            if let installed = row.installed {
                if installed.canStart { Button(controlTitle(.start)) { pendingControl = (installed, .start) }.disabled(busy) }
                if installed.canStop { Button(controlTitle(.stop)) { pendingControl = (installed, .stop) }.disabled(busy) }
                if installed.canUninstall { Button(controlTitle(.uninstall), role: .destructive) { pendingControl = (installed, .uninstall) }.disabled(busy) }
            }
        }
    }
    @ViewBuilder private func status(_ row: Row) -> some View {
        if let installed = row.installed {
            Text(installed.statusDescription ?? L10n.string("package.center.section.installed")).font(.caption).foregroundStyle(.secondary)
        } else if row.available?.isBeta == true {
            Text(L10n.string("package.center.section.beta")).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func rowActions(_ row: Row) -> some View {
        HStack(spacing: 6) {
            if let available = row.available, row.installed == nil || available.isUpdateAvailable {
                Button(L10n.string(row.installed == nil ? "package.center.install" : "package.center.update")) { prepare([available.id]) }
            }
            if let installed = row.installed {
                if installed.canStop { Button(controlTitle(.stop)) { pendingControl = (installed, .stop) } }
                else if installed.canStart { Button(controlTitle(.start)) { pendingControl = (installed, .start) } }
            }
        }.buttonStyle(.bordered).controlSize(.small).disabled(busy)
    }
    private func prepare(_ ids: [String]) {
        sheet = .installation
        Task {
            do { try await model.preparePackageInstallation(ids) }
            catch is CancellationError { }
            catch { pendingSheetError = safeMessage(error); sheet = nil }
        }
    }
    private func refresh() async { await model.activate(.packages, force: true); await model.loadPackageCatalog(force: true) }
    private func safeMessage(_ error: Error) -> String { (error as? AppError)?.safeUserMessage ?? L10n.string("package.center.failed") }
    private func controlTitle(_ action: NasPackageAction) -> String {
        L10n.string(action == .start ? "ui.56410fc65314dfb5" : action == .stop ? "package.center.stop" : "ui.330dc1fd06685f18")
    }
}

struct PackageDetailsView: View {
    let installed: NasPackage?
    let available: NasPackageCatalogEntry?
    let isBusy: Bool
    let onInstall: () -> Void
    let onControl: (NasPackageAction) -> Void
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if let installed { PackageIconView(package: installed, size: 56) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(available?.name ?? installed?.name ?? "").font(.title2.bold())
                    if let available { Text(available.publisher).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let installed { LabeledContent(L10n.string("package.center.installed-version"), value: installed.version ?? "") }
                    if let available {
                        LabeledContent(L10n.string("package.center.available-version"), value: available.version)
                        LabeledContent(L10n.string("package.center.source"), value: L10n.string(available.isOfficial ? "package.center.official" : "package.center.section.community"))
                        if let size = available.sizeBytes { LabeledContent(L10n.string("package.center.size"), value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                        if available.isBeta { Text(L10n.string("package.center.beta-warning")).foregroundStyle(.orange) }
                    }
                    Text(packagePlainText(available?.description ?? installed?.packageDescription ?? "")).textSelection(.enabled)
                    if let notes = available?.releaseNotes, !notes.isEmpty {
                        Text(L10n.string("package.center.release-notes")).font(.headline)
                        Text(packagePlainText(notes)).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let installed {
                    if installed.canUninstall { Button(L10n.string("ui.330dc1fd06685f18"), role: .destructive) { onControl(.uninstall) }.disabled(isBusy) }
                    if installed.canStop { Button(L10n.string("package.center.stop")) { onControl(.stop) }.disabled(isBusy) }
                    if installed.canStart { Button(L10n.string("ui.56410fc65314dfb5")) { onControl(.start) }.disabled(isBusy) }
                }
                Spacer()
                Button(L10n.string("package.center.close"), action: onClose).keyboardShortcut(.cancelAction)
                if available != nil, installed == nil || available?.isUpdateAvailable == true {
                    Button(L10n.string(installed == nil ? "package.center.install" : "package.center.update"), action: onInstall)
                        .buttonStyle(.borderedProminent).disabled(isBusy)
                }
            }
        }.padding(24).frame(width: 620, height: 550)
    }
}

/// 套件说明是服务端内容，只提取文字；不加载其中的脚本、链接图片或网页资源。
func packagePlainText(_ value: String) -> String {
    value.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|li|div|h[1-6])>", with: "\n", options: .regularExpression)
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
}
