import Foundation
import ServiceManagement

enum LoginItem {
    enum ChangeResult {
        case applied
        case pendingApproval
        case failed
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> ChangeResult {
        do {
            if on {
                if isEnabled { return .applied }
                if requiresApproval { return .pendingApproval }
                try SMAppService.mainApp.register()
            } else {
                if !isEnabled && !requiresApproval { return .applied }
                try SMAppService.mainApp.unregister()
            }
            if isEnabled == on { return .applied }
            if requiresApproval {
                NSLog("LoginItem change requires approval; status=\(String(describing: SMAppService.mainApp.status))")
                return .pendingApproval
            }
            return .failed
        } catch {
            NSLog("LoginItem toggle failed: \(error.localizedDescription)")
            return .failed
        }
    }
}
