#if DEBUG
import Foundation

/// 仅内存保存 UI 测试通知，不申请系统权限，也不向通知中心写入。
@MainActor
final class MobileChatNotificationUIDriver: MobileChatNotificationDriving {
    var onOpen: ((String, String, String) -> Void)?
    var shouldPresent: ((String) -> Bool)?
    var authorizationValue: MobileChatNotificationAuthorization = .notDetermined
    var grantPermission = true
    private(set) var requestCount = 0
    private(set) var notices: [String: MobileChatNotice] = [:]

    init(denied: Bool = false) { grantPermission = !denied }
    func authorization() async -> MobileChatNotificationAuthorization { authorizationValue }
    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        authorizationValue = grantPermission ? .allowed : .denied
        return grantPermission
    }
    func add(_ notice: MobileChatNotice) async throws { notices[notice.id] = notice }
    func remove(ids: [String]) async { for id in ids { notices[id] = nil } }
    func removeAll(exceptScope: String?) async { notices = notices.filter { $0.value.scope == exceptScope } }
    func removeReminders(scope: String, keepingIDs: Set<String>) async {
        notices = notices.filter { !($0.value.scope == scope && $0.value.date != nil && !keepingIDs.contains($0.key)) }
    }
}
#endif
