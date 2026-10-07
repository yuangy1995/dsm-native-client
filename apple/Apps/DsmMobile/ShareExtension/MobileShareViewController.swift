import DsmCore
import DsmLocalization
import SwiftUI
import UIKit

final class MobileShareViewController: UIViewController {
    private var model: MobileShareComposerModel?
    private var completed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let language = AppLanguageStore.shared
        language.selection = MobileExtensionStorage.preferences?.string(forKey: AppLanguageStore.preferenceKey)
            .flatMap(AppLanguageSelection.init(rawValue:)) ?? .system
        do {
            var root = try MobileExtensionStorage.rootURL()
            let sessions = try MobileExtensionStorage.sessionStore()
            var makeRepository: (@Sendable (MobileExtensionAccount) async throws -> any DsmCore.FileRepository)?
            #if DEBUG
            if let fixture = MobileShareDebugEnvironment.active() {
                root = try fixture.rootURL()
                let accounts = MobileExtensionAccountStore(rootURL: root)
                makeRepository = { account in try await fixture.repository(account: account, accounts: accounts, sessions: sessions) }
            }
            #endif
            let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SharedInput-\(UUID().uuidString)", isDirectory: true)
            let model = MobileShareComposerModel(accounts: .init(rootURL: root), sessions: sessions,
                transfers: .init(rootURL: root.appendingPathComponent("ShareTransfers", isDirectory: true)),
                loadInput: { try await MobileShareIntake.receive(providers, directory: temporary) },
                cleanupInput: { try? FileManager.default.removeItem(at: temporary) }, makeRepository: makeRepository)
            self.model = model
            let content = MobileShareComposerView(model: model) { [weak self] in self?.finish() }
                .environment(language).environment(\.locale, language.locale)
            #if DEBUG
            install(UIHostingController(rootView: content.modifier(MobileShareDebugAppearance(enabled: MobileShareDebugEnvironment.active()?.usesLargestDarkText == true))))
            #else
            install(UIHostingController(rootView: content))
            #endif
        } catch {
            install(UIHostingController(rootView: NavigationStack {
                ContentUnavailableView(L10n.string("mobile.share.title"), systemImage: "square.and.arrow.up",
                    description: Text(L10n.string("mobile.extensions.unavailable")))
                    .toolbar { Button(L10n.string("mobile.share.close")) { [weak self] in self?.finish() } }
            }.environment(language).environment(\.locale, language.locale)))
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let model { Task { await model.close() } }
    }

    private func install<Content: View>(_ controller: UIHostingController<Content>) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        extensionContext?.completeRequest(returningItems: nil)
    }
}
