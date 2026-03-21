import Foundation
import Testing
@testable import Muxi

@Suite("TailscaleConfigStore", .serialized)
struct TailscaleConfigStoreTests {

    private func makeStore() -> TailscaleConfigStore {
        let defaults = UserDefaults(suiteName: "TailscaleConfigStoreTests")!
        defaults.removePersistentDomain(forName: "TailscaleConfigStoreTests")
        defaults.synchronize()
        return TailscaleConfigStore(defaults: defaults, keychainService: KeychainService())
    }

    @Test("Save and load controlURL")
    func saveLoadControlURL() {
        let store = makeStore()
        store.controlURL = "https://hs.example.com"
        #expect(store.controlURL == "https://hs.example.com")
    }

    @Test("Save and load hostname")
    func saveLoadHostname() {
        let store = makeStore()
        store.hostname = "muxi-iphone"
        #expect(store.hostname == "muxi-iphone")
    }

    @Test("Default hostname from device name")
    func defaultHostname() {
        let store = makeStore()
        #expect(store.hostname.isEmpty == false)
    }

    @Test("isConfigured requires controlURL and preAuthKey")
    func isConfigured() {
        let store = makeStore()
        #expect(store.isConfigured == false)
        store.controlURL = "https://hs.example.com"
        #expect(store.isConfigured == false)
    }

    @Test("Clear removes all config")
    func clearConfig() {
        let store = makeStore()
        store.controlURL = "https://hs.example.com"
        store.hostname = "test"
        store.clear()
        #expect(store.controlURL == "")
        #expect(store.hostname != "test")
    }
}
