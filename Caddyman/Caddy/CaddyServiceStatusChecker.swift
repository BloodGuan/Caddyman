import Foundation
import Network

enum CaddyServiceObservation: Equatable, Sendable {
    case notChecked
    case checking
    case adminPortResponding(port: UInt16)
    case unavailable

    var summary: String {
        switch self {
        case .notChecked: L10n.text("Not checked")
        case .checking: L10n.text("Checking…")
        case .adminPortResponding(let port): L10n.format("Port %d is open", Int(port))
        case .unavailable: L10n.text("No response on 127.0.0.1:2019")
        }
    }

    var detail: String {
        switch self {
        case .notChecked, .checking:
            L10n.text("The check only probes the local port and does not change Caddy configuration.")
        case .adminPortResponding:
            L10n.text("A local process accepts connections on the default Caddy Admin API port. Process ownership is not confirmed.")
        case .unavailable:
            L10n.text("Caddyman did not find a listener on the default local Admin API port. Caddy may use a custom port or have its Admin API disabled.")
        }
    }
}

protocol CaddyServiceChecking: Sendable {
    func check() async -> CaddyServiceObservation
}

struct LoopbackCaddyServiceChecker: CaddyServiceChecking {
    private let port: UInt16
    private let timeout: TimeInterval

    init(port: UInt16 = 2019, timeout: TimeInterval = 1.2) {
        self.port = port
        self.timeout = timeout
    }

    func check() async -> CaddyServiceObservation {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return .unavailable
        }

        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: endpointPort
            )
            let connection = NWConnection(to: endpoint, using: .tcp)
            let completion = OneShotContinuation(continuation)
            let queue = DispatchQueue(label: "com.blood.caddyman.loopback-status")

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.resume(returning: .adminPortResponding(port: port))
                    connection.cancel()
                case .failed:
                    completion.resume(returning: .unavailable)
                    connection.cancel()
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                completion.resume(returning: .unavailable)
                connection.cancel()
            }
        }
    }
}

private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
