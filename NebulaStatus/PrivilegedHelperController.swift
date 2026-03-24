import Foundation
import ServiceManagement

final class PrivilegedHelperController {
    private let service = SMAppService.daemon(plistName: NebulaPrivilegedHelperConstants.plistName)
    private static let xpcTimeout: TimeInterval = 10
    private static let healthcheckTimeout: TimeInterval = 2

    func currentState() -> PrivilegedHelperState {
        switch service.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func registerIfNeeded() -> Result<PrivilegedHelperState, PrivilegedHelperFailure> {
        let initialState = currentState()
        if initialState == .enabled {
            return .success(initialState)
        }

        do {
            try service.register()
        } catch {
            let stateAfterFailure = currentState()
            if stateAfterFailure == .requiresApproval || stateAfterFailure == .enabled {
                return .success(stateAfterFailure)
            }

            return .failure(.init(message: "Failed to register privileged helper: \(error.localizedDescription)"))
        }

        return .success(currentState())
    }

    func repairRegistration() -> Result<PrivilegedHelperState, PrivilegedHelperFailure> {
        do {
            try? service.unregister()
            try service.register()
        } catch {
            let fallbackState = currentState()
            if fallbackState == .requiresApproval || fallbackState == .enabled {
                return .success(fallbackState)
            }

            return .failure(.init(message: "Failed to repair privileged helper: \(error.localizedDescription)"))
        }

        return .success(currentState())
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func probeReachability(completion: @escaping (Bool) -> Void) {
        guard currentState() == .enabled else {
            completion(false)
            return
        }

        performPing(timeout: Self.healthcheckTimeout, completion: completion)
    }

    func runLaunchctl(arguments: [String], completion: @escaping (Result<(Int32, String, String), PrivilegedHelperFailure>) -> Void) {
        perform(completion: completion) { proxy, reply in
            proxy.runLaunchctl(arguments: arguments, withReply: reply)
        }
    }

    func startNebula(configPath: String, completion: @escaping (Result<(Int32, String, String), PrivilegedHelperFailure>) -> Void) {
        perform(completion: completion) { proxy, reply in
            proxy.startNebula(configPath: configPath, withReply: reply)
        }
    }

    func stopNebula(configPath: String, completion: @escaping (Result<(Int32, String, String), PrivilegedHelperFailure>) -> Void) {
        perform(completion: completion) { proxy, reply in
            proxy.stopNebula(configPath: configPath, withReply: reply)
        }
    }

    private func performPing(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        NebulaTraceLogger.shared.log("xpc", "Opening ping connection to \(NebulaPrivilegedHelperConstants.machServiceName)")
        let connection = NSXPCConnection(
            machServiceName: NebulaPrivilegedHelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: NebulaPrivilegedHelperProtocol.self)

        let completionLock = NSLock()
        var didFinish = false
        var timeoutWorkItem: DispatchWorkItem?

        let finish: (Bool) -> Void = { reachable in
            completionLock.lock()
            defer { completionLock.unlock() }

            guard !didFinish else {
                NebulaTraceLogger.shared.log("xpc", "Ignoring duplicate ping completion")
                return
            }

            didFinish = true
            timeoutWorkItem?.cancel()
            connection.invalidate()
            completion(reachable)
        }

        connection.interruptionHandler = {
            NebulaTraceLogger.shared.log("xpc", "Ping connection interrupted")
            finish(false)
        }

        connection.invalidationHandler = {
            NebulaTraceLogger.shared.log("xpc", "Ping connection invalidated")
        }

        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            NebulaTraceLogger.shared.log("xpc", "Ping connection error = \(error.localizedDescription)")
            finish(false)
        } as? NebulaPrivilegedHelperProtocol

        guard let proxy else {
            NebulaTraceLogger.shared.log("xpc", "Ping proxy unavailable")
            finish(false)
            return
        }

        DispatchQueue.global(qos: .utility).async {
            proxy.ping { response in
                NebulaTraceLogger.shared.log("xpc", "Ping reply = \(Self.sanitize(response))")
                finish(true)
            }
        }

        let workItem = DispatchWorkItem {
            NebulaTraceLogger.shared.log("xpc", "Ping timed out after \(Int(timeout)) seconds")
            finish(false)
        }
        timeoutWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func perform(
        completion: @escaping (Result<(Int32, String, String), PrivilegedHelperFailure>) -> Void,
        invocation: @escaping (NebulaPrivilegedHelperProtocol, @escaping (Int, String, String) -> Void) -> Void
    ) {
        NebulaTraceLogger.shared.log("xpc", "Opening privileged helper connection to \(NebulaPrivilegedHelperConstants.machServiceName)")
        let connection = NSXPCConnection(
            machServiceName: NebulaPrivilegedHelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: NebulaPrivilegedHelperProtocol.self)
        let completionLock = NSLock()
        var didFinish = false

        let finish: (Result<(Int32, String, String), PrivilegedHelperFailure>) -> Void = { result in
            completionLock.lock()
            defer { completionLock.unlock() }

            guard !didFinish else {
                NebulaTraceLogger.shared.log("xpc", "Ignoring duplicate completion")
                return
            }

            didFinish = true
            connection.invalidate()
            completion(result)
        }

        connection.interruptionHandler = {
            NebulaTraceLogger.shared.log("xpc", "Connection interrupted")
            finish(.failure(.init(message: "Privileged helper connection was interrupted.")))
        }

        connection.invalidationHandler = {
            NebulaTraceLogger.shared.log("xpc", "Connection invalidated")
        }

        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            NebulaTraceLogger.shared.log("xpc", "Connection error = \(error.localizedDescription)")
            finish(.failure(.init(message: "Privileged helper connection failed: \(error.localizedDescription)")))
        } as? NebulaPrivilegedHelperProtocol

        guard let proxy else {
            NebulaTraceLogger.shared.log("xpc", "Proxy unavailable")
            finish(.failure(.init(message: "Privileged helper interface is unavailable.")))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            NebulaTraceLogger.shared.log("xpc", "Dispatching helper invocation off main thread")
            invocation(proxy) { status, output, error in
                NebulaTraceLogger.shared.log(
                    "xpc",
                    "Reply status = \(status), stdout = \(Self.sanitize(output)), stderr = \(Self.sanitize(error))"
                )
                finish(.success((Int32(status), output, error)))
            }
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.xpcTimeout) {
            NebulaTraceLogger.shared.log("xpc", "Connection timed out after \(Int(Self.xpcTimeout)) seconds")
            finish(.failure(.init(message: "Privileged helper did not respond within \(Int(Self.xpcTimeout)) seconds.")))
        }
    }

    private static func sanitize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "<empty>"
        }

        return trimmed.replacingOccurrences(of: "\n", with: "\\n")
    }
}

enum HelperOperation {
    case launchctl([String])
    case startNebula(String)
    case stopNebula(String)
}
