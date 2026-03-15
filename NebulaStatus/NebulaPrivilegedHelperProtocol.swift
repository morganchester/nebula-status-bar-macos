import Foundation

enum NebulaPrivilegedHelperConstants {
    static let plistName = "underclub.NebulaStatus.PrivilegedHelper.plist"
    static let machServiceName = "underclub.NebulaStatus.PrivilegedHelper"
    static let executableName = "underclub.NebulaStatus.PrivilegedHelper"
    static let logDirectoryPath = "/Users/Shared/NebulaStatus"
    static let logFilePath = "/Users/Shared/NebulaStatus/nebula-status.log"
    static let debugFlagPath = "/Users/Shared/NebulaStatus/debug-on"

    static func isDebugEnabled() -> Bool {
        FileManager.default.fileExists(atPath: debugFlagPath)
    }

    static func setDebugEnabled(_ enabled: Bool) throws {
        let fileManager = FileManager.default

        if enabled {
            try ensureSharedDirectoryExists(fileManager: fileManager)
            if !fileManager.fileExists(atPath: debugFlagPath) {
                fileManager.createFile(
                    atPath: debugFlagPath,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o666]
                )
            }
            try? fileManager.setAttributes([.posixPermissions: 0o666], ofItemAtPath: debugFlagPath)
            return
        }

        if fileManager.fileExists(atPath: debugFlagPath) {
            try fileManager.removeItem(atPath: debugFlagPath)
        }

        if fileManager.fileExists(atPath: logFilePath) {
            try? fileManager.removeItem(atPath: logFilePath)
        }
    }

    private static func ensureSharedDirectoryExists(fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: logDirectoryPath) {
            try fileManager.createDirectory(
                atPath: logDirectoryPath,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o777]
            )
        }

        try? fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: logDirectoryPath)
    }
}

@objc protocol NebulaPrivilegedHelperProtocol: NSObjectProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func runLaunchctl(arguments: [String], withReply reply: @escaping (Int, String, String) -> Void)
    func startNebula(configPath: String, withReply reply: @escaping (Int, String, String) -> Void)
    func stopNebula(configPath: String, withReply reply: @escaping (Int, String, String) -> Void)
}
