import Foundation
import ServiceManagement

enum CaddymanLoginStatus: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
protocol CaddymanLoginManaging: AnyObject {
    func status() -> CaddymanLoginStatus
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
final class CaddymanLoginItem: CaddymanLoginManaging {
    func status() -> CaddymanLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
