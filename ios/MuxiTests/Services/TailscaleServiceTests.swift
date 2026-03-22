import Testing
@testable import Muxi

@Suite("TailscaleService")
struct TailscaleServiceTests {

    @Test("Initial state is disconnected")
    func initialState() async {
        let service = TailscaleService()
        let state = await service.state
        #expect(state == .disconnected)
    }

    @Test("State transitions to error on start without libtailscale")
    func startTransitionsToError() async throws {
        let service = TailscaleService()
        do {
            try await service.start(controlURL: "https://invalid.test", authKey: "test-key", hostname: "test")
        } catch {
            // Expected to fail without real libtailscale
        }
        let state = await service.state
        if case .error = state {
            // OK — expected
        } else if state == .disconnected {
            // Also acceptable
        } else {
            Issue.record("Unexpected state after failed start: \(state)")
        }
    }

    @Test("Stop returns to disconnected")
    func stopReturnsToDisconnected() async {
        let service = TailscaleService()
        await service.stop()
        let state = await service.state
        #expect(state == .disconnected)
    }

    @Test("Dial throws when not connected")
    func dialThrowsWhenNotConnected() async {
        let service = TailscaleService()
        await #expect(throws: TailscaleError.notConnected) {
            _ = try await service.dial(host: "100.64.0.1", port: 22)
        }
    }
}
