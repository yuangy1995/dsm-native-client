import SwiftUI

/// 仅描述跨页面的布局节奏，颜色和字体继续使用 SwiftUI 系统语义值。
enum MobileSpacing {
    static let compact: CGFloat = 4
    static let controlGap: CGFloat = 8
    static let content: CGFloat = 16
    static let section: CGFloat = 24
}

enum MobileCornerRadius {
    static let control: CGFloat = 10
    static let card: CGFloat = 16
}

enum MobileMetrics {
    static let minimumTouchTarget: CGFloat = 44
}

enum MobileMotion {
    /// 状态替换只使用短淡入淡出；页面容器会在系统开启“减少动态效果”时禁用它。
    static let stateTransition = Animation.easeOut(duration: 0.2)
}
