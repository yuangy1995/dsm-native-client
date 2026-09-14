import SwiftUI

/// 玻璃仅用于导航／控制层；照片和正文保持清晰。旧系统使用原生 Material。
struct MobileGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 20
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Color(uiColor: .secondarySystemBackground), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
        } else {
            modernSurface(content)
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    @ViewBuilder
    private func modernSurface(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            materialSurface(content)
        }
        #else
        materialSurface(content)
        #endif
    }

    private func materialSurface(_ content: Content) -> some View {
        content.background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

extension View {
    func mobileGlass(cornerRadius: CGFloat = 20) -> some View {
        modifier(MobileGlassSurface(cornerRadius: cornerRadius))
    }
}

struct MobileWorkspaceBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            if !reduceTransparency {
                LinearGradient(colors: [Color.accentColor.opacity(scheme == .dark ? 0.12 : 0.06), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}
