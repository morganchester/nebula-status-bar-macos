import Darwin
import Foundation

final class NebulaTraceLogger {
    static let shared = NebulaTraceLogger(processLabel: "HELPER")

    private let processLabel: String
    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(processLabel: String) {
        self.processLabel = processLabel
    }

    func log(_ scope: String, _ message: String) {
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
            fputs("NebulaTraceLogger failed: \(error)\n", stderr)
        }
    }

    private func ensureLogFile() {
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

final class NebulaPrivilegedHelper: NSObject, NSXPCListenerDelegate, NebulaPrivilegedHelperProtocol {
    private let listener = NSXPCListener(machServiceName: NebulaPrivilegedHelperConstants.machServiceName)
    private let fileManager = FileManager.default
    private let allowedNebulaBinaries = [
        "/opt/homebrew/bin/nebula",
        "/opt/homebrew/opt/nebula/bin/nebula",
        "/usr/local/bin/nebula",
        "/usr/local/opt/nebula/bin/nebula"
    ]

    func run() {
        NebulaTraceLogger.shared.log("run", "Helper starting, mach service = \(NebulaPrivilegedHelperConstants.machServiceName)")
        listener.delegate = self
        listener.resume()
        RunLoop.current.run()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        NebulaTraceLogger.shared.log("xpc", "Accepted connection pid = \(newConnection.processIdentifier)")
        newConnection.exportedInterface = NSXPCInterface(with: NebulaPrivilegedHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(withReply reply: @escaping (String) -> Void) {
        let response = "pong pid=\(getpid())"
        NebulaTraceLogger.shared.log("ping", response)
        reply(response)
    }

    func runLaunchctl(arguments: [String], withReply reply: @escaping (Int, String, String) -> Void) {
        NebulaTraceLogger.shared.log("launchctl", "Request arguments = \(arguments)")
        guard validate(arguments: arguments) else {
            NebulaTraceLogger.shared.log("launchctl", "Rejected arguments = \(arguments)")
            reply(64, "", "Rejected unsupported privileged launchctl request.")
            return
        }

        let result = runPlain("/bin/launchctl", arguments)
        NebulaTraceLogger.shared.log(
            "launchctl",
            "Finished status = \(result.status), stdout = \(sanitize(result.output)), stderr = \(sanitize(result.error))"
        )
        reply(Int(result.status), result.output, result.error)
    }

    func startNebula(configPath: String, withReply reply: @escaping (Int, String, String) -> Void) {
        let normalizedConfigPath = normalizeConfigPath(configPath)
        NebulaTraceLogger.shared.log("startNebula", "Request configPath = \(configPath), normalized = \(normalizedConfigPath)")

        guard validateStartConfigPath(normalizedConfigPath) else {
            NebulaTraceLogger.shared.log("startNebula", "Rejected config path = \(normalizedConfigPath)")
            reply(64, "", "Rejected invalid Nebula config path.")
            return
        }

        guard let executablePath = resolveNebulaExecutablePath() else {
            NebulaTraceLogger.shared.log("startNebula", "No supported nebula executable found")
            reply(69, "", "Nebula executable was not found in supported locations.")
            return
        }

        NebulaTraceLogger.shared.log("startNebula", "Using executable = \(executablePath)")

        let existingPIDs = matchingNebulaPIDs(for: normalizedConfigPath)
        if !existingPIDs.isEmpty {
            NebulaTraceLogger.shared.log("startNebula", "Already running pids = \(existingPIDs)")
            reply(0, "Nebula is already running for \(normalizedConfigPath).", "")
            return
        }

        let process = Process()
        let stdoutURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stderrURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-config", normalizedConfigPath]

        do {
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                try? fileManager.removeItem(at: stdoutURL)
                try? fileManager.removeItem(at: stderrURL)
            }

            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            try process.run()
            NebulaTraceLogger.shared.log("startNebula", "Spawned pid = \(process.processIdentifier)")
            if waitForNebulaLaunch(configPath: normalizedConfigPath, timeout: 2.0) {
                let pids = matchingNebulaPIDs(for: normalizedConfigPath)
                NebulaTraceLogger.shared.log("startNebula", "Confirmed running pids = \(pids)")
                reply(0, "Started Nebula with \(normalizedConfigPath).", "")
                return
            }

            let pid = process.processIdentifier
            if process.isRunning {
                NebulaTraceLogger.shared.log("startNebula", "Process still running but no validated match, terminating pid = \(pid)")
                process.terminate()
                process.waitUntilExit()
            }

            let output = String(data: (try? Data(contentsOf: stdoutURL)) ?? Data(), encoding: .utf8) ?? ""
            let error = String(data: (try? Data(contentsOf: stderrURL)) ?? Data(), encoding: .utf8) ?? ""

            let details = [error, output]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
                ?? "Nebula did not stay running after launch."

            NebulaTraceLogger.shared.log(
                "startNebula",
                "Launch failed pid = \(pid), stdout = \(sanitize(output)), stderr = \(sanitize(error)), details = \(sanitize(details))"
            )

            reply(1, "", "Failed to start Nebula for \(normalizedConfigPath) [pid \(pid)]: \(details)")
        } catch {
            NebulaTraceLogger.shared.log("startNebula", "Spawn failed error = \(error.localizedDescription)")
            reply(1, "", "Failed to start Nebula: \(error.localizedDescription)")
            return
        }
    }

    func stopNebula(configPath: String, withReply reply: @escaping (Int, String, String) -> Void) {
        let normalizedConfigPath = normalizeConfigPath(configPath)
        NebulaTraceLogger.shared.log("stopNebula", "Request configPath = \(configPath), normalized = \(normalizedConfigPath)")

        guard validateLookupConfigPath(normalizedConfigPath) else {
            NebulaTraceLogger.shared.log("stopNebula", "Rejected config path = \(normalizedConfigPath)")
            reply(64, "", "Rejected invalid Nebula config path.")
            return
        }

        let initialPIDs = matchingNebulaPIDs(for: normalizedConfigPath)
        NebulaTraceLogger.shared.log("stopNebula", "Initial matching pids = \(initialPIDs)")
        if initialPIDs.isEmpty {
            reply(0, "Nebula is not running for \(normalizedConfigPath).", "")
            return
        }

        for pid in initialPIDs {
            NebulaTraceLogger.shared.log("stopNebula", "Sending SIGTERM to pid = \(pid)")
            _ = kill(pid, SIGTERM)
        }

        if waitForTermination(of: initialPIDs, timeout: 2.0) {
            NebulaTraceLogger.shared.log("stopNebula", "Stopped after SIGTERM")
            reply(0, "Stopped Nebula for \(normalizedConfigPath).", "")
            return
        }

        let remainingPIDs = matchingNebulaPIDs(for: normalizedConfigPath)
        NebulaTraceLogger.shared.log("stopNebula", "Remaining pids after SIGTERM = \(remainingPIDs)")
        for pid in remainingPIDs {
            NebulaTraceLogger.shared.log("stopNebula", "Sending SIGKILL to pid = \(pid)")
            _ = kill(pid, SIGKILL)
        }

        if waitForTermination(of: remainingPIDs, timeout: 1.0) {
            NebulaTraceLogger.shared.log("stopNebula", "Stopped after SIGKILL")
            reply(0, "Stopped Nebula for \(normalizedConfigPath).", "")
            return
        }

        NebulaTraceLogger.shared.log("stopNebula", "Failed to stop configPath = \(normalizedConfigPath)")
        reply(1, "", "Failed to stop Nebula for \(normalizedConfigPath).")
    }

    private func validate(arguments: [String]) -> Bool {
        guard let command = arguments.first else {
            return false
        }

        switch command {
        case "bootstrap":
            guard arguments.count == 3 else {
                return false
            }

            return arguments[1] == "system" && looksLikeNebulaPlistPath(arguments[2])
        case "bootout":
            guard arguments.count == 2 else {
                return false
            }

            return looksLikeNebulaServiceTarget(arguments[1])
        case "kickstart":
            guard arguments.count == 3 else {
                return false
            }

            return arguments[1] == "-k" && looksLikeNebulaServiceTarget(arguments[2])
        default:
            return false
        }
    }

    private func looksLikeNebulaPlistPath(_ value: String) -> Bool {
        let normalized = value.lowercased()
        guard normalized.hasSuffix(".plist") else {
            return false
        }

        return normalized.contains("nebula")
    }

    private func looksLikeNebulaServiceTarget(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.hasPrefix("system/") && normalized.contains("nebula")
    }

    private func validateStartConfigPath(_ value: String) -> Bool {
        guard !value.isEmpty else {
            NebulaTraceLogger.shared.log("validateStartConfigPath", "Rejected empty value")
            return false
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: value, isDirectory: &isDirectory) else {
            NebulaTraceLogger.shared.log("validateStartConfigPath", "Path does not exist = \(value)")
            return false
        }

        let isValid = isDirectory.boolValue || fileManager.isReadableFile(atPath: value)
        NebulaTraceLogger.shared.log(
            "validateStartConfigPath",
            "Path = \(value), isDirectory = \(isDirectory.boolValue), readable = \(fileManager.isReadableFile(atPath: value)), valid = \(isValid)"
        )
        return isValid
    }

    private func validateLookupConfigPath(_ value: String) -> Bool {
        let isValid = !value.isEmpty
        NebulaTraceLogger.shared.log("validateLookupConfigPath", "Path = \(value), valid = \(isValid)")
        return isValid
    }

    private func resolveNebulaExecutablePath() -> String? {
        for candidate in allowedNebulaBinaries {
            if fileManager.isExecutableFile(atPath: candidate) {
                NebulaTraceLogger.shared.log("resolveNebulaExecutablePath", "Selected candidate = \(candidate)")
                return candidate
            }

            NebulaTraceLogger.shared.log("resolveNebulaExecutablePath", "Skipped non-executable candidate = \(candidate)")
        }

        return nil
    }

    private func normalizeConfigPath(_ value: String) -> String {
        let expanded = (value as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath

        guard standardized.count > 1 else {
            return standardized
        }

        return standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty ? "/" : standardized.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private func matchingNebulaPIDs(for configPath: String) -> [pid_t] {
        let result = runPlain("/usr/bin/pgrep", ["-fal", "nebula"])
        guard result.status == 0 else {
            NebulaTraceLogger.shared.log(
                "matchingNebulaPIDs",
                "ps failed status = \(result.status), stdout = \(sanitize(result.output)), stderr = \(sanitize(result.error))"
            )
            return []
        }

        var matches: [pid_t] = []
        var nebulaLikeLines: [String] = []

        for line in result.output.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                continue
            }

            let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = pid_t(parts[0]) else {
                continue
            }

            let arguments = String(parts[1])
            if arguments.lowercased().contains("nebula") {
                nebulaLikeLines.append(text)
            }

            guard commandLineStartsWithNebula(arguments) else {
                continue
            }

            if commandLine(arguments, containsConfigPath: configPath) {
                matches.append(pid)
            }
        }

        NebulaTraceLogger.shared.log(
            "matchingNebulaPIDs",
            "configPath = \(configPath), nebulaLikeLines = \(sanitize(nebulaLikeLines.joined(separator: " || "))), matches = \(matches)"
        )

        return matches
    }

    private func commandLine(_ arguments: String, containsConfigPath configPath: String) -> Bool {
        let patterns = [
            "-config \(configPath)",
            "--config \(configPath)",
            "-config=\(configPath)",
            "--config=\(configPath)"
        ]

        return patterns.contains { arguments.contains($0) }
    }

    private func commandLineStartsWithNebula(_ arguments: String) -> Bool {
        guard let executable = arguments.split(whereSeparator: \.isWhitespace).first else {
            return false
        }

        let matches = URL(fileURLWithPath: String(executable)).lastPathComponent == "nebula"
        if arguments.lowercased().contains("nebula") {
            NebulaTraceLogger.shared.log(
                "commandLineStartsWithNebula",
                "arguments = \(sanitize(arguments)), matches = \(matches)"
            )
        }
        return matches
    }

    private func waitForNebulaLaunch(configPath: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if !matchingNebulaPIDs(for: configPath).isEmpty {
                NebulaTraceLogger.shared.log("waitForNebulaLaunch", "Matched running process for configPath = \(configPath)")
                return true
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        NebulaTraceLogger.shared.log("waitForNebulaLaunch", "Timed out waiting for configPath = \(configPath)")
        return false
    }

    private func waitForTermination(of pids: [pid_t], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let stillRunning = pids.filter { kill($0, 0) == 0 }
            if stillRunning.isEmpty {
                return true
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        return pids.allSatisfy { kill($0, 0) != 0 }
    }

    private func runPlain(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String, error: String) {
        NebulaTraceLogger.shared.log("runPlain", "Executing \(executable) \(arguments.joined(separator: " "))")
        let process = Process()
        let temporaryDirectory = fileManager.temporaryDirectory
        let stdoutURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stderrURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)

        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        do {
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                try? fileManager.removeItem(at: stdoutURL)
                try? fileManager.removeItem(at: stderrURL)
            }

            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            try process.run()
            process.waitUntilExit()

            let outData = (try? Data(contentsOf: stdoutURL)) ?? Data()
            let errData = (try? Data(contentsOf: stderrURL)) ?? Data()

            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""

            NebulaTraceLogger.shared.log(
                "runPlain",
                "Completed \(executable) status = \(process.terminationStatus), stdout = \(sanitize(out)), stderr = \(sanitize(err))"
            )
            return (process.terminationStatus, out, err)
        } catch {
            NebulaTraceLogger.shared.log("runPlain", "Failed \(executable) error = \(error.localizedDescription)")
            return (1, "", error.localizedDescription)
        }
    }

    private func sanitize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "<empty>"
        }

        let normalized = trimmed.replacingOccurrences(of: "\n", with: "\\n")
        if normalized.count > 1200 {
            return String(normalized.prefix(1200)) + "...<truncated>"
        }

        return normalized
    }
}

@main
struct PrivilegedHelperMain {
    static func main() {
        let helper = NebulaPrivilegedHelper()
        helper.run()
    }
}
