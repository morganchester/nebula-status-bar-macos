import Foundation

final class NebulaPrivilegedHelper: NSObject, NSXPCListenerDelegate, NebulaPrivilegedHelperProtocol {
    private let listener = NSXPCListener(machServiceName: NebulaPrivilegedHelperConstants.machServiceName)

    func run() {
        listener.delegate = self
        listener.resume()
        RunLoop.current.run()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: NebulaPrivilegedHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func runLaunchctl(arguments: [String], withReply reply: @escaping (Int, String, String) -> Void) {
        guard validate(arguments: arguments) else {
            reply(64, "", "Rejected unsupported privileged launchctl request.")
            return
        }

        let result = runPlain("/bin/launchctl", arguments)
        reply(Int(result.status), result.output, result.error)
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

    private func runPlain(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()

            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""

            return (process.terminationStatus, out, err)
        } catch {
            return (1, "", error.localizedDescription)
        }
    }
}

@main
struct PrivilegedHelperMain {
    static func main() {
        let helper = NebulaPrivilegedHelper()
        helper.run()
    }
}
