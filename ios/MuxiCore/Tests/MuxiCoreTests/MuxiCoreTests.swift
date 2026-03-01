import Testing
@testable import MuxiCore

@Test func coreHealthCheck() {
    #expect(MuxiCore.healthCheck() == true)
}

@Test func coreVersion() {
    #expect(MuxiCore.version == "0.1.0")
}
