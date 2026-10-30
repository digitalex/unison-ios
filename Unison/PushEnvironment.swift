import Foundation

/// Which APNs environment this build's push tokens belong to (#137), so
/// the server sends each device's pushes to the matching host.
enum PushEnvironment {
    /// "sandbox" for builds Xcode installs (a development provisioning
    /// profile), "production" for TestFlight and the App Store (which embed
    /// no profile). Nil when the profile can't be read.
    static let current: String? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return "production"
        }
        return (try? Data(contentsOf: url)).flatMap(environment(inProfile:))
    }()

    /// The environment a provisioning profile grants: its signed data
    /// wraps a plist whose Entitlements hold aps-environment.
    static func environment(inProfile data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String else { return nil }
        switch aps {
        case "development": return "sandbox"
        case "production": return "production"
        default: return nil
        }
    }
}
