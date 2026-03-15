import SwiftUI
import AppKit
import Combine
import Foundation
import ServiceManagement

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

struct NebulaService: Identifiable, Hashable {
    let title: String
    let label: String
    let plistPath: String
    let configPath: String?
    let domain: LaunchctlDomain

    var id: String {
        "\(domain.target):\(label)"
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
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1",
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "underclub.NebulaStatus"
    )

    var versionLine: String {
        "\(name) \(version) (\(build))"
    }
}

enum PrivilegedHelperState: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound

    var title: String {
        switch self {
        case .enabled:
            return "Ready"
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

final class PrivilegedHelperController {
    private let service = SMAppService.daemon(plistName: NebulaPrivilegedHelperConstants.plistName)

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

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func runLaunchctl(arguments: [String], completion: @escaping (Result<(Int32, String, String), PrivilegedHelperFailure>) -> Void) {
        let connection = NSXPCConnection(
            machServiceName: NebulaPrivilegedHelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: NebulaPrivilegedHelperProtocol.self)
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            connection.invalidate()
            completion(.failure(.init(message: "Privileged helper connection failed: \(error.localizedDescription)")))
        } as? NebulaPrivilegedHelperProtocol

        guard let proxy else {
            connection.invalidate()
            completion(.failure(.init(message: "Privileged helper interface is unavailable.")))
            return
        }

        proxy.runLaunchctl(arguments: arguments) { status, output, error in
            connection.invalidate()
            completion(.success((Int32(status), output, error)))
        }
    }
}

@MainActor
final class NebulaModel: ObservableObject {
    @Published var services: [NebulaService] = []
    @Published var serviceStates: [String: ServiceState] = [:]
    @Published var lastError: String = ""
    @Published var isBusy = false
    @Published var helperState: PrivilegedHelperState = .notRegistered

    private let fileManager = FileManager.default
    private let helperController = PrivilegedHelperController()
    private let launchDirectories: [(path: String, domain: LaunchctlDomain)]
    private let extraPlistSources: [(url: URL, domain: LaunchctlDomain)]
    private var timer: Timer?

    init() {
        let userDomain = LaunchctlDomain.gui(getuid())
        self.launchDirectories = [
            ("/Library/LaunchDaemons", .system),
            ("/Library/LaunchAgents", userDomain),
            ("\(NSHomeDirectory())/Library/LaunchAgents", userDomain)
        ]
        self.extraPlistSources = NebulaModel.makeExtraPlistSources(userDomain: userDomain)

        refreshAll()
        startPolling()
    }

    deinit {
        timer?.invalidate()
    }

    var helperStatusText: String {
        helperState.title
    }

    var helperHintText: String {
        switch helperState {
        case .enabled:
            return "Root commands run through a bundled XPC launch daemon."
        case .notRegistered:
            return "Install the helper once to run system launchctl commands through Service Management."
        case .requiresApproval:
            return "Approve the helper in System Settings > Login Items."
        case .notFound:
            return "The helper files are missing from the app bundle. Rebuild the app."
        }
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let model = self else {
                return
            }

            Task { @MainActor [model] in
                model.refreshAll()
            }
        }
    }

    func refreshAll() {
        refreshHelperState()
        services = discoverServices()

        let validServiceIDs = Set(services.map(\.id))
        serviceStates = serviceStates.filter { validServiceIDs.contains($0.key) }

        refreshStates()
    }

    func refreshStates() {
        for service in services {
            serviceStates[service.id] = queryState(for: service)
        }
    }

    func refreshHelperState() {
        helperState = helperController.currentState()
    }

    func installHelper() {
        lastError = ""

        switch helperController.registerIfNeeded() {
        case let .success(state):
            helperState = state
            if state == .requiresApproval {
                lastError = "Privileged helper installed. Open System Settings > Login Items and approve it."
            }
        case let .failure(error):
            helperState = helperController.currentState()
            lastError = error.message
        }
    }

    func openHelperSettings() {
        helperController.openSystemSettings()
    }

    func stateText(for service: NebulaService) -> String {
        serviceStates[service.id, default: .unknown].rawValue
    }

    func isRunning(_ service: NebulaService) -> Bool {
        serviceStates[service.id, default: .unknown] == .running
    }

    func toggle(_ service: NebulaService) {
        if isRunning(service) {
            stop(service)
        } else {
            start(service)
        }
    }

    func start(_ service: NebulaService) {
        performLaunchctl(
            ["bootstrap", service.domain.target, service.plistPath],
            for: service
        )
    }

    func stop(_ service: NebulaService) {
        performLaunchctl(
            ["bootout", "\(service.domain.target)/\(service.label)"],
            for: service
        )
    }

    func restart(_ service: NebulaService) {
        performLaunchctl(
            ["kickstart", "-k", "\(service.domain.target)/\(service.label)"],
            for: service
        )
    }

    func openConfig(_ service: NebulaService) {
        guard let configPath = service.configPath else {
            lastError = "Config path not found in \(service.plistPath)"
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath)])
    }

    func openPlist(_ service: NebulaService) {
        NSWorkspace.shared.selectFile(service.plistPath, inFileViewerRootedAtPath: "/")
    }

    private func performLaunchctl(_ arguments: [String], for service: NebulaService) {
        if service.domain.requiresPrivileges {
            runViaHelper(arguments)
        } else {
            runDirect(arguments)
        }
    }

    private func runViaHelper(_ arguments: [String]) {
        lastError = ""

        switch helperController.registerIfNeeded() {
        case let .failure(error):
            helperState = helperController.currentState()
            lastError = error.message
            return
        case let .success(state):
            helperState = state

            guard state == .enabled else {
                lastError = "Privileged helper is not ready. \(helperHintText)"
                return
            }
        }

        isBusy = true

        helperController.runLaunchctl(arguments: arguments) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.isBusy = false
                self.refreshHelperState()

                switch result {
                case let .success((status, output, error)):
                    if status != 0 {
                        self.lastError = (error.isEmpty ? output : error)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        self.lastError = ""
                        self.refreshSoon()
                    }
                case let .failure(error):
                    self.lastError = error.message
                }
            }
        }
    }

    private func runDirect(_ arguments: [String]) {
        isBusy = true
        lastError = ""

        let result = runPlain("/bin/launchctl", arguments)

        isBusy = false

        if result.status != 0 {
            lastError = (result.error.isEmpty ? result.output : result.error)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.refreshStates()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.refreshStates()
        }
    }

    private func discoverServices() -> [NebulaService] {
        var discovered: [NebulaService] = []
        var seenIDs: Set<String> = []

        for source in launchDirectories {
            let directoryURL = URL(fileURLWithPath: source.path, isDirectory: true)
            let plistURLs: [URL]

            do {
                plistURLs = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                continue
            }

            for plistURL in plistURLs where plistURL.pathExtension == "plist" {
                guard let service = loadService(from: plistURL, domain: source.domain) else {
                    continue
                }

                if seenIDs.insert(service.id).inserted {
                    discovered.append(service)
                }
            }
        }

        for source in extraPlistSources {
            guard let service = loadService(from: source.url, domain: source.domain) else {
                continue
            }

            if seenIDs.insert(service.id).inserted {
                discovered.append(service)
            }
        }

        return discovered.sorted { lhs, rhs in
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleOrder == .orderedSame {
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }

            return titleOrder == .orderedAscending
        }
    }

    private static func makeExtraPlistSources(userDomain: LaunchctlDomain) -> [(url: URL, domain: LaunchctlDomain)] {
        let fileManager = FileManager.default
        let candidates = [
            "/opt/homebrew/opt/nebula/homebrew.mxcl.nebula.plist",
            "/usr/local/opt/nebula/homebrew.mxcl.nebula.plist"
        ]

        var sources = candidates
            .map { URL(fileURLWithPath: $0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .map { ($0, userDomain) }

        for cellarRoot in ["/opt/homebrew/Cellar/nebula", "/usr/local/Cellar/nebula"] {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: cellarRoot) else {
                continue
            }

            for entry in entries.sorted() {
                let plistURL = URL(fileURLWithPath: cellarRoot)
                    .appendingPathComponent(entry, isDirectory: true)
                    .appendingPathComponent("homebrew.mxcl.nebula.plist")

                if fileManager.fileExists(atPath: plistURL.path) {
                    sources.append((plistURL, userDomain))
                }
            }
        }

        return sources
    }

    private func loadService(from plistURL: URL, domain: LaunchctlDomain) -> NebulaService? {
        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any]
        else {
            return nil
        }

        let label = (dictionary["Label"] as? String) ?? plistURL.deletingPathExtension().lastPathComponent
        let program = dictionary["Program"] as? String
        let programArguments = dictionary["ProgramArguments"] as? [String] ?? []

        guard isNebulaService(
            label: label,
            program: program,
            programArguments: programArguments,
            plistName: plistURL.lastPathComponent
        ) else {
            return nil
        }

        let configPath = extractConfigPath(from: programArguments)
        let title = makeTitle(label: label, configPath: configPath)

        return NebulaService(
            title: title,
            label: label,
            plistPath: plistURL.path,
            configPath: configPath,
            domain: domain
        )
    }

    private func isNebulaService(
        label: String,
        program: String?,
        programArguments: [String],
        plistName: String
    ) -> Bool {
        let candidates = [label, program, plistName]
            .compactMap { $0?.lowercased() }
            + programArguments.map { $0.lowercased() }

        return candidates.contains { candidate in
            candidate.contains("nebula") || URL(fileURLWithPath: candidate).lastPathComponent == "nebula"
        }
    }

    private func extractConfigPath(from programArguments: [String]) -> String? {
        for (index, argument) in programArguments.enumerated() {
            if argument == "-config" || argument == "--config" {
                let nextIndex = programArguments.index(after: index)
                if nextIndex < programArguments.endIndex {
                    return programArguments[nextIndex]
                }
            }

            if argument.hasPrefix("-config=") {
                return String(argument.dropFirst("-config=".count))
            }

            if argument.hasPrefix("--config=") {
                return String(argument.dropFirst("--config=".count))
            }
        }

        return nil
    }

    private func makeTitle(label: String, configPath: String?) -> String {
        if label == "homebrew.mxcl.nebula" {
            return "Nebula (Homebrew)"
        }

        let suffix = label.split(separator: ".").last.map(String.init) ?? label
        let normalizedSuffix = suffix.lowercased()

        if normalizedSuffix == "nebula" {
            return "Nebula"
        }

        if normalizedSuffix == "vpn" {
            return "Nebula"
        }

        if normalizedSuffix.hasPrefix("vpn") {
            let remainder = String(suffix.dropFirst(3))
            if !remainder.isEmpty {
                return "Nebula \(remainder)"
            }
        }

        if let configPath {
            let fileName = URL(fileURLWithPath: configPath).deletingPathExtension().lastPathComponent
            if !fileName.isEmpty && !fileName.lowercased().hasPrefix("config") {
                return fileName
            }
        }

        return "Nebula \(suffix)"
    }

    private func queryState(for service: NebulaService) -> ServiceState {
        let result = runPlain("/bin/launchctl", ["print", "\(service.domain.target)/\(service.label)"])
        let text = result.output + "\n" + result.error

        if result.status == 0 && text.contains("state = running") {
            return .running
        }

        if text.contains("Could not find service") || text.contains("not found") {
            return .stopped
        }

        let list = runPlain("/bin/launchctl", ["list"])
        if list.output.contains(service.label) {
            return .running
        }

        return .stopped
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

struct MenuContentView: View {
    @ObservedObject var model: NebulaModel
    private let metadata = AppMetadata.current

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Privileged helper")
                        .font(.headline)

                    Spacer()

                    Text(model.helperStatusText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(model.helperState == .enabled ? .green : .orange)
                }

                Text(model.helperHintText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360, alignment: .leading)

                if model.helperState != .enabled {
                    HStack {
                        Button("Install Helper") {
                            model.installHelper()
                        }

                        if model.helperState == .requiresApproval {
                            Button("Open Login Items") {
                                model.openHelperSettings()
                            }
                        }

                        Button("Recheck") {
                            model.refreshHelperState()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            if model.services.isEmpty {
                Text("No Nebula launchd services found.")
                    .font(.headline)

                Text("Scan paths: /Library/LaunchDaemons, /Library/LaunchAgents, ~/Library/LaunchAgents")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360, alignment: .leading)
            }

            ForEach(model.services) { service in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.title)
                                .font(.headline)

                            Text(service.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(model.stateText(for: service))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(model.isRunning(service) ? .green : .secondary)
                    }

                    if let configPath = service.configPath {
                        Text(configPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack {
                        Button(model.isRunning(service) ? "Stop" : "Start") {
                            model.toggle(service)
                        }

                        Button("Restart") {
                            model.restart(service)
                        }

                        Button("Config") {
                            model.openConfig(service)
                        }
                        .disabled(service.configPath == nil)

                        Button("plist") {
                            model.openPlist(service)
                        }
                    }
                    .buttonStyle(.bordered)

                    Divider()
                }
            }

            HStack {
                Button("Refresh") {
                    model.refreshAll()
                }

                Spacer()

                Text("\(model.services.count) service\(model.services.count == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if model.isBusy {
                Text("Applying…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !model.lastError.isEmpty {
                Divider()
                Text(model.lastError)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .frame(maxWidth: 360, alignment: .leading)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text(metadata.versionLine)
                    .font(.footnote.weight(.semibold))

                Text(metadata.bundleIdentifier)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(minWidth: 380)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
    }
}

@main
struct NebulaTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = NebulaModel()

    var body: some Scene {
        MenuBarExtra("Nebula", systemImage: "network") {
            MenuContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
