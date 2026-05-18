import Foundation

// MARK: - Ngrok API Models

struct NgrokTunnel: Decodable {
    let public_url: String
    let proto: String
    let config: TunnelConfig?

    struct TunnelConfig: Decodable {
        let addr: String
    }
}

struct NgrokRequest: Decodable {
    let remote_addr: String?
    let start: String? // RFC3339
    let request: RequestInfo?
    let response: ResponseInfo?

    struct RequestInfo: Decodable {
        let method: String?
        let uri: String?
    }
    struct ResponseInfo: Decodable {
        let status_code: Int?
    }

    var effectiveIP: String { remote_addr ?? "unknown" }
    var method: String? { request?.method }
    var path: String? { request?.uri }
    var time: String? { start }
    var status: Int? { response?.status_code }
}

struct NgrokRequestsResponse: Decodable {
    let requests: [NgrokRequest]?
    let page: NgrokPageInfo?

    struct NgrokPageInfo: Decodable {
        let size: Int?
    }

    var allRequests: [NgrokRequest] { requests ?? [] }
}

struct NgrokTunnelsResponse: Decodable {
    let tunnels: [NgrokTunnel]
}

// MARK: - Traffic Log Entry

struct TrafficLogEntry {
    let timestamp: Date
    let remoteAddr: String
    let bytesIn: Int
    let bytesOut: Int
    let method: String?
    let path: String?

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    var formattedBytes: String {
        let total = bytesIn + bytesOut
        if total < 1024 { return "\(total) B" }
        if total < 1024 * 1024 { return String(format: "%.1f KB", Double(total) / 1024) }
        return String(format: "%.1f MB", Double(total) / (1024 * 1024))
    }

    var description: String {
        if let method = method, let path = path {
            return "\(method) \(path)"
        }
        return "\(remoteAddr) \(formattedBytes)"
    }
}
