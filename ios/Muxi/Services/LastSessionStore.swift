import Foundation

struct LastSessionStore {
    let defaults: UserDefaults

    private static let keyPrefix = "lastSession."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastSessionName(forServerID serverID: String) -> String? {
        defaults.string(forKey: Self.keyPrefix + serverID)
    }

    func save(sessionName: String, forServerID serverID: String) {
        defaults.set(sessionName, forKey: Self.keyPrefix + serverID)
    }

    func clear(forServerID serverID: String) {
        defaults.removeObject(forKey: Self.keyPrefix + serverID)
    }
}
