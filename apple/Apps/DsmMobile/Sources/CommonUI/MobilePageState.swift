/// 页面在一次内容加载周期中的稳定状态，不携带本地化文案或业务数据。
enum MobilePageState: String, CaseIterable, Equatable, Sendable {
    case loading
    case empty
    case filteredEmpty
    case error
    case content

    var showsContent: Bool {
        self == .content
    }

    var showsRecoveryAction: Bool {
        self == .error
    }

    var layout: MobilePageLayout {
        switch self {
        case .filteredEmpty, .content:
            .topLeading
        case .loading, .empty, .error:
            .centered
        }
    }
}

enum MobilePageLayout: Equatable, Sendable {
    case centered
    case topLeading
}

/// 页面状态所需的展示文案全部由调用方提供，避免组件内新增硬编码用户文案。
struct MobilePageStateLabels {
    let loading: String
    let emptyTitle: String
    let emptyMessage: String
    let filteredEmptyTitle: String
    let filteredEmptyMessage: String
    let errorTitle: String
    let errorMessage: String
    let retryTitle: String

    init(
        loading: String,
        emptyTitle: String,
        emptyMessage: String,
        filteredEmptyTitle: String,
        filteredEmptyMessage: String,
        errorTitle: String,
        errorMessage: String,
        retryTitle: String
    ) {
        self.loading = loading
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.filteredEmptyTitle = filteredEmptyTitle
        self.filteredEmptyMessage = filteredEmptyMessage
        self.errorTitle = errorTitle
        self.errorMessage = errorMessage
        self.retryTitle = retryTitle
    }
}
