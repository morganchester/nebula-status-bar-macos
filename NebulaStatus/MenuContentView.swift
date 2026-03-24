import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: NebulaModel
    private let metadata = AppMetadata.current

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Add Config") {
                    model.addManualConfig()
                }

                if model.isDebugEnabled {
                    Button("Refresh") {
                        model.refreshAll()
                    }

                    Button("Open Log") {
                        model.openLogFile()
                    }

                    Button("Clear Log") {
                        model.clearLogFile()
                    }
                }

                Spacer()

                Toggle("Debug On", isOn: Binding(
                    get: { model.isDebugEnabled },
                    set: { model.setDebugEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                Text("\(model.services.count) item\(model.services.count == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if model.shouldShowHelperSection {
                Divider()

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

                            if model.helperState == .unreachable {
                                Button("Repair Helper") {
                                    model.repairHelper()
                                }
                            }

                            if model.helperState == .requiresApproval {
                                Button("Open Login Items") {
                                    model.openHelperSettings()
                                }
                            }

                            if model.isDebugEnabled {
                                Button("Recheck") {
                                    model.refreshHelperState()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if model.services.isEmpty {
                Text("No Nebula services or manual configs found.")
                    .font(.headline)

                Text("Scan paths: /Library/LaunchDaemons, /Library/LaunchAgents, ~/Library/LaunchAgents. Use Add Config for direct nebula -config launches.")
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

                            Text(service.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(model.stateText(for: service))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(model.isRunning(service) ? .green : .secondary)
                    }

                    if let configPath = model.configPath(for: service) {
                        Text(configPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(model.hasManualConfigOverride(for: service) ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let actualIP = model.actualIPAddress(for: service) {
                        Text("IP \(actualIP)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.green)
                    }

                    HStack {
                        Button(model.isRunning(service) ? "Stop" : "Start") {
                            model.toggle(service)
                        }

                        if model.isDebugEnabled {
                            Button("Restart") {
                                model.restart(service)
                            }

                            Button("Config") {
                                model.openConfig(service)
                            }
                            .disabled(model.configPath(for: service) == nil)
                        }

                        if model.isDebugEnabled, service.plistPath != nil {
                            Button("plist") {
                                model.openPlist(service)
                            }
                        }

                        Button {
                            model.configureConfigPath(for: service)
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .help(service.isManual ? "Change or remove manual config" : (model.hasManualConfigOverride(for: service) ? "Change or reset config override" : "Select config path manually"))
                    }
                    .buttonStyle(.bordered)

                    Divider()
                }
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

            if model.isDebugEnabled {
                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text(metadata.versionLine)
                        .font(.footnote.weight(.semibold))

                    Text(metadata.bundleIdentifier)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(model.logFilePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(minWidth: 380)
    }
}
