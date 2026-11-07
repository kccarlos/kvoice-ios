import Foundation

/// iPhone model facts read from the model identifier (no private API).
public enum DeviceModel {
    /// This device's identifier, such as "iPhone14,5" (the simulated model
    /// on the simulator).
    public static var current: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// iPhone 15 Pro ("iPhone16,1") and every later iPhone have an Action Button.
    public static func hasActionButton(_ identifier: String = current) -> Bool {
        guard identifier.hasPrefix("iPhone"),
              let major = Int(identifier.dropFirst(6).prefix { $0.isNumber }) else { return false }
        return major >= 16
    }
}
