import SwiftUI
import AppKit
import Combine
import Foundation

@MainActor
final class NebulaModel: ObservableObject {
    @Published var services: [NebulaService] = []
    @Published var serviceStates: [String: ServiceState] = [:]
    @Published var serviceActualIPs: [String: String] = [:]
    @Published var lastError: String = ""
    @Published var isBusy = false
    @Published var isDebugEnabled = NebulaPrivilegedHelperConstants.isDebugEnabled()
    @Published var helperState: PrivilegedHelperState = .notRegistered
    @Published private var configOverrides: [String: String] = [:] {
        didSet {
            UserDefaults.standard.set(configOverrides, forKey: Self.configOverridesDefaultsKey)
        }
    }

    private let fileManager = FileManager.default
    private let helperController = PrivilegedHelperController()
    private let launchDirectories: [(path: String, domain: LaunchctlDomain)]
    private let extraPlistSources: [(url: URL, domain: LaunchctlDomain)]
    private var timer: Timer?
    private var busyOperationID: UUID?
    private var busyOperationTimeoutWorkItem: DispatchWorkItem?
    private var manualEntries: [ManualNebulaEntry] = [] {
        didSet {
            persistManualEntries()
        }
    }

    private static let configOverridesDefaultsKey = "NebulaStatus.configOverrides"
    private static let manualEntriesDefaultsKey = "NebulaStatus.manualEntries"
    private static let operationTimeout: TimeInterval = 10

    init() {
        let userDomain = LaunchctlDomain.gui(getuid())
        self.launchDirectories = [
            ("/Library/LaunchDaemons", .system),
            ("/Library/LaunchAgents", userDomain),
            ("\(NSHomeDirectory())/Library/LaunchAgents", userDomain)
        ]
        self.extraPlistSources = NebulaModel.makeExtraPlistSources(userDomain: userDomain)
        self.configOverrides = UserDefaults.standard.dictionary(forKey: Self.configOverridesDefaultsKey) as? [String: String] ?? [:]
        self.manualEntries = NebulaModel.loadManualEntries()

        if !isDebugEnabled {
            cleanupLogArtifactsIfNeeded()
        }

        NebulaTraceLogger.shared.log(
            "init",
            "Model init userDomain = \(userDomain.target), manualEntries = \(manualEntries.count), overrides = \(configOverrides.count), logFile = \(NebulaPrivilegedHelperConstants.logFilePath)"
        )
        refreshAll()
        startPolling()
    }

    deinit {
        timer?.invalidate()
        busyOperationTimeoutWorkItem?.cancel()
    }

    var helperStatusText: String {
        helperState.title
    }

    var logFilePath: String {
        NebulaPrivilegedHelperConstants.logFilePath
    }

    var helperHintText: String {
        switch helperState {
        case .enabled:
            return "Root commands run through a bundled XPC launch daemon."
        case .unreachable:
            return "The helper is installed but not responding over XPC. Use Repair Helper to reinstall it."
        case .notRegistered:
            return "Install the helper once to run system launchctl commands and manual Nebula starts."
        case .requiresApproval:
            return "Approve the helper in System Settings > Login Items."
        case .notFound:
            return "The helper files are missing from the app bundle. Rebuild the app."
        }
    }

    var shouldShowHelperSection: Bool {
        isDebugEnabled || helperState.needsAttention
    }

    func startPolling() {
        NebulaTraceLogger.shared.log("startPolling", "Starting 5 second polling timer")
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
        if !isDebugEnabled {
            cleanupLogArtifactsIfNeeded()
        }

        NebulaTraceLogger.shared.log("refreshAll", "Refreshing all services")
        refreshHelperState()
        services = discoverServices()

        let validServiceIDs = Set(services.map(\.id))
        serviceStates = serviceStates.filter { validServiceIDs.contains($0.key) }
        serviceActualIPs = serviceActualIPs.filter { validServiceIDs.contains($0.key) }

        refreshStates()
    }

    func refreshStates() {
        NebulaTraceLogger.shared.log("refreshStates", "Refreshing states for \(services.count) services")
        for service in services {
            let state = queryState(for: service)
            serviceStates[service.id] = state

            if state == .running, let actualIP = queryActualIPAddress(for: service) {
                serviceActualIPs[service.id] = actualIP
            } else {
                serviceActualIPs.removeValue(forKey: service.id)
            }
        }
    }

    func refreshHelperState() {
        let state = helperController.currentState()
        helperState = state
        NebulaTraceLogger.shared.log("refreshHelperState", "ServiceManagement state = \(state.title)")

        guard state == .enabled else {
            return
        }

        helperController.probeReachability { [weak self] reachable in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.helperState = reachable ? .enabled : .unreachable
                NebulaTraceLogger.shared.log("refreshHelperState", "XPC reachability = \(reachable ? "reachable" : "unreachable")")
            }
        }
    }

    func installHelper() {
        lastError = ""
        NebulaTraceLogger.shared.log("installHelper", "Register helper requested")

        switch helperController.registerIfNeeded() {
        case let .success(state):
            helperState = state
            NebulaTraceLogger.shared.log("installHelper", "Register helper result = \(state.title)")
            if state == .requiresApproval {
                lastError = "Privileged helper installed. Open System Settings > Login Items and approve it."
            }
            refreshHelperState()
        case let .failure(error):
            helperState = helperController.currentState()
            lastError = error.message
            NebulaTraceLogger.shared.log("installHelper", "Register helper failed = \(error.message)")
        }
    }

    func repairHelper() {
        lastError = ""
        NebulaTraceLogger.shared.log("repairHelper", "Repair helper requested")

        switch helperController.repairRegistration() {
        case let .success(state):
            helperState = state
            NebulaTraceLogger.shared.log("repairHelper", "Repair helper result = \(state.title)")
            if state == .requiresApproval {
                lastError = "Privileged helper repaired. Open System Settings > Login Items and approve it."
            }
            refreshHelperState()
        case let .failure(error):
            helperState = helperController.currentState()
            lastError = error.message
            NebulaTraceLogger.shared.log("repairHelper", "Repair helper failed = \(error.message)")
        }
    }

    func openHelperSettings() {
        helperController.openSystemSettings()
    }

    func setDebugEnabled(_ enabled: Bool) {
        lastError = ""

        do {
            try NebulaPrivilegedHelperConstants.setDebugEnabled(enabled)
            isDebugEnabled = enabled

            if enabled {
                _ = try ensureLogFileExists()
                NebulaTraceLogger.shared.log("debug", "Debug logging enabled")
            } else {
                cleanupLogArtifactsIfNeeded()
            }
        } catch {
            lastError = "Failed to change debug mode: \(error.localizedDescription)"
        }
    }

    func stateText(for service: NebulaService) -> String {
        NebulaTraceLogger.shared.log("stateText", "Service id = \(service.id), state = \(serviceStates[service.id, default: .unknown].rawValue)")
        return serviceStates[service.id, default: .unknown].rawValue
    }

    func isRunning(_ service: NebulaService) -> Bool {
        serviceStates[service.id, default: .unknown] == .running
    }

    func actualIPAddress(for service: NebulaService) -> String? {
        serviceActualIPs[service.id]
    }

    func toggle(_ service: NebulaService) {
        if isRunning(service) {
            stop(service)
        } else {
            start(service)
        }
    }

    func start(_ service: NebulaService) {
        NebulaTraceLogger.shared.log("start", "Requested start for service = \(service.id), kind = \(describe(service.kind))")
        switch service.kind {
        case let .launchd(label, plistPath, domain):
            if label == "homebrew.mxcl.nebula", domain.requiresPrivileges == false {
                startHomebrewViaHelper(service, label: label, domain: domain, fallbackPlistPath: plistPath)
                return
            }

            performLaunchctl(
                ["bootstrap", domain.target, plistPath],
                requiresPrivileges: domain.requiresPrivileges
            )
        case .manual:
            guard let configPath = configPath(for: service) else {
                lastError = "Config path is missing for \(service.title)."
                return
            }

            runViaHelper(.startNebula(normalizeConfigPath(configPath)))
        }
    }

    func stop(_ service: NebulaService) {
        NebulaTraceLogger.shared.log("stop", "Requested stop for service = \(service.id), kind = \(describe(service.kind))")
        switch service.kind {
        case let .launchd(label, _, domain):
            if label == "homebrew.mxcl.nebula", domain.requiresPrivileges == false {
                stopHomebrewViaHelper(service, label: label, domain: domain)
                return
            }

            performLaunchctl(
                ["bootout", "\(domain.target)/\(label)"],
                requiresPrivileges: domain.requiresPrivileges
            )
        case .manual:
            guard let configPath = configPath(for: service) else {
                lastError = "Config path is missing for \(service.title)."
                return
            }

            runViaHelper(.stopNebula(normalizeConfigPath(configPath)))
        }
    }

    func restart(_ service: NebulaService) {
        NebulaTraceLogger.shared.log("restart", "Requested restart for service = \(service.id), kind = \(describe(service.kind))")
        switch service.kind {
        case let .launchd(label, _, domain):
            if label == "homebrew.mxcl.nebula", domain.requiresPrivileges == false {
                restartHomebrewViaHelper(service, label: label, domain: domain, fallbackPlistPath: effectivePlistPath(for: service))
                return
            }

            performLaunchctl(
                ["kickstart", "-k", "\(domain.target)/\(label)"],
                requiresPrivileges: domain.requiresPrivileges
            )
        case .manual:
            guard let configPath = configPath(for: service) else {
                lastError = "Config path is missing for \(service.title)."
                return
            }

            let normalizedPath = normalizeConfigPath(configPath)
            if !isRunning(service) {
                runViaHelper(.startNebula(normalizedPath))
                return
            }

            runViaHelper(.stopNebula(normalizedPath), refreshAfterSuccess: false) { [weak self] success in
                guard let self, success else {
                    return
                }

                self.runViaHelper(.startNebula(normalizedPath))
            }
        }
    }

    func openConfig(_ service: NebulaService) {
        guard let configPath = configPath(for: service) else {
            lastError = "Config path not found for \(service.title)."
            NebulaTraceLogger.shared.log("openConfig", "No config path for service = \(service.id)")
            return
        }

        NebulaTraceLogger.shared.log("openConfig", "Opening config path = \(configPath) for service = \(service.id)")
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath)])
    }

    func configPath(for service: NebulaService) -> String? {
        let resolved: String?
        switch service.kind {
        case .manual:
            resolved = service.detectedConfigPath
        case .launchd:
            if let override = configOverrides[service.id], !override.isEmpty {
                resolved = override
            } else {
                resolved = service.detectedConfigPath
            }
        }

        NebulaTraceLogger.shared.log("configPath", "Service = \(service.id), resolvedConfigPath = \(resolved ?? "<nil>")")
        return resolved
    }

    func hasManualConfigOverride(for service: NebulaService) -> Bool {
        guard !service.isManual else {
            return false
        }

        return configOverrides[service.id] != nil
    }

    func addManualConfig() {
        lastError = ""
        NebulaTraceLogger.shared.log("addManualConfig", "Opening picker for new manual config")

        presentConfigPanel(
            title: "Add Nebula config",
            message: "Choose a config file or directory to manage as a direct Nebula process.",
            initialPath: nil
        ) { [weak self] selectedPath in
            guard let self, let selectedPath else {
                return
            }

            if self.manualEntries.contains(where: { $0.configPath == selectedPath }) {
                self.lastError = "That manual config is already in the list."
                NebulaTraceLogger.shared.log("addManualConfig", "Rejected duplicate manual config = \(selectedPath)")
                return
            }

            self.manualEntries.append(.init(id: UUID().uuidString, configPath: selectedPath))
            NebulaTraceLogger.shared.log("addManualConfig", "Added manual config = \(selectedPath)")
            self.refreshAll()
        }
    }

    func configureConfigPath(for service: NebulaService) {
        lastError = ""
        NebulaTraceLogger.shared.log("configureConfigPath", "Requested for service = \(service.id)")

        switch service.kind {
        case .manual:
            configureManualEntry(for: service)
        case .launchd:
            configureLaunchdConfigPath(for: service)
        }
    }

    func openPlist(_ service: NebulaService) {
        guard let plistPath = service.plistPath else {
            NebulaTraceLogger.shared.log("openPlist", "No plist for service = \(service.id)")
            return
        }

        NebulaTraceLogger.shared.log("openPlist", "Opening plist path = \(plistPath) for service = \(service.id)")
        NSWorkspace.shared.selectFile(plistPath, inFileViewerRootedAtPath: "/")
    }

    func openLogFile() {
        try? ensureLogFileExists()
        NebulaTraceLogger.shared.log("openLogFile", "Opening log file = \(logFilePath)")
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: logFilePath)])
    }

    func clearLogFile() {
        lastError = ""

        do {
            let url = try ensureLogFileExists()
            try Data().write(to: url, options: .atomic)
        } catch {
            lastError = "Failed to clear log: \(error.localizedDescription)"
        }
    }

    private func configureLaunchdConfigPath(for service: NebulaService) {
        if hasManualConfigOverride(for: service) {
            NebulaTraceLogger.shared.log("configureLaunchdConfigPath", "Service = \(service.id) already has override")
            presentChoiceAlert(
                title: "Config override",
                message: "This service already has a manually selected config path.",
                buttons: ["Choose New", "Reset", "Cancel"]
            ) { [weak self] response in
                guard let self else {
                    return
                }

                switch response {
                case .alertFirstButtonReturn:
                    self.selectLaunchdConfigPath(for: service)
                case .alertSecondButtonReturn:
                    self.configOverrides.removeValue(forKey: service.id)
                    if self.isHomebrewService(service) {
                        _ = self.syncHomebrewLaunchAgentConfig(for: service)
                    }
                    NebulaTraceLogger.shared.log("configureLaunchdConfigPath", "Reset override for service = \(service.id)")
                default:
                    NebulaTraceLogger.shared.log("configureLaunchdConfigPath", "Cancelled for service = \(service.id)")
                }
            }
            return
        }

        selectLaunchdConfigPath(for: service)
    }

    private func selectLaunchdConfigPath(for service: NebulaService) {
        presentConfigPanel(
            title: "Select Nebula config",
            message: "Choose a config file or a config directory for \(service.title).",
            initialPath: configPath(for: service)
        ) { [weak self] selectedPath in
            guard let self, let selectedPath else {
                NebulaTraceLogger.shared.log("configureLaunchdConfigPath", "Selection cancelled for service = \(service.id)")
                return
            }

            self.configOverrides[service.id] = selectedPath
            if self.isHomebrewService(service) {
                _ = self.syncHomebrewLaunchAgentConfig(for: service)
            }
            NebulaTraceLogger.shared.log("configureLaunchdConfigPath", "Set override for service = \(service.id) to \(selectedPath)")
        }
    }

    private func configureManualEntry(for service: NebulaService) {
        guard let index = manualEntries.firstIndex(where: { $0.id == service.id }) else {
            lastError = "Manual config entry was not found."
            NebulaTraceLogger.shared.log("configureManualEntry", "Entry not found for service = \(service.id)")
            return
        }

        presentChoiceAlert(
            title: "Manual config",
            message: "Change or remove this manual Nebula config entry.",
            buttons: ["Choose New", "Remove", "Cancel"]
        ) { [weak self] response in
            guard let self else {
                return
            }

            switch response {
            case .alertFirstButtonReturn:
                self.presentConfigPanel(
                    title: "Select Nebula config",
                    message: "Choose a new config file or directory for \(service.title).",
                    initialPath: self.manualEntries[index].configPath
                ) { [weak self] selectedPath in
                    guard let self, let selectedPath else {
                        NebulaTraceLogger.shared.log("configureManualEntry", "Selection cancelled for service = \(service.id)")
                        return
                    }

                    if self.manualEntries.contains(where: { $0.configPath == selectedPath && $0.id != service.id }) {
                        self.lastError = "That manual config is already in the list."
                        NebulaTraceLogger.shared.log("configureManualEntry", "Rejected duplicate path = \(selectedPath)")
                        return
                    }

                    self.manualEntries[index].configPath = selectedPath
                    NebulaTraceLogger.shared.log("configureManualEntry", "Updated manual entry = \(service.id) to \(selectedPath)")
                    self.refreshAll()
                }
            case .alertSecondButtonReturn:
                NebulaTraceLogger.shared.log("configureManualEntry", "Removing manual entry = \(self.manualEntries[index].configPath)")
                self.manualEntries.remove(at: index)
                self.refreshAll()
            default:
                NebulaTraceLogger.shared.log("configureManualEntry", "Cancelled for service = \(service.id)")
            }
        }
    }

    private func presentConfigPanel(
        title: String,
        message: String,
        initialPath: String?,
        completion: @escaping (String?) -> Void
    ) {
        NebulaTraceLogger.shared.log(
            "presentConfigPanel",
            "title = \(title), message = \(message), initialPath = \(initialPath ?? "<nil>")"
        )
        DispatchQueue.main.async {
            let previousPolicy = NSApp.activationPolicy()
            if previousPolicy == .prohibited {
                NSApp.setActivationPolicy(.accessory)
            }

            NSApp.activate(ignoringOtherApps: true)

            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            panel.title = title
            panel.message = message
            panel.prompt = "Use Config"
            panel.level = .modalPanel
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

            if let initialPath {
                let existingURL = URL(fileURLWithPath: initialPath)
                panel.directoryURL = existingURL.hasDirectoryPath ? existingURL : existingURL.deletingLastPathComponent()
            }

            panel.orderFrontRegardless()
            let response = panel.runModal()
            defer {
                if previousPolicy == .prohibited {
                    NSApp.setActivationPolicy(.prohibited)
                }
            }

            guard response == .OK, let url = panel.url else {
                NebulaTraceLogger.shared.log("presentConfigPanel", "Panel dismissed without selection")
                completion(nil)
                return
            }

            let selectedPath = self.normalizeConfigPath(url.path)
            NebulaTraceLogger.shared.log("presentConfigPanel", "Selected path = \(selectedPath)")
            completion(selectedPath)
        }
    }

    private func presentChoiceAlert(
        title: String,
        message: String,
        buttons: [String],
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        DispatchQueue.main.async {
            let previousPolicy = NSApp.activationPolicy()
            if previousPolicy == .prohibited {
                NSApp.setActivationPolicy(.accessory)
            }

            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            buttons.forEach { alert.addButton(withTitle: $0) }
            alert.window.level = .modalPanel
            alert.window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            alert.window.orderFrontRegardless()

            let response = alert.runModal()
            if previousPolicy == .prohibited {
                NSApp.setActivationPolicy(.prohibited)
            }

            completion(response)
        }
    }

    private func performLaunchctl(_ arguments: [String], requiresPrivileges: Bool) {
        NebulaTraceLogger.shared.log("performLaunchctl", "arguments = \(arguments), requiresPrivileges = \(requiresPrivileges)")
        if requiresPrivileges {
            runViaHelper(.launchctl(arguments))
        } else {
            runDirect(arguments)
        }
    }

    private func runViaHelper(
        _ operation: HelperOperation,
        refreshAfterSuccess: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        lastError = ""
        NebulaTraceLogger.shared.log("runViaHelper", "operation = \(describe(operation)), refreshAfterSuccess = \(refreshAfterSuccess)")

        switch helperController.registerIfNeeded() {
        case let .failure(error):
            helperState = helperController.currentState()
            NebulaTraceLogger.shared.log("runViaHelper", "Helper register failed = \(error.message)")
            runViaAdminDialog(
                operation,
                reason: "helper register failed: \(error.message)",
                refreshAfterSuccess: refreshAfterSuccess,
                completion: completion
            )
            return
        case let .success(state):
            let knownState = helperState
            helperState = (knownState == .unreachable && state == .enabled) ? .unreachable : state

            guard state == .enabled else {
                NebulaTraceLogger.shared.log("runViaHelper", "Helper not enabled, state = \(state.title)")
                runViaAdminDialog(
                    operation,
                    reason: "helper state = \(state.title)",
                    refreshAfterSuccess: refreshAfterSuccess,
                    completion: completion
                )
                return
            }

            if knownState == .unreachable {
                NebulaTraceLogger.shared.log("runViaHelper", "Helper marked unreachable")
                runViaAdminDialog(
                    operation,
                    reason: "helper marked unreachable",
                    refreshAfterSuccess: refreshAfterSuccess,
                    completion: completion
                )
                return
            }

            NebulaTraceLogger.shared.log("runViaHelper", "Helper state enabled")
        }

        let operationID = beginBusyOperation("Timed out after \(Int(Self.operationTimeout)) seconds while applying \(describe(operation)).")

        let finish: (Result<(Int32, String, String), PrivilegedHelperFailure>) -> Void = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                guard self.completeBusyOperation(operationID) else {
                    return
                }
                self.refreshHelperState()

                switch result {
                case let .success((status, output, error)):
                    NebulaTraceLogger.shared.log(
                        "runViaHelper",
                        "Result status = \(status), stdout = \(self.sanitize(output)), stderr = \(self.sanitize(error))"
                    )
                    if status != 0 {
                        self.lastError = (error.isEmpty ? output : error)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        completion?(false)
                    } else {
                        self.lastError = ""
                        if refreshAfterSuccess {
                            self.refreshSoon()
                        }
                        completion?(true)
                    }
                case let .failure(error):
                    self.lastError = error.message
                    NebulaTraceLogger.shared.log("runViaHelper", "XPC failure = \(error.message)")
                    completion?(false)
                }
            }
        }

        switch operation {
        case let .launchctl(arguments):
            helperController.runLaunchctl(arguments: arguments, completion: finish)
        case let .startNebula(configPath):
            helperController.startNebula(configPath: configPath, completion: finish)
        case let .stopNebula(configPath):
            helperController.stopNebula(configPath: configPath, completion: finish)
        }
    }

    private func runViaAdminDialog(
        _ operation: HelperOperation,
        reason: String,
        refreshAfterSuccess: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let shellCommand = privilegedShellCommand(for: operation) else {
            lastError = "Privileged helper is unavailable, and no fallback command could be prepared."
            NebulaTraceLogger.shared.log("runViaAdminDialog", "No fallback command for operation = \(describe(operation)), reason = \(reason)")
            completion?(false)
            return
        }

        lastError = ""
        NebulaTraceLogger.shared.log("runViaAdminDialog", "Falling back to admin dialog for operation = \(describe(operation)), reason = \(reason), command = \(sanitize(shellCommand))")
        let operationID = beginBusyOperation("Timed out after \(Int(Self.operationTimeout)) seconds while applying \(describe(operation)).")
        let script = "do shell script \"\(escapeAppleScriptString(shellCommand))\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runPlain("/usr/bin/osascript", ["-e", script])

            DispatchQueue.main.async {
                guard self.completeBusyOperation(operationID) else {
                    return
                }

                NebulaTraceLogger.shared.log(
                    "runViaAdminDialog",
                    "Completed status = \(result.status), stdout = \(self.sanitize(result.output)), stderr = \(self.sanitize(result.error))"
                )

                if result.status != 0 {
                    self.lastError = (result.error.isEmpty ? result.output : result.error)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    completion?(false)
                    return
                }

                self.lastError = ""
                if refreshAfterSuccess {
                    self.refreshSoon()
                }
                completion?(true)
            }
        }
    }

    private func runDirect(_ arguments: [String]) {
        lastError = ""
        NebulaTraceLogger.shared.log("runDirect", "arguments = \(arguments)")
        let operationID = beginBusyOperation("Timed out after \(Int(Self.operationTimeout)) seconds while running launchctl \(arguments.joined(separator: " ")).")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runPlain("/bin/launchctl", arguments)

            DispatchQueue.main.async {
                guard self.completeBusyOperation(operationID) else {
                    return
                }

                if result.status != 0 {
                    self.lastError = (result.error.isEmpty ? result.output : result.error)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    NebulaTraceLogger.shared.log(
                        "runDirect",
                        "Failed status = \(result.status), stdout = \(self.sanitize(result.output)), stderr = \(self.sanitize(result.error))"
                    )
                    return
                }

                NebulaTraceLogger.shared.log("runDirect", "Succeeded")
                self.refreshSoon()
            }
        }
    }

    private func startHomebrewViaHelper(
        _ service: NebulaService,
        label: String,
        domain: LaunchctlDomain,
        fallbackPlistPath: String
    ) {
        lastError = ""

        guard let configPath = configPath(for: service) else {
            lastError = "Config path is missing for \(service.title)."
            NebulaTraceLogger.shared.log("startHomebrewViaHelper", "Missing config path for service = \(service.id)")
            return
        }

        _ = syncHomebrewLaunchAgentConfig(for: service, fallbackPlistPath: fallbackPlistPath)

        let target = "\(domain.target)/\(label)"
        let normalizedPath = normalizeConfigPath(configPath)
        NebulaTraceLogger.shared.log(
            "startHomebrewViaHelper",
            "Booting out launch agent and starting direct root process, label = \(label), domain = \(domain.target), config = \(normalizedPath)"
        )

        runDirectLaunchctl(["bootout", target], ignoreFailure: true, refreshAfterSuccess: false) { [weak self] in
            guard let self else {
                return
            }

            self.runViaHelper(.startNebula(normalizedPath))
        }
    }

    private func stopHomebrewViaHelper(
        _ service: NebulaService,
        label: String,
        domain: LaunchctlDomain
    ) {
        guard let configPath = configPath(for: service) else {
            lastError = "Config path is missing for \(service.title)."
            NebulaTraceLogger.shared.log("stopHomebrewViaHelper", "Missing config path for service = \(service.id)")
            return
        }

        let target = "\(domain.target)/\(label)"
        let normalizedPath = normalizeConfigPath(configPath)
        NebulaTraceLogger.shared.log(
            "stopHomebrewViaHelper",
            "Booting out launch agent and stopping direct root process, label = \(label), domain = \(domain.target), config = \(normalizedPath)"
        )

        runDirectLaunchctl(["bootout", target], ignoreFailure: true, refreshAfterSuccess: false) { [weak self] in
            guard let self else {
                return
            }

            self.runViaHelper(.stopNebula(normalizedPath))
        }
    }

    private func restartHomebrewViaHelper(
        _ service: NebulaService,
        label: String,
        domain: LaunchctlDomain,
        fallbackPlistPath: String
    ) {
        guard let configPath = configPath(for: service) else {
            lastError = "Config path is missing for \(service.title)."
            NebulaTraceLogger.shared.log("restartHomebrewViaHelper", "Missing config path for service = \(service.id)")
            return
        }

        _ = syncHomebrewLaunchAgentConfig(for: service, fallbackPlistPath: fallbackPlistPath)

        let target = "\(domain.target)/\(label)"
        let normalizedPath = normalizeConfigPath(configPath)
        NebulaTraceLogger.shared.log(
            "restartHomebrewViaHelper",
            "Booting out launch agent and restarting direct root process, label = \(label), domain = \(domain.target), config = \(normalizedPath)"
        )

        runDirectLaunchctl(["bootout", target], ignoreFailure: true, refreshAfterSuccess: false) { [weak self] in
            guard let self else {
                return
            }

            self.runViaHelper(.stopNebula(normalizedPath), refreshAfterSuccess: false) { [weak self] _ in
                guard let self else {
                    return
                }

                self.runViaHelper(.startNebula(normalizedPath))
            }
        }
    }

    private func runDirectLaunchctl(
        _ arguments: [String],
        ignoreFailure: Bool,
        refreshAfterSuccess: Bool,
        completion: @escaping () -> Void
    ) {
        lastError = ""
        NebulaTraceLogger.shared.log(
            "runDirectLaunchctl",
            "arguments = \(arguments), ignoreFailure = \(ignoreFailure), refreshAfterSuccess = \(refreshAfterSuccess)"
        )
        let operationID = beginBusyOperation("Timed out after \(Int(Self.operationTimeout)) seconds while running launchctl \(arguments.joined(separator: " ")).")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runPlain("/bin/launchctl", arguments)

            DispatchQueue.main.async {
                guard self.completeBusyOperation(operationID) else {
                    return
                }
                NebulaTraceLogger.shared.log(
                    "runDirectLaunchctl",
                    "Completed status = \(result.status), stdout = \(self.sanitize(result.output)), stderr = \(self.sanitize(result.error))"
                )

                if result.status != 0 && !ignoreFailure {
                    self.lastError = (result.error.isEmpty ? result.output : result.error)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return
                }

                self.lastError = ""
                if refreshAfterSuccess {
                    self.refreshSoon()
                }
                completion()
            }
        }
    }

    private func syncHomebrewLaunchAgentConfig(
        for service: NebulaService,
        fallbackPlistPath: String? = nil
    ) -> String? {
        guard isHomebrewService(service) else {
            return effectivePlistPath(for: service)
        }

        guard let configPath = configPath(for: service) else {
            lastError = "Config path is missing for \(service.title)."
            NebulaTraceLogger.shared.log("syncHomebrewLaunchAgentConfig", "Missing config path for service = \(service.id)")
            return nil
        }

        let destinationURL = homebrewLaunchAgentDestinationURL()
        let sourceURL = homebrewLaunchAgentSourceURL(fallbackPlistPath: fallbackPlistPath ?? service.plistPath)

        guard
            let sourceURL,
            let plist = loadMutablePlistDictionary(from: sourceURL)
        else {
            lastError = "Homebrew launch agent template was not found."
            NebulaTraceLogger.shared.log(
                "syncHomebrewLaunchAgentConfig",
                "Failed loading source plist for service = \(service.id), fallback = \(fallbackPlistPath ?? service.plistPath ?? "<nil>")"
            )
            return nil
        }

        let normalizedConfigPath = normalizeConfigPath(configPath)
        let executablePath = homebrewNebulaExecutablePath(from: plist)
        plist["Label"] = "homebrew.mxcl.nebula"
        plist["ProgramArguments"] = [executablePath, "-config", normalizedConfigPath]

        do {
            let directoryURL = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try data.write(to: destinationURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destinationURL.path)

            NebulaTraceLogger.shared.log(
                "syncHomebrewLaunchAgentConfig",
                "Wrote plist = \(destinationURL.path), executable = \(executablePath), config = \(normalizedConfigPath)"
            )

            return destinationURL.path
        } catch {
            lastError = "Failed to update Homebrew launch agent: \(error.localizedDescription)"
            NebulaTraceLogger.shared.log(
                "syncHomebrewLaunchAgentConfig",
                "Write failed plist = \(destinationURL.path), error = \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func beginBusyOperation(_ timeoutMessage: String) -> UUID {
        let operationID = UUID()
        busyOperationTimeoutWorkItem?.cancel()
        busyOperationID = operationID
        isBusy = true

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.busyOperationID == operationID else {
                    return
                }

                self.busyOperationID = nil
                self.busyOperationTimeoutWorkItem = nil
                self.isBusy = false
                self.lastError = timeoutMessage
                NebulaTraceLogger.shared.log("operationTimeout", timeoutMessage)
            }
        }

        busyOperationTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.operationTimeout, execute: workItem)
        return operationID
    }

    private func completeBusyOperation(_ operationID: UUID) -> Bool {
        guard busyOperationID == operationID else {
            NebulaTraceLogger.shared.log("operationTimeout", "Ignoring late completion for operation = \(operationID.uuidString)")
            return false
        }

        busyOperationTimeoutWorkItem?.cancel()
        busyOperationTimeoutWorkItem = nil
        busyOperationID = nil
        isBusy = false
        return true
    }

    private func ensureLogFileExists() throws -> URL {
        let directoryURL = URL(fileURLWithPath: NebulaPrivilegedHelperConstants.logDirectoryPath, isDirectory: true)
        let fileURL = URL(fileURLWithPath: NebulaPrivilegedHelperConstants.logFilePath)

        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o777]
            )
        }

        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o666]
            )
        }

        try? fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directoryURL.path)
        try? fileManager.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fileURL.path)
        return fileURL
    }

    private func cleanupLogArtifactsIfNeeded() {
        let logFilePath = NebulaPrivilegedHelperConstants.logFilePath
        if fileManager.fileExists(atPath: logFilePath) {
            try? fileManager.removeItem(atPath: logFilePath)
        }
    }

    private func privilegedShellCommand(for operation: HelperOperation) -> String? {
        switch operation {
        case let .launchctl(arguments):
            return ([shellQuote("/bin/launchctl")] + arguments.map(shellQuote)).joined(separator: " ")
        case let .startNebula(configPath):
            guard let executablePath = resolveNebulaExecutablePath() else {
                return nil
            }

            let pattern = shellQuote(" -config \(configPath)")
            let command = [
                shellQuote(executablePath),
                "-config",
                shellQuote(configPath),
                ">/dev/null 2>&1 &",
                "/bin/sleep 1",
                ";",
                "/usr/bin/pgrep -fal nebula | /usr/bin/grep -F -- \(pattern) >/dev/null"
            ].joined(separator: " ")
            return command
        case let .stopNebula(configPath):
            let pattern = shellQuote(nebulaProcessPattern(for: configPath))
            return [
                "/usr/bin/pkill -TERM -f \(pattern) >/dev/null 2>&1 || true",
                "/bin/sleep 1",
                ";",
                "/usr/bin/pkill -KILL -f \(pattern) >/dev/null 2>&1 || true"
            ].joined(separator: " ")
        }
    }

    private func resolveNebulaExecutablePath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/nebula",
            "/opt/homebrew/opt/nebula/bin/nebula",
            "/usr/local/bin/nebula",
            "/usr/local/opt/nebula/bin/nebula"
        ]

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return nil
    }

    private func nebulaProcessPattern(for configPath: String) -> String {
        let escapedPath = NSRegularExpression.escapedPattern(for: configPath)
        return "(^|/)nebula([[:space:]]|$).*(-config|--config)(=|[[:space:]])\(escapedPath)([[:space:]]|$)"
    }

    func shellQuote(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }

        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
        NebulaTraceLogger.shared.log("discoverServices", "Scanning launchd and manual sources")
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
                    NebulaTraceLogger.shared.log("discoverServices", "Discovered service = \(service.id)")
                    discovered.append(service)
                }
            }
        }

        for source in extraPlistSources {
            guard let service = loadService(from: source.url, domain: source.domain) else {
                continue
            }

            if seenIDs.insert(service.id).inserted {
                NebulaTraceLogger.shared.log("discoverServices", "Discovered extra service = \(service.id)")
                discovered.append(service)
            }
        }

        discovered.append(contentsOf: manualEntries.map(makeManualService(from:)))
        NebulaTraceLogger.shared.log("discoverServices", "Manual entries appended = \(manualEntries.count)")

        return discovered.sorted { lhs, rhs in
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleOrder == .orderedSame {
                return lhs.subtitle.localizedCaseInsensitiveCompare(rhs.subtitle) == .orderedAscending
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

    private static func loadManualEntries() -> [ManualNebulaEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: manualEntriesDefaultsKey),
            let entries = try? JSONDecoder().decode([ManualNebulaEntry].self, from: data)
        else {
            return []
        }

        return entries
    }

    private func persistManualEntries() {
        guard let data = try? JSONEncoder().encode(manualEntries) else {
            NebulaTraceLogger.shared.log("persistManualEntries", "Failed to encode manual entries")
            return
        }

        UserDefaults.standard.set(data, forKey: Self.manualEntriesDefaultsKey)
        NebulaTraceLogger.shared.log("persistManualEntries", "Saved manual entries count = \(manualEntries.count)")
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

        let normalizedConfigPath = extractConfigPath(from: programArguments).map(normalizeConfigPath)
        let title = makeLaunchdTitle(label: label, configPath: normalizedConfigPath)
        NebulaTraceLogger.shared.log(
            "loadService",
            "Loaded launchd service label = \(label), plist = \(plistURL.path), configPath = \(normalizedConfigPath ?? "<nil>"), domain = \(domain.target)"
        )

        return NebulaService(
            id: "launchd:\(domain.target):\(label)",
            title: title,
            subtitle: label,
            detectedConfigPath: normalizedConfigPath,
            kind: .launchd(label: label, plistPath: plistURL.path, domain: domain)
        )
    }

    private func makeManualService(from entry: ManualNebulaEntry) -> NebulaService {
        NebulaTraceLogger.shared.log("makeManualService", "Entry id = \(entry.id), configPath = \(entry.configPath)")
        return NebulaService(
            id: entry.id,
            title: makeManualTitle(configPath: entry.configPath),
            subtitle: "Manual launch",
            detectedConfigPath: entry.configPath,
            kind: .manual
        )
    }

    func isNebulaService(
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

    func extractConfigPath(from programArguments: [String]) -> String? {
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

    private func isHomebrewService(_ service: NebulaService) -> Bool {
        service.launchdLabel == "homebrew.mxcl.nebula"
    }

    private func effectivePlistPath(for service: NebulaService) -> String {
        if isHomebrewService(service) {
            let destinationPath = homebrewLaunchAgentDestinationURL().path
            if fileManager.fileExists(atPath: destinationPath) {
                return destinationPath
            }
        }

        return service.plistPath ?? ""
    }

    private func homebrewLaunchAgentDestinationURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("homebrew.mxcl.nebula.plist")
    }

    private func homebrewLaunchAgentSourceURL(fallbackPlistPath: String?) -> URL? {
        let candidates: [String?] = [
            fallbackPlistPath,
            homebrewLaunchAgentDestinationURL().path,
            "/opt/homebrew/opt/nebula/homebrew.mxcl.nebula.plist",
            "/usr/local/opt/nebula/homebrew.mxcl.nebula.plist"
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if fileManager.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    private func loadMutablePlistDictionary(from url: URL) -> NSMutableDictionary? {
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any]
        else {
            return nil
        }

        return NSMutableDictionary(dictionary: dictionary)
    }

    private func homebrewNebulaExecutablePath(from plist: NSDictionary) -> String {
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        if let candidate = arguments.first, fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let fallbackCandidates = [
            "/opt/homebrew/opt/nebula/bin/nebula",
            "/opt/homebrew/bin/nebula",
            "/usr/local/opt/nebula/bin/nebula",
            "/usr/local/bin/nebula"
        ]

        for candidate in fallbackCandidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return arguments.first ?? "/opt/homebrew/opt/nebula/bin/nebula"
    }

    private func makeLaunchdTitle(label: String, configPath: String?) -> String {
        if label == "homebrew.mxcl.nebula" {
            return "Nebula (Homebrew)"
        }

        let suffix = label.split(separator: ".").last.map(String.init) ?? label
        let normalizedSuffix = suffix.lowercased()

        if normalizedSuffix == "nebula" || normalizedSuffix == "vpn" {
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

    private func makeManualTitle(configPath: String) -> String {
        let url = URL(fileURLWithPath: configPath)
        let candidate = url.hasDirectoryPath ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let normalized = candidate.lowercased()

        if !candidate.isEmpty && normalized != "config" {
            return normalized.contains("nebula") ? candidate : "Nebula \(candidate)"
        }

        let parent = url.deletingLastPathComponent().lastPathComponent
        if !parent.isEmpty {
            return "Nebula \(parent)"
        }

        return "Nebula (Manual)"
    }

    private func queryState(for service: NebulaService) -> ServiceState {
        if isHomebrewService(service), let configPath = configPath(for: service) {
            let directState = queryManualState(configPath: configPath)
            if directState == .running {
                NebulaTraceLogger.shared.log(
                    "queryState",
                    "Homebrew service = \(service.id) resolved as running via direct helper-managed process"
                )
                return .running
            }

            NebulaTraceLogger.shared.log(
                "queryState",
                "Homebrew service = \(service.id) resolved as stopped via direct helper-managed process"
            )
            return .stopped
        }

        switch service.kind {
        case let .launchd(label, _, domain):
            return queryLaunchdState(label: label, domain: domain)
        case .manual:
            guard let configPath = configPath(for: service) else {
                return .unknown
            }

            return queryManualState(configPath: configPath)
        }
    }

    private func queryActualIPAddress(for service: NebulaService) -> String? {
        guard let configPath = configPath(for: service) else {
            return nil
        }

        guard let configFilePath = resolveConfigFilePath(from: configPath) else {
            NebulaTraceLogger.shared.log("queryActualIPAddress", "No config file resolved for service = \(service.id), configPath = \(configPath)")
            return nil
        }

        guard let interfaceName = extractTunDevice(fromConfigFile: configFilePath) else {
            NebulaTraceLogger.shared.log("queryActualIPAddress", "No tun.dev found in config = \(configFilePath)")
            return nil
        }

        let result = runPlain("/sbin/ifconfig", [interfaceName])
        guard result.status == 0 else {
            NebulaTraceLogger.shared.log(
                "queryActualIPAddress",
                "ifconfig failed for interface = \(interfaceName), status = \(result.status), stderr = \(sanitize(result.error))"
            )
            return nil
        }

        let lines = result.output.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet ") else {
                continue
            }

            let components = trimmed.split(whereSeparator: \.isWhitespace)
            guard components.count >= 2 else {
                continue
            }

            let address = String(components[1])
            if address != "127.0.0.1" {
                NebulaTraceLogger.shared.log(
                    "queryActualIPAddress",
                    "Resolved service = \(service.id), interface = \(interfaceName), address = \(address)"
                )
                return address
            }
        }

        NebulaTraceLogger.shared.log(
            "queryActualIPAddress",
            "No inet address found for service = \(service.id), interface = \(interfaceName)"
        )
        return nil
    }

    private func queryLaunchdState(label: String, domain: LaunchctlDomain) -> ServiceState {
        let result = runPlain("/bin/launchctl", ["print", "\(domain.target)/\(label)"])
        let text = result.output + "\n" + result.error
        let normalizedText = text.lowercased()

        if result.status == 0 && normalizedText.contains("state = running") {
            NebulaTraceLogger.shared.log("queryLaunchdState", "label = \(label), domain = \(domain.target), reason = state = running")
            return .running
        }

        if result.status == 0, let pid = extractPID(from: text), pid > 0 {
            NebulaTraceLogger.shared.log("queryLaunchdState", "label = \(label), domain = \(domain.target), reason = pid = \(pid)")
            return .running
        }

        if text.contains("Could not find service") || normalizedText.contains("not found") {
            NebulaTraceLogger.shared.log("queryLaunchdState", "label = \(label), domain = \(domain.target), reason = service not found")
            return .stopped
        }

        if result.status == 0 {
            if normalizedText.contains("spawn scheduled") {
                NebulaTraceLogger.shared.log("queryLaunchdState", "label = \(label), domain = \(domain.target), reason = spawn scheduled")
                return .stopped
            }

            if normalizedText.contains("last exit code =") {
                NebulaTraceLogger.shared.log("queryLaunchdState", "label = \(label), domain = \(domain.target), reason = last exit code present")
                return .stopped
            }

            if normalizedText.contains("state = waiting") || normalizedText.contains("state = exited") {
                NebulaTraceLogger.shared.log("queryLaunchdState", "label = \(label), domain = \(domain.target), reason = non-running state")
                return .stopped
            }
        }

        let list = runPlain("/bin/launchctl", ["list"])
        if let state = extractLaunchctlListState(label: label, from: list.output) {
            NebulaTraceLogger.shared.log(
                "queryLaunchdState",
                "label = \(label), domain = \(domain.target), reason = launchctl list parsed as \(state.rawValue)"
            )
            return state
        }

        NebulaTraceLogger.shared.log("queryLaunchdState", "label = \(label), domain = \(domain.target), reason = default stopped")
        return .stopped
    }

    private func queryManualState(configPath: String) -> ServiceState {
        let normalizedPath = normalizeConfigPath(configPath)
        let result = runPlain("/usr/bin/pgrep", ["-fal", "nebula"])
        guard result.status == 0 else {
            NebulaTraceLogger.shared.log(
                "queryManualState",
                "ps failed for configPath = \(normalizedPath), status = \(result.status), stderr = \(sanitize(result.error))"
            )
            return .unknown
        }

        let matchingLines = result.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap { line -> String? in
                let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard parts.count == 2 else {
                    return nil
                }

                return String(parts[1])
            }
            .filter { arguments in
                commandLineStartsWithNebula(arguments)
                    && commandLine(arguments, containsConfigPath: normalizedPath)
            }

        NebulaTraceLogger.shared.log(
            "queryManualState",
            "configPath = \(normalizedPath), matchingLines = \(sanitize(matchingLines.joined(separator: " || "))), state = \(matchingLines.isEmpty ? ServiceState.stopped.rawValue : ServiceState.running.rawValue)"
        )

        return matchingLines.isEmpty ? .stopped : .running
    }

    func extractPID(from text: String) -> Int? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = ") {
                let value = trimmed.replacingOccurrences(of: "pid = ", with: "")
                return Int(value)
            }
        }

        return nil
    }

    func extractLaunchctlListState(label: String, from output: String) -> ServiceState? {
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 3 else {
                continue
            }

            let lineLabel = String(columns[2])
            guard lineLabel == label else {
                continue
            }

            let pidColumn = String(columns[0])
            if let pid = Int(pidColumn), pid > 0 {
                return .running
            }

            return .stopped
        }

        return nil
    }

    func normalizeConfigPath(_ value: String) -> String {
        let expanded = (value as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath

        guard standardized.count > 1 else {
            return standardized
        }

        return standardized.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    func resolveConfigFilePath(from configPath: String) -> String? {
        let normalizedPath = normalizeConfigPath(configPath)
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: normalizedPath, isDirectory: &isDirectory) else {
            return nil
        }

        if !isDirectory.boolValue {
            return normalizedPath
        }

        let preferredNames = ["config.yml", "config.yaml", "nebula.yml", "nebula.yaml"]
        for preferredName in preferredNames {
            let candidate = URL(fileURLWithPath: normalizedPath, isDirectory: true)
                .appendingPathComponent(preferredName)
                .path
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }

        guard let contents = try? fileManager.contentsOfDirectory(atPath: normalizedPath) else {
            return nil
        }

        let yamlCandidates = contents
            .filter { $0.lowercased().hasSuffix(".yml") || $0.lowercased().hasSuffix(".yaml") }
            .sorted()

        guard yamlCandidates.count == 1 else {
            return nil
        }

        return URL(fileURLWithPath: normalizedPath, isDirectory: true)
            .appendingPathComponent(yamlCandidates[0])
            .path
    }

    func extractTunDevice(fromConfigFile configFilePath: String) -> String? {
        guard let contents = try? String(contentsOfFile: configFilePath, encoding: .utf8) else {
            return nil
        }

        var insideTunSection = false
        var tunIndent: Int?

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let uncommented = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
            let trimmed = uncommented.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                continue
            }

            let indent = uncommented.prefix { $0 == " " || $0 == "\t" }.count

            if trimmed == "tun:" {
                insideTunSection = true
                tunIndent = indent
                continue
            }

            if insideTunSection, let tunIndent, indent <= tunIndent {
                insideTunSection = false
            }

            guard insideTunSection else {
                continue
            }

            guard trimmed.hasPrefix("dev:") else {
                continue
            }

            let value = trimmed
                .dropFirst(4)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            return value.isEmpty ? nil : value
        }

        return nil
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

    private nonisolated func runPlain(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String, error: String) {
        NebulaTraceLogger.shared.log("runPlain", "Executing \(executable) \(arguments.joined(separator: " "))")
        let process = Process()
        let fileManager = FileManager.default
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

    private func describe(_ kind: NebulaServiceKind) -> String {
        switch kind {
        case let .launchd(label, plistPath, domain):
            return "launchd(label: \(label), plist: \(plistPath), domain: \(domain.target))"
        case .manual:
            return "manual"
        }
    }

    private func describe(_ operation: HelperOperation) -> String {
        switch operation {
        case let .launchctl(arguments):
            return "launchctl \(arguments)"
        case let .startNebula(configPath):
            return "startNebula \(configPath)"
        case let .stopNebula(configPath):
            return "stopNebula \(configPath)"
        }
    }

    func commandLineStartsWithNebula(_ arguments: String) -> Bool {
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

    private nonisolated func sanitize(_ text: String) -> String {
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
