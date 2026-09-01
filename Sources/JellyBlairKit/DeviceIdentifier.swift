import Foundation

/// A stable random identifier for this install. Jellyfin keeps one session per
/// device ID, so sharing an ID across devices makes logins revoke each other.
enum DeviceIdentifier {
    private static let defaultsKey = "deviceID"

    static let value: String = {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: defaultsKey)
        return fresh
    }()
}
