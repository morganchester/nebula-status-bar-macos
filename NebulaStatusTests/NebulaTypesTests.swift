import Testing
import Foundation
@testable import NebulaStatus

struct ManualNebulaEntryTests {
    @Test func roundTripsThroughJSON() throws {
        let entry = ManualNebulaEntry(id: "test-id-123", configPath: "/etc/nebula/config.yml")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ManualNebulaEntry.self, from: data)
        #expect(decoded.id == entry.id)
        #expect(decoded.configPath == entry.configPath)
    }

    @Test func roundTripsEmptyConfigPath() throws {
        let entry = ManualNebulaEntry(id: "empty", configPath: "")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ManualNebulaEntry.self, from: data)
        #expect(decoded.configPath == "")
    }
}

struct NebulaServiceComputedPropertyTests {
    static let launchdService = NebulaService(
        id: "launchd:system:com.example.nebula",
        title: "Nebula",
        subtitle: "com.example.nebula",
        detectedConfigPath: "/etc/nebula/config.yml",
        kind: .launchd(
            label: "com.example.nebula",
            plistPath: "/Library/LaunchDaemons/com.example.nebula.plist",
            domain: .system
        )
    )

    static let manualService = NebulaService(
        id: "manual-123",
        title: "Nebula Manual",
        subtitle: "Manual launch",
        detectedConfigPath: "/tmp/nebula.yml",
        kind: .manual
    )

    @Test func isManualReturnsTrueForManualKind() {
        #expect(Self.manualService.isManual == true)
    }

    @Test func isManualReturnsFalseForLaunchdKind() {
        #expect(Self.launchdService.isManual == false)
    }

    @Test func plistPathReturnsPathForLaunchdKind() {
        #expect(Self.launchdService.plistPath == "/Library/LaunchDaemons/com.example.nebula.plist")
    }

    @Test func plistPathReturnsNilForManualKind() {
        #expect(Self.manualService.plistPath == nil)
    }

    @Test func launchdLabelReturnsLabelForLaunchdKind() {
        #expect(Self.launchdService.launchdLabel == "com.example.nebula")
    }

    @Test func launchdLabelReturnsNilForManualKind() {
        #expect(Self.manualService.launchdLabel == nil)
    }

    @Test func domainReturnsValueForLaunchdKind() {
        #expect(Self.launchdService.domain == .system)
    }

    @Test func domainReturnsNilForManualKind() {
        #expect(Self.manualService.domain == nil)
    }
}

struct LaunchctlDomainTests {
    @Test func systemTargetString() {
        #expect(LaunchctlDomain.system.target == "system")
    }

    @Test func guiTargetString() {
        #expect(LaunchctlDomain.gui(501).target == "gui/501")
    }

    @Test func systemRequiresPrivileges() {
        #expect(LaunchctlDomain.system.requiresPrivileges == true)
    }

    @Test func guiDoesNotRequirePrivileges() {
        #expect(LaunchctlDomain.gui(501).requiresPrivileges == false)
    }
}

struct PrivilegedHelperStateTests {
    @Test func enabledDoesNotNeedAttention() {
        #expect(PrivilegedHelperState.enabled.needsAttention == false)
    }

    @Test func unreachableNeedsAttention() {
        #expect(PrivilegedHelperState.unreachable.needsAttention == true)
    }

    @Test func notRegisteredNeedsAttention() {
        #expect(PrivilegedHelperState.notRegistered.needsAttention == true)
    }

    @Test func requiresApprovalNeedsAttention() {
        #expect(PrivilegedHelperState.requiresApproval.needsAttention == true)
    }

    @Test func notFoundNeedsAttention() {
        #expect(PrivilegedHelperState.notFound.needsAttention == true)
    }
}

struct AppMetadataTests {
    @Test func versionLineFormat() {
        let metadata = AppMetadata(
            name: "TestApp",
            version: "1.2.3",
            build: "42",
            bundleIdentifier: "com.test.app"
        )
        #expect(metadata.versionLine == "TestApp 1.2.3 (42)")
    }
}
