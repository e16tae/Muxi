import Foundation
import Testing

@testable import Muxi

@Suite("SSH Host Key Verification")
struct HostKeyVerificationTests {

    // MARK: - SSHHostKeyError

    @Test("fingerprintVerificationNeeded has correct description")
    func fingerprintVerificationNeededDescription() {
        let error = SSHHostKeyError.fingerprintVerificationNeeded(
            fingerprint: "SHA256:abc123"
        )
        #expect(error.errorDescription?.contains("SHA256:abc123") == true)
        #expect(error.errorDescription?.contains("verification needed") == true)
    }

    @Test("fingerprintMismatch has correct description")
    func fingerprintMismatchDescription() {
        let error = SSHHostKeyError.fingerprintMismatch(
            expected: "SHA256:old", actual: "SHA256:new"
        )
        #expect(error.errorDescription?.contains("SHA256:old") == true)
        #expect(error.errorDescription?.contains("SHA256:new") == true)
        #expect(error.errorDescription?.contains("changed") == true)
    }

    @Test("hostKeyNotAvailable has correct description")
    func hostKeyNotAvailableDescription() {
        let error = SSHHostKeyError.hostKeyNotAvailable
        #expect(error.errorDescription?.contains("host key") == true)
    }

    // MARK: - Equatable

    @Test("SSHHostKeyError equatable: same fingerprints are equal")
    func fingerprintVerificationNeededEquality() {
        let a = SSHHostKeyError.fingerprintVerificationNeeded(fingerprint: "SHA256:abc")
        let b = SSHHostKeyError.fingerprintVerificationNeeded(fingerprint: "SHA256:abc")
        #expect(a == b)
    }

    @Test("SSHHostKeyError equatable: different fingerprints are not equal")
    func fingerprintVerificationNeededInequality() {
        let a = SSHHostKeyError.fingerprintVerificationNeeded(fingerprint: "SHA256:abc")
        let b = SSHHostKeyError.fingerprintVerificationNeeded(fingerprint: "SHA256:xyz")
        #expect(a != b)
    }

    @Test("SSHHostKeyError equatable: mismatch pairs are equal when matching")
    func fingerprintMismatchEquality() {
        let a = SSHHostKeyError.fingerprintMismatch(expected: "SHA256:old", actual: "SHA256:new")
        let b = SSHHostKeyError.fingerprintMismatch(expected: "SHA256:old", actual: "SHA256:new")
        #expect(a == b)
    }

    @Test("SSHHostKeyError equatable: different error cases are not equal")
    func differentCasesInequality() {
        let a = SSHHostKeyError.fingerprintVerificationNeeded(fingerprint: "SHA256:abc")
        let b = SSHHostKeyError.hostKeyNotAvailable
        #expect(a != b)
    }

    // MARK: - Fingerprint Format

    @Test("Fingerprint format starts with SHA256: prefix")
    func fingerprintFormatPrefix() {
        // Verify our format expectation: "SHA256:<base64>"
        let fingerprint = "SHA256:n4bQgYhMfWWaL+qgxVrQFaO/TxsrC4Is0V1sFbDwCgg="
        #expect(fingerprint.hasPrefix("SHA256:"))

        let base64Part = String(fingerprint.dropFirst("SHA256:".count))
        #expect(!base64Part.isEmpty)
        // Base64 characters are alphanumeric, +, /, =
        let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/="))
        let allValid = base64Part.unicodeScalars.allSatisfy { validChars.contains($0) }
        #expect(allValid)
    }

    // MARK: - Server Model

    @Test("Server model has nil fingerprint by default")
    func serverDefaultFingerprint() {
        let server = Server(
            name: "Test", host: "host", username: "user", authMethod: .password
        )
        #expect(server.hostKeyFingerprint == nil)
    }

    @Test("Server model stores fingerprint when provided")
    func serverStoresFingerprint() {
        let server = Server(
            name: "Test", host: "host", username: "user", authMethod: .password,
            hostKeyFingerprint: "SHA256:abc123"
        )
        #expect(server.hostKeyFingerprint == "SHA256:abc123")
    }

    @Test("Server model fingerprint is mutable")
    func serverFingerprintMutable() {
        let server = Server(
            name: "Test", host: "host", username: "user", authMethod: .password
        )
        #expect(server.hostKeyFingerprint == nil)

        server.hostKeyFingerprint = "SHA256:newfingerprint"
        #expect(server.hostKeyFingerprint == "SHA256:newfingerprint")
    }
}
