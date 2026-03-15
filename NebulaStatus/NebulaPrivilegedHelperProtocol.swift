import Foundation

enum NebulaPrivilegedHelperConstants {
    static let plistName = "underclub.NebulaStatus.PrivilegedHelper.plist"
    static let machServiceName = "underclub.NebulaStatus.PrivilegedHelper"
    static let executableName = "underclub.NebulaStatus.PrivilegedHelper"
}

@objc protocol NebulaPrivilegedHelperProtocol: NSObjectProtocol {
    func runLaunchctl(arguments: [String], withReply reply: @escaping (Int, String, String) -> Void)
}
