import AppKit
import DsmLocalization
import Observation
import SwiftUI

enum MacAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case fog
    case ink

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .fog: .light
        case .ink: .dark
        }
    }

    var title: String {
        switch self {
        case .system: L10n.string("appearance.system")
        case .fog: L10n.string("appearance.fog")
        case .ink: L10n.string("appearance.ink")
        }
    }
}

/// 外观偏好仅保存在本机，不与 NAS 配置或账号绑定。
@MainActor
@Observable
final class MacAppearanceStore {
    static let shared = MacAppearanceStore(defaults: .standard)
    static let defaultFogTransparency = 0.72
    static let defaultInkTransparency = 0.60

    private let defaults: UserDefaults?
    private static let modeKey = "LanStash_AppearanceMode"
    private static let fogKey = "LanStash_FogTransparency"
    private static let inkKey = "LanStash_InkTransparency"

    var mode: MacAppearanceMode = .system {
        didSet { defaults?.set(mode.rawValue, forKey: Self.modeKey) }
    }
    private(set) var fogTransparency = defaultFogTransparency
    private(set) var inkTransparency = defaultInkTransparency

    /// 生产入口使用标准偏好；不传入存储时可用于隔离的内存样板和测试。
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        // 初始化不触发属性观察器，避免首次读取就写入默认值。
        _mode = defaults?.string(forKey: Self.modeKey).flatMap(MacAppearanceMode.init(rawValue:)) ?? .system
        fogTransparency = min(max(defaults?.object(forKey: Self.fogKey) as? Double ?? Self.defaultFogTransparency, 0), 1)
        inkTransparency = min(max(defaults?.object(forKey: Self.inkKey) as? Double ?? Self.defaultInkTransparency, 0), 1)
    }

    func transparency(for scheme: ColorScheme) -> Double {
        scheme == .dark ? inkTransparency : fogTransparency
    }

    func setTransparency(_ value: Double, for scheme: ColorScheme) {
        let value = min(max(value, 0), 1)
        if scheme == .dark {
            inkTransparency = value
            defaults?.set(value, forKey: Self.inkKey)
        } else {
            fogTransparency = value
            defaults?.set(value, forKey: Self.fogKey)
        }
    }

    func reset() {
        mode = .system
        fogTransparency = Self.defaultFogTransparency
        inkTransparency = Self.defaultInkTransparency
        for key in [Self.modeKey, Self.fogKey, Self.inkKey] {
            defaults?.removeObject(forKey: key)
        }
    }

    /// 在原生背景模糊上调节遮罩浓度，不降低文字和控件的不透明度。
    func glassOverlayOpacity(for scheme: ColorScheme, reducesTransparency: Bool) -> Double {
        guard !reducesTransparency else { return 1 }
        return 0.96 - transparency(for: scheme) * 0.80
    }
}

/// 用途颜色统一解析，避免各页面分别反转浅色值或硬编码背景。
struct MacAppearancePalette {
    let scheme: ColorScheme
    let increasedContrast: Bool

    var content: Color {
        scheme == .dark
            ? Color(red: 0.105, green: 0.125, blue: 0.15)
            : Color(red: 0.975, green: 0.98, blue: 0.99)
    }

    var glassTint: Color {
        scheme == .dark
            ? Color(red: 0.12, green: 0.16, blue: 0.205)
            : Color(red: 0.89, green: 0.935, blue: 0.99)
    }

    var edge: Color {
        if increasedContrast { return Color(nsColor: .separatorColor) }
        return scheme == .dark ? .white.opacity(0.12) : .white.opacity(0.78)
    }

    var separator: Color {
        Color(nsColor: .separatorColor).opacity(increasedContrast ? 1 : 0.55)
    }

    var searchField: Color { scheme == .dark ? .black.opacity(0.26) : .white.opacity(0.42) }
    /// 卡片只在当前主题上增加轻量层次，不再铺系统控件的白色底。
    var card: Color {
        Color(red: 0.36, green: 0.48, blue: 0.62)
            .opacity(increasedContrast ? 0.14 : (scheme == .dark ? 0.10 : 0.055))
    }
    var previewCanvas: Color {
        scheme == .dark ? Color(red: 0.06, green: 0.075, blue: 0.095) : Color(red: 0.92, green: 0.94, blue: 0.97)
    }

    var nativeSelection: NSColor {
        NSColor(red: 0.36, green: 0.48, blue: 0.62, alpha: increasedContrast ? 0.30 : (scheme == .dark ? 0.24 : 0.16))
    }
    var selection: Color { Color(nsColor: nativeSelection) }
    var selectionBorder: Color {
        Color(red: 0.36, green: 0.48, blue: 0.62).opacity(increasedContrast ? 0.9 : 0.5)
    }
    var hover: Color { Color.primary.opacity(scheme == .dark ? 0.055 : 0.035) }
    var folderIcon: Color {
        scheme == .dark
            ? Color(red: 0.36, green: 0.64, blue: 0.98)
            : Color(red: 0.36, green: 0.60, blue: 0.94)
    }
}

struct MacCardFill: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        MacAppearancePalette(scheme: environment.colorScheme,
                             increasedContrast: environment.colorSchemeContrast == .increased).card
    }
}

enum MacAppearanceMetrics {
    static let workspaceInset: CGFloat = 12
    static let surfaceRadius: CGFloat = 16
    static let controlRadius: CGFloat = 8
    static let inspectorMinimumWidth: CGFloat = 800
    static let inspectorWidth: CGFloat = 210
}

private struct MacAppearanceRoot: ViewModifier {
    @State private var appearance = MacAppearanceStore.shared

    func body(content: Content) -> some View {
        content
            .environment(appearance)
            .preferredColorScheme(appearance.mode.colorScheme)
            .tint(.blue)
            .accentColor(.blue)
            .scrollContentBackground(.hidden)
            .toolbarBackground(.hidden, for: .windowToolbar)
            .onChange(of: appearance.mode, initial: true) { _, mode in
                // 系统文件面板与 AppKit 确认框也跟随 App 外观，不修改系统的全局主题。
                let name: NSAppearance.Name? = switch mode {
                case .system: nil
                case .fog: .aqua
                case .ink: .darkAqua
                }
                if NSApp?.appearance?.name != name {
                    NSApp?.appearance = name.flatMap(NSAppearance.init(named:))
                }
            }
    }
}

/// 让标题栏延续窗口材质；不改系统按钮、窗口尺寸或业务生命周期。
struct MacWorkspaceWindowChrome: NSViewRepresentable {
    let fullSize: Bool
    var hidesSystemButtons = false
    final class HostView: NSView {
        var fullSize = false
        var hidesSystemButtons = false
        private var didHideSystemButtons = false
        private var titleObservation: NSKeyValueObservation?
        // 仅配置窗口的背景视图不接收鼠标事件。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }
        func configure() {
            guard let window else { return }
            if titleObservation == nil {
                titleObservation = window.observe(\.titleVisibility, options: [.new]) { [weak self] window, _ in
                    MainActor.assumeIsolated {
                        guard self?.fullSize == true, window.titleVisibility != .hidden else { return }
                        window.titleVisibility = .hidden
                    }
                }
            }
            if fullSize && !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            if !fullSize && window.styleMask.contains(.fullSizeContentView) { window.styleMask.remove(.fullSizeContentView) }
            window.titleVisibility = fullSize ? .hidden : .visible
            window.isMovableByWindowBackground = fullSize
            window.titlebarAppearsTransparent = fullSize
            window.titlebarSeparatorStyle = fullSize ? .none : .automatic
            if hidesSystemButtons || didHideSystemButtons {
                setSystemButtonsHidden(hidesSystemButtons, in: window)
                didHideSystemButtons = hidesSystemButtons
            }
            // 透明效果由 NSVisualEffectView 在窗口背后模糊，避免透出未模糊的桌面文字。
            window.alphaValue = 1
            window.backgroundColor = fullSize ? .clear : .windowBackgroundColor
            window.isOpaque = !fullSize
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window, window !== newWindow {
                titleObservation?.invalidate()
                titleObservation = nil
                // 登录与工作区交接时，新外壳可能已经接管同一窗口，旧视图不能恢复白色标题栏。
                let hasNewChrome = window.contentView.map { containsOtherChrome(in: $0, window: window) } ?? false
                if !hasNewChrome {
                    if didHideSystemButtons { setSystemButtonsHidden(false, in: window) }
                    window.styleMask.remove(.fullSizeContentView)
                    window.titleVisibility = .visible
                    window.titlebarAppearsTransparent = false
                    window.titlebarSeparatorStyle = .automatic
                    window.isMovableByWindowBackground = false
                    window.backgroundColor = .windowBackgroundColor
                    window.isOpaque = true
                }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func setSystemButtonsHidden(_ hidden: Bool, in window: NSWindow) {
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = hidden
            }
        }

        private func containsOtherChrome(in view: NSView, window: NSWindow) -> Bool {
            if let chrome = view as? HostView, chrome !== self, chrome.window === window { return true }
            return view.subviews.contains { containsOtherChrome(in: $0, window: window) }
        }
    }
    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.fullSize = fullSize
        view.hidesSystemButtons = hidesSystemButtons
        return view
    }
    func updateNSView(_ view: HostView, context: Context) {
        view.fullSize = fullSize
        view.hidesSystemButtons = hidesSystemButtons
        view.configure()
    }
}

struct MacToolbarButtonStyle: ButtonStyle {
    var prominent = false
    var selected = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let palette = MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased)
        configuration.label
            .font(.system(size: 16, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Color.white : configuration.role == .destructive ? Color.red : selected ? Color.accentColor : Color.primary)
            .padding(.horizontal, prominent ? 15 : 10)
            .frame(minWidth: 34, minHeight: 36)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(prominent ? (configuration.role == .destructive ? Color.red : Color.accentColor) : selected ? palette.selection : Color.primary.opacity(configuration.isPressed ? 0.10 : 0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? palette.selectionBorder : Color.clear, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

extension View {
    /// 弹窗是独立表面，不能沿用工作区只叠一层透明色的背景假设。
    func macSheetSurface() -> some View {
        self
            .macThemedScrollContent()
            .background(MacGlassSurface(role: .content).environment(\.macUsesContentBackground, false))
            .environment(\.macUsesContentBackground, true)
            .presentationBackground(.clear)
    }

    func macSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().macSheetSurface()
        }
    }

    func macSheet<Item: Identifiable, SheetContent: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss) { item in
            content(item).macSheetSurface()
        }
    }

    /// 仅作用于当前滚动区域，清除传统滚动条轨道的实色底；保留滚动与可见性设置。
    func macThemedScrollContent(selection: AnyHashable? = nil) -> some View {
        scrollContentBackground(.hidden)
            .background(MacScrollBackground(selection: selection))
    }

    func macPageActions<Actions: View>(title: String = "", @ViewBuilder _ actions: @escaping () -> Actions) -> some View {
        VStack(spacing: 0) {
            MacPageHeader(title: title, actions: actions)
            self
        }
        .fillsAvailableContentArea(alignment: .topLeading)
    }

    func macInlineSearch(text: Binding<String>, prompt: String) -> some View {
        VStack(spacing: 0) {
            MacInlineSearchField(text: text, prompt: prompt)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(MacGlassSurface(role: .toolbar))
            self
        }
        .fillsAvailableContentArea(alignment: .topLeading)
    }

    func macAppearanceRoot() -> some View {
        modifier(MacAppearanceRoot())
    }
}

struct MacSelectionSurface: View {
    let isSelected: Bool
    var cornerRadius: CGFloat = 8
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(isSelected ? MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased).selection : .clear)
            .allowsHitTesting(false)
    }
}

struct MacScrollBackground: NSViewRepresentable {
    var selection: AnyHashable? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    final class HostView: NSView {
        var selectionColor = MacAppearancePalette(scheme: .light, increasedContrast: false).nativeSelection
        private let observedTables = NSHashTable<NSTableView>.weakObjects()
        private let rowColorObservations = NSMapTable<NSTableRowView, NSKeyValueObservation>.weakToStrongObjects()
        private var observers: [NSObjectProtocol] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI 挂载背景时，滚动视图可能仍未加入同级容器。
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }

        override func layout() {
            super.layout()
            configure()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window !== newWindow {
                observers.forEach(NotificationCenter.default.removeObserver)
                observers.removeAll()
                observedTables.removeAllObjects()
                rowColorObservations.removeAllObjects()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        func configure() {
            guard window != nil else { return }
            var ancestor = superview
            while let container = ancestor {
                if Self.configureScrollViews(in: container, configureTable: configureTable) { return }
                ancestor = container.superview
            }
        }

        @discardableResult
        static func configureScrollViews(in view: NSView, configureTable: ((NSTableView) -> Void)? = nil) -> Bool {
            if let scroll = view as? NSScrollView {
                scroll.drawsBackground = false
                scroll.contentView.drawsBackground = false
                if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
                if let table = scroll.documentView as? NSTableView { configureTable?(table) }
                return true
            }
            var found = false
            for child in view.subviews {
                if configureScrollViews(in: child, configureTable: configureTable) { found = true }
            }
            return found
        }

        private func configureTable(_ table: NSTableView) {
            table.selectionHighlightStyle = .none
            applySelection(to: table)
            guard !observedTables.contains(table) else { return }
            observedTables.add(table)
            observers.append(NotificationCenter.default.addObserver(
                forName: NSTableView.selectionDidChangeNotification, object: table, queue: .main
            ) { [weak self, weak table] _ in
                DispatchQueue.main.async {
                    if let table {
                        table.layoutSubtreeIfNeeded()
                        self?.applySelection(to: table)
                    }
                }
            })
            if let clip = table.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { [weak self, weak table] _ in
                    DispatchQueue.main.async {
                        if let table { self?.applySelection(to: table) }
                    }
                })
            }
        }

        private func applySelection(to table: NSTableView) {
            // 不改 List/Table 的选择模型、焦点和快捷键，只替换原生蓝/灰色高亮。
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            for index in visible.location..<NSMaxRange(visible) {
                guard let row = table.rowView(atRow: index, makeIfNecessary: true) else { continue }
                if table.selectedRowIndexes.contains(index) {
                    if rowColorObservations.object(forKey: row) == nil {
                        let observation = row.observe(\.backgroundColor, options: [.new]) { [weak self, weak table] row, _ in
                            MainActor.assumeIsolated {
                                guard let self, let table else { return }
                                let index = table.row(for: row)
                                guard index >= 0, table.isRowSelected(index),
                                      row.backgroundColor != self.selectionColor else { return }
                                row.backgroundColor = self.selectionColor
                            }
                        }
                        rowColorObservations.setObject(observation, forKey: row)
                    }
                    row.selectionHighlightStyle = .none
                    if row.backgroundColor != selectionColor { row.backgroundColor = selectionColor }
                } else {
                    rowColorObservations.removeObject(forKey: row)
                    if row.backgroundColor != .clear { row.backgroundColor = .clear }
                }
            }
        }
    }

    func makeNSView(context: Context) -> HostView { HostView() }
    func updateNSView(_ view: HostView, context: Context) {
        view.selectionColor = MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased).nativeSelection
        DispatchQueue.main.async { [weak view] in view?.configure() }
    }
}

private struct MacInlineSearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Label(L10n.string("workspace.search.clear"), systemImage: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(MacAppearancePalette(scheme: scheme, increasedContrast: false).searchField, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.15), lineWidth: 1))
        .background {
            Button("") { isFocused = true }.keyboardShortcut("f", modifiers: .command)
                .hidden().accessibilityHidden(true)
        }
    }
}

extension View {
    func macDataRowSurface() -> some View {
        self
            .padding(12)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// 页面共用工作区导航，避免模块再叠一条空的返回栏。
struct MacPageNavigation: Sendable {
    let canGoBack: Bool
    let canGoUp: Bool
    let goBack: @MainActor @Sendable () -> Void
    let goUp: @MainActor @Sendable () -> Void
}

private struct MacPageNavigationKey: EnvironmentKey {
    static let defaultValue: MacPageNavigation? = nil
}

private struct MacContentBackgroundKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 工作区内只叠加轻量主题色，共用外壳的一层背景模糊。
    var macUsesContentBackground: Bool {
        get { self[MacContentBackgroundKey.self] }
        set { self[MacContentBackgroundKey.self] = newValue }
    }

    var macPageNavigation: MacPageNavigation? {
        get { self[MacPageNavigationKey.self] }
        set { self[MacPageNavigationKey.self] = newValue }
    }
}

struct MacPageHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let actions: () -> Actions
    @Environment(\.macPageNavigation) private var navigation

    var body: some View {
        HStack(spacing: 12) {
            if let navigation {
                HStack(spacing: 6) {
                    Button(action: navigation.goBack) {
                        Label(L10n.string("ui.572cf45ba43634b3"), systemImage: "chevron.backward")
                    }
                    .disabled(!navigation.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    Button(action: navigation.goUp) {
                        Label(L10n.string("ui.8e7847be62b68c2b"), systemImage: "arrow.up")
                    }
                    .disabled(!navigation.canGoUp)
                }
                .labelStyle(.iconOnly)
                Divider().frame(height: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            actions()
        }
        .buttonStyle(MacToolbarButtonStyle())
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(MacGlassSurface(role: .toolbar))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct MacPageTabs<Item: Hashable>: View {
    let options: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    var icon: ((Item) -> String)? = nil

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(options, id: \.self) { option in
                    Button { selection = option } label: {
                        Group {
                            if let icon {
                                Label(title(option), systemImage: icon(option)).labelStyle(.iconOnly)
                            } else {
                                Text(title(option))
                            }
                        }
                        .font(.callout.weight(selection == option ? .semibold : .regular))
                    }
                    .buttonStyle(MacToolbarButtonStyle(selected: selection == option))
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .onMoveCommand { direction in
            guard let index = options.firstIndex(of: selection) else { return }
            if direction == .left, index > 0 { selection = options[index - 1] }
            if direction == .right, index + 1 < options.count { selection = options[index + 1] }
        }
    }
}

enum MacGlassRole {
    case sidebar
    case toolbar
    case selectionBar
    case content

    var material: NSVisualEffectView.Material {
        switch self {
        case .sidebar, .toolbar, .content: .sidebar
        case .selectionBar: .popover
        }
    }

    var blendingMode: NSVisualEffectView.BlendingMode {
        self == .selectionBar ? .withinWindow : .behindWindow
    }
}

struct MacGlassSurface: View {
    let role: MacGlassRole
    @Environment(MacAppearanceStore.self) private var appearance
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    @Environment(\.macUsesContentBackground) private var usesContentBackground

    var body: some View {
        let palette = MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased)
        ZStack {
            if reducesTransparency {
                palette.content
            } else if usesContentBackground {
                palette.glassTint.opacity(role == .selectionBar ? 0.16 : 0.06)
            } else {
                MacVisualEffect(role: role, scheme: scheme)
                palette.glassTint.opacity(
                    appearance.glassOverlayOpacity(for: scheme, reducesTransparency: reducesTransparency)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct MacVisualEffect: NSViewRepresentable {
    let role: MacGlassRole
    let scheme: ColorScheme

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = role.material
        view.blendingMode = role.blendingMode
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != role.material { view.material = role.material }
        if view.blendingMode != role.blendingMode { view.blendingMode = role.blendingMode }
        let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
    }
}

struct MacAppearanceSettingsView: View {
    @Environment(MacAppearanceStore.self) private var appearance
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency

    var body: some View {
        @Bindable var appearance = appearance
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("appearance.title"))
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }

            HStack(spacing: 12) {
                Text(L10n.string("appearance.theme"))
                MacPageTabs(options: MacAppearanceMode.allCases, selection: $appearance.mode, title: { $0.title })
            }
            .accessibilityIdentifier("appearance.theme")

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.string("appearance.transparency"))
                        .font(.headline)
                    Spacer()
                }
                Slider(value: Binding(
                    get: { appearance.transparency(for: scheme) },
                    set: { appearance.setTransparency($0, for: scheme) }
                ), in: 0...1) {
                    Text(L10n.string("appearance.transparency"))
                } minimumValueLabel: {
                    Text(L10n.string("appearance.moreSolid"))
                } maximumValueLabel: {
                    Text(L10n.string("appearance.moreTransparent"))
                }
                .labelsHidden()
                .disabled(reducesTransparency)
                .accessibilityIdentifier("appearance.transparency")
                if reducesTransparency {
                    Text(L10n.string("appearance.reducedTransparency"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .background {
                MacGlassSurface(role: .selectionBar)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            HStack {
                Spacer()
                Button(L10n.string("appearance.reset")) { appearance.reset() }
                    .buttonStyle(MacToolbarButtonStyle())
            }
        }
        .frame(maxWidth: 580, alignment: .leading)
    }
}
