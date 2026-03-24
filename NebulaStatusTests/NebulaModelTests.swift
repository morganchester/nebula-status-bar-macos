import Testing
import Foundation
@testable import NebulaStatus

@MainActor
struct ExtractConfigPathTests {
    private let model = NebulaModel()

    @Test func dashConfigSeparateArg() {
        let result = model.extractConfigPath(from: ["/usr/bin/nebula", "-config", "/etc/nebula/config.yml"])
        #expect(result == "/etc/nebula/config.yml")
    }

    @Test func doubleDashConfigSeparateArg() {
        let result = model.extractConfigPath(from: ["/usr/bin/nebula", "--config", "/etc/nebula/config.yml"])
        #expect(result == "/etc/nebula/config.yml")
    }

    @Test func dashConfigEquals() {
        let result = model.extractConfigPath(from: ["/usr/bin/nebula", "-config=/etc/nebula/config.yml"])
        #expect(result == "/etc/nebula/config.yml")
    }

    @Test func doubleDashConfigEquals() {
        let result = model.extractConfigPath(from: ["/usr/bin/nebula", "--config=/etc/nebula/config.yml"])
        #expect(result == "/etc/nebula/config.yml")
    }

    @Test func noConfigFlag() {
        let result = model.extractConfigPath(from: ["/usr/bin/nebula", "-listen", ":4242"])
        #expect(result == nil)
    }

    @Test func emptyArguments() {
        let result = model.extractConfigPath(from: [])
        #expect(result == nil)
    }

    @Test func configFlagWithoutValue() {
        let result = model.extractConfigPath(from: ["/usr/bin/nebula", "-config"])
        #expect(result == nil)
    }
}

@MainActor
struct NormalizeConfigPathTests {
    private let model = NebulaModel()

    @Test func removesTrailingSlash() {
        let result = model.normalizeConfigPath("/etc/nebula/")
        #expect(result == "/etc/nebula")
    }

    @Test func removesMultipleTrailingSlashes() {
        let result = model.normalizeConfigPath("/etc/nebula///")
        #expect(result == "/etc/nebula")
    }

    @Test func preservesRootSlash() {
        let result = model.normalizeConfigPath("/")
        #expect(result == "/")
    }

    @Test func expandsTilde() {
        let result = model.normalizeConfigPath("~/nebula/config.yml")
        #expect(!result.hasPrefix("~"))
        #expect(result.hasSuffix("/nebula/config.yml"))
    }

    @Test func preservesSimplePath() {
        let result = model.normalizeConfigPath("/etc/nebula/config.yml")
        #expect(result == "/etc/nebula/config.yml")
    }
}

@MainActor
struct IsNebulaServiceTests {
    private let model = NebulaModel()

    @Test func matchesByLabel() {
        let result = model.isNebulaService(
            label: "com.example.nebula",
            program: nil,
            programArguments: [],
            plistName: "com.example.plist"
        )
        #expect(result == true)
    }

    @Test func matchesByProgram() {
        let result = model.isNebulaService(
            label: "com.example.vpn",
            program: "/usr/local/bin/nebula",
            programArguments: [],
            plistName: "com.example.vpn.plist"
        )
        #expect(result == true)
    }

    @Test func matchesByProgramArguments() {
        let result = model.isNebulaService(
            label: "com.example.vpn",
            program: nil,
            programArguments: ["/opt/homebrew/bin/nebula", "-config", "/etc/nebula/config.yml"],
            plistName: "com.example.vpn.plist"
        )
        #expect(result == true)
    }

    @Test func matchesByPlistName() {
        let result = model.isNebulaService(
            label: "com.example.vpn",
            program: nil,
            programArguments: [],
            plistName: "nebula.plist"
        )
        #expect(result == true)
    }

    @Test func doesNotMatchUnrelatedService() {
        let result = model.isNebulaService(
            label: "com.example.vpnserver",
            program: "/usr/sbin/openvpn",
            programArguments: ["/usr/sbin/openvpn", "--config", "/etc/openvpn.conf"],
            plistName: "com.example.vpnserver.plist"
        )
        #expect(result == false)
    }
}

@MainActor
struct ExtractPIDTests {
    private let model = NebulaModel()

    @Test func extractsValidPID() {
        let text = """
        state = running
        pid = 12345
        last exit code = 0
        """
        #expect(model.extractPID(from: text) == 12345)
    }

    @Test func returnsNilWhenNoPID() {
        let text = """
        state = waiting
        last exit code = 1
        """
        #expect(model.extractPID(from: text) == nil)
    }

    @Test func extractsZeroPID() {
        let text = "pid = 0"
        #expect(model.extractPID(from: text) == 0)
    }
}

@MainActor
struct ExtractLaunchctlListStateTests {
    private let model = NebulaModel()

    @Test func runningServiceWithPID() {
        let output = """
        PID\tStatus\tLabel
        12345\t0\tcom.example.nebula
        -\t0\tcom.other.service
        """
        #expect(model.extractLaunchctlListState(label: "com.example.nebula", from: output) == .running)
    }

    @Test func stoppedServiceWithDash() {
        let output = """
        PID\tStatus\tLabel
        -\t0\tcom.example.nebula
        """
        #expect(model.extractLaunchctlListState(label: "com.example.nebula", from: output) == .stopped)
    }

    @Test func serviceNotInList() {
        let output = """
        PID\tStatus\tLabel
        12345\t0\tcom.other.service
        """
        #expect(model.extractLaunchctlListState(label: "com.example.nebula", from: output) == nil)
    }

    @Test func emptyOutput() {
        #expect(model.extractLaunchctlListState(label: "com.example.nebula", from: "") == nil)
    }
}

@MainActor
struct ShellQuoteTests {
    private let model = NebulaModel()

    @Test func quotesSimpleString() {
        #expect(model.shellQuote("hello") == "'hello'")
    }

    @Test func quotesEmptyString() {
        #expect(model.shellQuote("") == "''")
    }

    @Test func escapesSingleQuotes() {
        let result = model.shellQuote("it's")
        #expect(result == "'it'\"'\"'s'")
    }

    @Test func quotesPathWithSpaces() {
        #expect(model.shellQuote("/path/to/my config.yml") == "'/path/to/my config.yml'")
    }
}

@MainActor
struct CommandLineStartsWithNebulaTests {
    private let model = NebulaModel()

    @Test func matchesNebulaBinary() {
        #expect(model.commandLineStartsWithNebula("/usr/local/bin/nebula -config /etc/nebula/config.yml") == true)
    }

    @Test func matchesBareNebula() {
        #expect(model.commandLineStartsWithNebula("nebula -config /etc/nebula/config.yml") == true)
    }

    @Test func doesNotMatchNebulaSubstring() {
        #expect(model.commandLineStartsWithNebula("/usr/bin/nebula-cert sign") == false)
    }

    @Test func doesNotMatchOtherBinary() {
        #expect(model.commandLineStartsWithNebula("/usr/bin/openvpn --config foo") == false)
    }

    @Test func emptyStringReturnsFalse() {
        #expect(model.commandLineStartsWithNebula("") == false)
    }
}

@MainActor
struct ExtractTunDeviceTests {
    private let model = NebulaModel()

    @Test func extractsDevFromYAML() throws {
        let configContent = """
        pki:
          ca: /etc/nebula/ca.crt
        tun:
          dev: nebula1
        listen:
          host: 0.0.0.0
        """
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yml")
        try configContent.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        #expect(model.extractTunDevice(fromConfigFile: tmpFile.path) == "nebula1")
    }

    @Test func returnsNilWhenNoTunSection() throws {
        let configContent = """
        pki:
          ca: /etc/nebula/ca.crt
        listen:
          host: 0.0.0.0
        """
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yml")
        try configContent.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        #expect(model.extractTunDevice(fromConfigFile: tmpFile.path) == nil)
    }

    @Test func returnsNilForNonexistentFile() {
        #expect(model.extractTunDevice(fromConfigFile: "/nonexistent/path/config.yml") == nil)
    }

    @Test func handlesQuotedDevValue() throws {
        let configContent = """
        tun:
          dev: "nebula0"
        """
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yml")
        try configContent.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        #expect(model.extractTunDevice(fromConfigFile: tmpFile.path) == "nebula0")
    }
}

@MainActor
struct ResolveConfigFilePathTests {
    private let model = NebulaModel()

    @Test func returnsFilePathDirectly() throws {
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yml")
        try "test".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        #expect(model.resolveConfigFilePath(from: tmpFile.path) == tmpFile.path)
    }

    @Test func returnsNilForNonexistentPath() {
        #expect(model.resolveConfigFilePath(from: "/nonexistent/path/config.yml") == nil)
    }

    @Test func findsConfigYmlInDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let configFile = tmpDir.appendingPathComponent("config.yml")
        try "test".write(to: configFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        #expect(model.resolveConfigFilePath(from: tmpDir.path) == configFile.path)
    }

    @Test func returnsSingleYAMLFileInDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let yamlFile = tmpDir.appendingPathComponent("mynetwork.yml")
        try "test".write(to: yamlFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        #expect(model.resolveConfigFilePath(from: tmpDir.path) == yamlFile.path)
    }

    @Test func returnsNilForDirectoryWithMultipleYAMLFiles() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try "a".write(to: tmpDir.appendingPathComponent("a.yml"), atomically: true, encoding: .utf8)
        try "b".write(to: tmpDir.appendingPathComponent("b.yml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        #expect(model.resolveConfigFilePath(from: tmpDir.path) == nil)
    }
}
