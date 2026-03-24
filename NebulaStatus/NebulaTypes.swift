import Foundation

enum LaunchctlDomain: Hashable {
    case system
    case gui(UInt32)

    var target: String {
        switch self {
        case .system:
            return "system"
        case let .gui(userID):
            return "gui/\(userID)"
        }
    }

    var requiresPrivileges: Bool {
        switch self {
        case .system:
            return true
        case .gui:
            return false
        }
    }
}

enum NebulaServiceKind: Hashable {
    case launchd(label: String, plistPath: String, domain: LaunchctlDomain)
    case manual
}

struct ManualNebulaEntry: Identifiable, Codable, Hashable {
    let id: String
    var configPath: String
}

struct NebulaService: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let detectedConfigPath: String?
    let kind: NebulaServiceKind

    var isManual: Bool {
        if case .manual = kind {
            return true
        }

        return false
    }

    var plistPath: String? {
        guard case let .launchd(_, path, _) = kind else {
            return nil
        }

        return path
    }

    var launchdLabel: String? {
        guard case let .launchd(label, _, _) = kind else {
            return nil
        }

        return label
    }

    var domain: LaunchctlDomain? {
        guard case let .launchd(_, _, domain) = kind else {
            return nil
        }

        return domain
    }
}

enum ServiceState: String {
    case running = "RUNNING"
    case stopped = "STOPPED"
    case unknown = "UNKNOWN"
}

struct AppMetadata {
    let name: String
    let version: String
    let build: String
    let bundleIdentifier: String

    static let current = AppMetadata(
        name: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "NebulaStatus",
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.2",
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2",
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "underclub.NebulaStatus"
    )

    var versionLine: String {
        "\(name) \(version) (\(build))"
    }
}

enum PrivilegedHelperState: Equatable {
    case enabled
    case unreachable
    case notRegistered
    case requiresApproval
    case notFound

    var title: String {
        switch self {
        case .enabled:
            return "Ready"
        case .unreachable:
            return "Unreachable"
        case .notRegistered:
            return "Not installed"
        case .requiresApproval:
            return "Awaiting approval"
        case .notFound:
            return "Missing from bundle"
        }
    }

    var needsAttention: Bool {
        self != .enabled
    }
}

struct PrivilegedHelperFailure: Error {
    let message: String
}
