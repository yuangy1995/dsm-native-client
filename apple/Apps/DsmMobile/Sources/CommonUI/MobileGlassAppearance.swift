import SwiftUI

/// 与 MacAppearancePalette 同源的雾蓝/墨蓝层次；不改变系统文字、触控或辅助功能语义。
struct MobileGlassPalette {
    let scheme: ColorScheme
    let increasedContrast: Bool
    var content: Color {
        scheme == .dark
            ? Color(red: 0.105, green: 0.125, blue: 0.15)
            : Color(red: 0.975, green: 0.98, blue: 0.99)
    }
    var tint: Color {
        scheme == .dark
            ? Color(red: 0.12, green: 0.16, blue: 0.205)
            : Color(red: 0.89, green: 0.935, blue: 0.99)
    }
    var card: Color {
        Color(red: 0.36, green: 0.48, blue: 0.62)
            .opacity(increasedContrast ? 0.14 : (scheme == .dark ? 0.10 : 0.055))
    }
    var edge: Color {
        increasedContrast ? Color.primary.opacity(0.45)
            : (scheme == .dark ? .white.opacity(0.12) : .white.opacity(0.78))
    }
}

struct MobileGlassBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let palette = MobileGlassPalette(scheme: scheme, increasedContrast: contrast == .increased)
        ZStack {
            palette.content
            if !reduceTransparency {
                LinearGradient(colors: [palette.tint.opacity(0.8), palette.content],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Liquid Glass 只用于导航与操作层，不对照片网格逐项做模糊。
/// iOS 27 使用系统当前材质；旧 SDK 可编译回退分支，最低系统仍为 iOS 17。
private struct MobileGlassChrome: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        let palette = MobileGlassPalette(scheme: scheme, increasedContrast: contrast == .increased)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content.background(palette.content, in: shape)
                .overlay(shape.strokeBorder(palette.edge, lineWidth: 1))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.ultraThinMaterial, in: shape)
                    .overlay(shape.strokeBorder(palette.edge, lineWidth: 0.5))
            }
            #else
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(palette.edge, lineWidth: 0.5))
            #endif
        }
    }
}

/// 同一工具栏中的玻璃由系统合并采样，避免为每个按钮创建额外渲染层。
struct MobileGlassGroup<Content: View>: View {
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    @ViewBuilder var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else { content }
        #else
        content
        #endif
    }
}

private struct MobileGlassCard: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let palette = MobileGlassPalette(scheme: scheme, increasedContrast: contrast == .increased)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background(palette.card, in: shape)
            .overlay(shape.strokeBorder(palette.edge, lineWidth: contrast == .increased ? 1 : 0.5))
    }
}

extension View {
    func mobileGlassChrome(cornerRadius: CGFloat = 16) -> some View {
        modifier(MobileGlassChrome(cornerRadius: cornerRadius))
    }
    func mobileGlassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(MobileGlassCard(cornerRadius: cornerRadius))
    }
    func mobileGlassWorkspace() -> some View {
        scrollContentBackground(.hidden).background { MobileGlassBackground() }
    }
}
