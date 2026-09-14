import SwiftUI

/// 与 macOS 的雾白/墨蓝色值一致；不改变文字透明度，也不模拟系统玻璃的私有实现。
struct MobileAppearancePalette {
    let scheme: ColorScheme
    let increasedContrast: Bool

    var content: Color {
        scheme == .dark ? Color(red: 0.105, green: 0.125, blue: 0.15)
            : Color(red: 0.975, green: 0.98, blue: 0.99)
    }
    var glassTint: Color {
        scheme == .dark ? Color(red: 0.12, green: 0.16, blue: 0.205)
            : Color(red: 0.89, green: 0.935, blue: 0.99)
    }
    var card: Color {
        Color(red: 0.36, green: 0.48, blue: 0.62)
            .opacity(increasedContrast ? 0.14 : (scheme == .dark ? 0.10 : 0.055))
    }
    var edge: Color {
        increasedContrast ? Color.primary.opacity(0.55)
            : Color.white.opacity(scheme == .dark ? 0.12 : 0.78)
    }
    var selection: Color {
        Color(red: 0.36, green: 0.48, blue: 0.62)
            .opacity(increasedContrast ? 0.30 : (scheme == .dark ? 0.24 : 0.16))
    }
    var preview: Color {
        scheme == .dark ? Color(red: 0.06, green: 0.075, blue: 0.095)
            : Color(red: 0.92, green: 0.94, blue: 0.97)
    }
}

struct MobileWorkspaceBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let palette = MobileAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased)
        ZStack {
            palette.content
            if !reduceTransparency, contrast != .increased {
                // 固定且轻量的底色给系统材质提供层次；没有逐帧截图或常驻动画。
                LinearGradient(colors: [palette.glassTint.opacity(0.6), palette.content],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum MobileGlassRole { case chrome, card }

private struct MobileGlassModifier: ViewModifier {
    let role: MobileGlassRole
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let palette = MobileAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content.background(palette.content, in: shape)
                .overlay(shape.strokeBorder(palette.edge, lineWidth: 1))
        } else if role == .card {
            // 内容卡片不逐个创建昂贵的玻璃层；浮动控件才参与玻璃合成。
            content.background(palette.card, in: shape)
                .overlay(shape.strokeBorder(palette.edge.opacity(0.5), lineWidth: 0.5))
        } else {
#if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                // iOS 27 的透明度/着色更新由系统处理；不覆盖用户的 Liquid Glass 偏好。
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
                    .overlay(shape.strokeBorder(palette.edge, lineWidth: 0.5))
            }
#else
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(palette.edge, lineWidth: 0.5))
#endif
        }
    }
}

/// 相邻工具栏共享系统合成容器，避免叠加大量独立玻璃采样层。
struct MobileGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var body: some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content() }
        } else {
            content()
        }
#else
        content()
#endif
    }
}

extension View {
    func mobileGlass(_ role: MobileGlassRole = .chrome, radius: CGFloat = 16) -> some View {
        modifier(MobileGlassModifier(role: role, radius: radius))
    }

    func mobileAppearanceRoot() -> some View {
        background(MobileWorkspaceBackground())
            .scrollContentBackground(.hidden)
    }
}
