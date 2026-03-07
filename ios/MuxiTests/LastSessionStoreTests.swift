import Testing
@testable import Muxi
import Foundation

@Suite("LastSessionStore", .serialized)
struct LastSessionStoreTests {
    let store: LastSessionStore

    init() {
        let defaults = UserDefaults(suiteName: "test.LastSessionStore")!
        defaults.removePersistentDomain(forName: "test.LastSessionStore")
        store = LastSessionStore(defaults: defaults)
    }

    @Test("Returns nil for unknown server")
    func unknownServer() {
        #expect(store.lastSessionName(forServerID: "unknown") == nil)
    }

    @Test("Saves and retrieves session name")
    func saveAndRetrieve() {
        let serverID = "server-1"
        store.save(sessionName: "main", forServerID: serverID)
        #expect(store.lastSessionName(forServerID: serverID) == "main")
    }

    @Test("Overwrites previous value")
    func overwrite() {
        let serverID = "server-1"
        store.save(sessionName: "main", forServerID: serverID)
        store.save(sessionName: "dev", forServerID: serverID)
        #expect(store.lastSessionName(forServerID: serverID) == "dev")
    }

    @Test("Isolates per server")
    func perServer() {
        store.save(sessionName: "main", forServerID: "s1")
        store.save(sessionName: "work", forServerID: "s2")
        #expect(store.lastSessionName(forServerID: "s1") == "main")
        #expect(store.lastSessionName(forServerID: "s2") == "work")
    }

    @Test("Clears session for server")
    func clear() {
        store.save(sessionName: "main", forServerID: "s1")
        store.clear(forServerID: "s1")
        #expect(store.lastSessionName(forServerID: "s1") == nil)
    }
}
