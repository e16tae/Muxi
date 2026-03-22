import Foundation

// MARK: - TailscaleDevice

struct TailscaleDevice: Identifiable, Sendable {
    let id: String
    let name: String
    let addresses: [String]
    let isOnline: Bool
    let os: String?
    let lastSeen: Date?

    var ipv4Address: String? {
        addresses.first(where: { $0.contains(".") }) ?? addresses.first
    }
}

// MARK: - TailscaleDeviceError

enum TailscaleDeviceError: Error, LocalizedError {
    case missingCredentials
    case invalidURL
    case apiFailed(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "인증 정보가 없습니다"
        case .invalidURL: "잘못된 URL입니다"
        case .apiFailed(let code): "API 오류 (HTTP \(code))"
        }
    }
}

// MARK: - TailscaleDeviceService

/// Fetches device lists from Tailscale (official) and Headscale REST APIs.
///
/// Parse methods are `static` so they can be unit-tested without network calls.
/// The actor uses `URLSession` for actual network requests.
actor TailscaleDeviceService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public

    func fetchDevices(account: TailscaleAccount, accessToken: String?, apiKey: String?) async throws -> [TailscaleDevice] {
        switch account.provider {
        case .official:
            guard let token = accessToken else { throw TailscaleDeviceError.missingCredentials }
            return try await fetchOfficialDevices(token: token)
        case .headscale:
            guard let key = apiKey else { throw TailscaleDeviceError.missingCredentials }
            return try await fetchHeadscaleDevices(controlURL: account.controlURL, apiKey: key)
        }
    }

    // MARK: - Official Tailscale

    /// GET https://api.tailscale.com/api/v2/tailnet/-/devices
    private func fetchOfficialDevices(token: String) async throws -> [TailscaleDevice] {
        var request = URLRequest(url: URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TailscaleDeviceError.apiFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try Self.parseOfficialResponse(data)
    }

    static func parseOfficialResponse(_ data: Data) throws -> [TailscaleDevice] {
        let decoded = try JSONDecoder.tailscaleDecoder.decode(OfficialDevicesResponse.self, from: data)
        return decoded.devices.map {
            TailscaleDevice(
                id: $0.id,
                name: $0.hostname,
                addresses: $0.addresses,
                isOnline: $0.online,
                os: $0.os,
                lastSeen: $0.lastSeen
            )
        }
    }

    // MARK: - Headscale

    /// Headscale API: try /api/v1/node (v0.23+), fallback to /api/v1/machine (v0.22-)
    private func fetchHeadscaleDevices(controlURL: String, apiKey: String) async throws -> [TailscaleDevice] {
        // Try v0.23+ endpoint first, fallback to legacy
        for path in ["/api/v1/node", "/api/v1/machine"] {
            guard let url = URL(string: "\(controlURL)\(path)") else {
                throw TailscaleDeviceError.invalidURL
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 404 { continue } // Try next endpoint
            guard status == 200 else {
                throw TailscaleDeviceError.apiFailed(status)
            }

            // Both endpoints return {"nodes": [...]} or {"machines": [...]}
            // Try nodes first, then machines
            if let devices = try? Self.parseHeadscaleNodeResponse(data) {
                return devices
            }
            return try Self.parseHeadscaleResponse(data)
        }
        throw TailscaleDeviceError.apiFailed(404)
    }

    /// Parse Headscale v0.23+ response with "nodes" key
    static func parseHeadscaleNodeResponse(_ data: Data) throws -> [TailscaleDevice] {
        let decoded = try JSONDecoder.tailscaleDecoder.decode(HeadscaleNodesResponse.self, from: data)
        return decoded.nodes.map {
            TailscaleDevice(
                id: $0.id.stringValue,
                name: $0.givenName,
                addresses: $0.ipAddresses,
                isOnline: $0.online,
                os: nil,
                lastSeen: $0.lastSeen
            )
        }
    }

    /// Parse Headscale v0.22- response with "machines" key
    static func parseHeadscaleResponse(_ data: Data) throws -> [TailscaleDevice] {
        let decoded = try JSONDecoder.tailscaleDecoder.decode(HeadscaleDevicesResponse.self, from: data)
        return decoded.machines.map {
            TailscaleDevice(
                id: $0.id.stringValue,
                name: $0.givenName,
                addresses: $0.ipAddresses,
                isOnline: $0.online,
                os: nil,
                lastSeen: $0.lastSeen
            )
        }
    }
}

// MARK: - API Response Types

private struct OfficialDevicesResponse: Decodable {
    let devices: [OfficialDevice]
}

private struct OfficialDevice: Decodable {
    let id: String
    let hostname: String
    let addresses: [String]
    let online: Bool
    let os: String?
    let lastSeen: Date?
}

private struct HeadscaleDevicesResponse: Decodable {
    let machines: [HeadscaleMachine]
}

/// Headscale v0.23+ uses "nodes" key instead of "machines"
private struct HeadscaleNodesResponse: Decodable {
    let nodes: [HeadscaleMachine]
}

/// Headscale versions vary between camelCase and snake_case JSON keys.
/// This struct handles both via custom Decodable init.
private struct HeadscaleMachine: Decodable {
    let id: StringOrInt
    let givenName: String
    let ipAddresses: [String]
    let online: Bool
    let lastSeen: Date?

    enum CamelKeys: String, CodingKey {
        case id, givenName, ipAddresses, online, lastSeen
    }

    enum SnakeKeys: String, CodingKey {
        case id, online
        case givenName = "given_name"
        case ipAddresses = "ip_addresses"
        case lastSeen = "last_seen"
    }

    init(from decoder: Decoder) throws {
        // Try camelCase first (common in newer Headscale versions)
        if let c = try? decoder.container(keyedBy: CamelKeys.self),
           c.contains(.givenName) {
            id = try c.decode(StringOrInt.self, forKey: .id)
            givenName = try c.decode(String.self, forKey: .givenName)
            ipAddresses = try c.decode([String].self, forKey: .ipAddresses)
            online = try c.decode(Bool.self, forKey: .online)
            lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        } else {
            // Fallback to snake_case
            let c = try decoder.container(keyedBy: SnakeKeys.self)
            id = try c.decode(StringOrInt.self, forKey: .id)
            givenName = try c.decode(String.self, forKey: .givenName)
            ipAddresses = try c.decode([String].self, forKey: .ipAddresses)
            online = try c.decode(Bool.self, forKey: .online)
            lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        }
    }
}

/// Decodes a JSON value that may be either a string or an integer.
/// Headscale API versions vary in whether `id` is numeric or string.
private enum StringOrInt: Decodable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var stringValue: String {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        }
    }
}

// MARK: - JSONDecoder Extension

private extension JSONDecoder {
    static let tailscaleDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            // Try fractional seconds first (e.g. "2025-03-22T10:00:00.123456Z")
            if let date = ISO8601DateFormatter.fractional.date(from: string) {
                return date
            }
            // Fall back to standard ISO 8601 (e.g. "2025-03-22T10:00:00Z")
            if let date = ISO8601DateFormatter.standard.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(string)")
        }
        return decoder
    }()
}

private extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let standard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
