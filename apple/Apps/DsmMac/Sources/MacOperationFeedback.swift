import DsmLocalization
import SwiftUI

/// 页面与弹窗共用的操作反馈。浮层不改变内容尺寸，关闭提示也不取消操作。
struct MacOperationFeedback<Actions: View>: View {
    let message: String
    var isWorking = false
    var isError = false
    var keepsVisible = false
    var autoDismiss = false
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var dismissed = false

    private var identity: FeedbackIdentity {
        .init(message: message, working: isWorking, error: isError, persistent: keepsVisible)
    }

    var body: some View {
        Group {
            if !dismissed {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        if isWorking {
                            ProgressView().controlSize(.small).padding(.top, 2)
                        } else {
                            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundStyle(isError ? Color.red : Color.accentColor)
                        }
                        Text(message).font(.callout.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        if !isWorking && !keepsVisible {
                            Button {
                                dismissed = true
                                onDismiss?()
                            } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain)
                                .frame(width: 28, height: 28)
                                .accessibilityLabel(L10n.string("files.common.close"))
                                .accessibilityIdentifier("operation.feedback.dismiss")
                        }
                    }
                    actions().buttonStyle(.bordered).controlSize(.small)
                }
                .padding(14)
                .frame(maxWidth: 560, alignment: .leading)
                .background {
                    if reducesTransparency {
                        RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor))
                    } else {
                        RoundedRectangle(cornerRadius: 16).fill(.regularMaterial)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(contrast == .increased ? 0.6 : 0.14)))
                .shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 5)
                .accessibilityElement(children: .contain)
                .transition(reducesMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .task(id: identity) {
                    guard autoDismiss, !isWorking, !isError, !keepsVisible else { return }
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    guard !Task.isCancelled else { return }
                    withAnimation(reducesMotion ? nil : .easeOut(duration: 0.2)) { dismissed = true }
                    onDismiss?()
                }
            }
        }
        .onChange(of: identity) { _, _ in dismissed = false }
    }

    private struct FeedbackIdentity: Hashable {
        let message: String
        let working: Bool
        let error: Bool
        let persistent: Bool
    }
}

extension MacOperationFeedback where Actions == EmptyView {
    init(message: String, isWorking: Bool = false, isError: Bool = false, keepsVisible: Bool = false, autoDismiss: Bool = false, onDismiss: (() -> Void)? = nil) {
        self.message = message
        self.isWorking = isWorking
        self.isError = isError
        self.keepsVisible = keepsVisible
        self.autoDismiss = autoDismiss
        self.onDismiss = onDismiss
        self.actions = { EmptyView() }
    }
}

extension View {
    func macOperationOverlay<Feedback: View>(@ViewBuilder feedback: () -> Feedback) -> some View {
        overlay(alignment: .top) {
            VStack(spacing: 10, content: feedback)
                .padding(.horizontal, 20)
                .padding(.top, 72)
        }
    }
}
