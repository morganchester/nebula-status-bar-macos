import Foundation

final class NebulaTraceLogger {
    nonisolated(unsafe) static let shared = NebulaTraceLogger(processLabel: "APP")

    private let processLabel: String
    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated init(processLabel: String) {
        self.processLabel = processLabel
    }

    nonisolated func log(_ scope: String, _ message: String) {
        guard NebulaPrivilegedHelperConstants.isDebugEnabled() else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        ensureLogFile()

        let timestamp = formatter.string(from: Date())
        let threadLabel = Thread.isMainThread ? "main" : "background"
        let line = "\(timestamp) [\(processLabel)] [pid:\(getpid())] [\(threadLabel)] [\(scope)] \(message)\n"

        guard let data = line.data(using: .utf8) else {
            return
        }

        let url = URL(fileURLWithPath: NebulaPrivilegedHelperConstants.logFilePath)

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            NSLog("NebulaTraceLogger failed: \(error.localizedDescription)")
        }
    }

    nonisolated private func ensureLogFile() {
        let directoryPath = NebulaPrivilegedHelperConstants.logDirectoryPath
        let filePath = NebulaPrivilegedHelperConstants.logFilePath

        if !fileManager.fileExists(atPath: directoryPath) {
            try? fileManager.createDirectory(
                atPath: directoryPath,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o777]
            )
        }

        if !fileManager.fileExists(atPath: filePath) {
            fileManager.createFile(
                atPath: filePath,
                contents: nil,
                attributes: [.posixPermissions: 0o666]
            )
        }

        try? fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directoryPath)
        try? fileManager.setAttributes([.posixPermissions: 0o666], ofItemAtPath: filePath)
    }
}
