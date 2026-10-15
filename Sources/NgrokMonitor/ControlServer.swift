import Foundation
import Network

/// Minimal loopback-only HTTP control server so external tools (for example an
/// automation agent) can start/stop ngrok and read its status *through*
/// NgrokMonitor — keeping the menu bar icon, auto-stop timer, and traffic view
/// all in sync, exactly as if the user had clicked the menu.
///
/// Endpoints, all on `127.0.0.1:<Constants.controlPort>`:
///
///   GET  /status  → `{"running": bool, "tunnels": [url, ...]}`
///   POST /start   → starts ngrok, replies once tunnels are up (same shape as /status)
///   POST /stop    → stops ngrok, replies `{"running": false, "tunnels": []}`
///
/// Security model: the listener binds to loopback only, so nothing off this Mac
/// can reach it. Any *local* process can — which is the same trust level as an
/// agent simply running `ngrok start` itself. To stop a drive-by web page from
/// triggering start/stop via a cross-origin request, the mutating endpoints
/// require the custom header `X-NgrokMonitor-Control` (any value); browsers
/// cannot set custom headers on a cross-origin request without a CORS preflight
/// that this server never answers. `GET /status` is read-only and unguarded.
///
/// Example:
///   curl -s 127.0.0.1:4042/status
///   curl -s -X POST -H 'X-NgrokMonitor-Control: 1' 127.0.0.1:4042/start
///   curl -s -X POST -H 'X-NgrokMonitor-Control: 1' 127.0.0.1:4042/stop
final class ControlServer {
    static let shared = ControlServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ch.dnconsulting.NgrokMonitor.control")
    private(set) var isRunning = false

    /// Lowercased because HTTP header names are case-insensitive and we compare
    /// against a lowercased parse.
    private static let controlHeader = "x-ngrokmonitor-control"

    func start(port: UInt16 = Constants.controlPort) {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            log.error("control server: invalid port \(port, privacy: .public)")
            return
        }

        let params = NWParameters.tcp
        // Bind to loopback only — never expose the control port off-box.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        params.allowLocalEndpointReuse = true

        do {
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.isRunning = true
                    log.info("control server listening on 127.0.0.1:\(port, privacy: .public)")
                case .failed(let error):
                    self?.isRunning = false
                    log.error("control server failed: \(error.localizedDescription, privacy: .public)")
                    self?.listener?.cancel()
                    self?.listener = nil
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            l.start(queue: queue)
            listener = l
        } catch {
            log.error("control server could not start on port \(port, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// Accumulate bytes until we have the full request head (through the blank
    /// line that ends the headers). Our requests carry no meaningful body, so we
    /// never need to read past the headers.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }
            var buffer = buffer
            if let data = data { buffer.append(data) }

            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                self.process(head, conn: conn)
                return
            }
            if error != nil || isComplete || buffer.count > 64 * 1024 {
                self.respond(conn, status: "400 Bad Request", json: ["error": "malformed request"])
                return
            }
            self.receive(conn, buffer: buffer)
        }
    }

    private func process(_ head: Data, conn: NWConnection) {
        guard let text = String(data: head, encoding: .utf8) else {
            respond(conn, status: "400 Bad Request", json: ["error": "non-utf8 request"])
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        let fields = lines.first?.split(separator: " ") ?? []
        guard fields.count >= 2 else {
            respond(conn, status: "400 Bad Request", json: ["error": "malformed request line"])
            return
        }
        let method = String(fields[0]).uppercased()
        let rawTarget = String(fields[1])
        let path = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawTarget

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        route(method: method, path: path, headers: headers, conn: conn)
    }

    private func route(method: String, path: String, headers: [String: String], conn: NWConnection) {
        switch (method, path) {
        case ("GET", "/status"), ("GET", "/"):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                self.respond(conn, status: "200 OK", json: self.statusJSON())
            }

        case ("POST", "/start"):
            guard headers[Self.controlHeader] != nil else { respondForbidden(conn); return }
            start(conn)

        case ("POST", "/stop"):
            guard headers[Self.controlHeader] != nil else { respondForbidden(conn); return }
            stopNgrok(conn)

        case (_, "/status"), (_, "/"):
            respond(conn, status: "405 Method Not Allowed", json: ["error": "use GET"])
        case (_, "/start"), (_, "/stop"):
            respond(conn, status: "405 Method Not Allowed", json: ["error": "use POST"])

        default:
            respond(conn, status: "404 Not Found", json: [
                "error": "unknown endpoint",
                "endpoints": ["GET /status", "POST /start", "POST /stop"],
            ])
        }
    }

    // MARK: - Actions

    private func start(_ conn: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            NgrokMonitor.shared.performStart { result in
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    self.respond(conn, status: "500 Internal Server Error", json: ["error": error.localizedDescription])
                case .success:
                    // Tunnels register with the agent API a moment after the
                    // process is up; poll off the main thread so the reply
                    // carries the real URLs.
                    DispatchQueue.global(qos: .userInitiated).async {
                        let tunnels = self.tunnelURLsNow(timeout: 5)
                        self.respond(conn, status: "200 OK", json: ["running": true, "tunnels": tunnels])
                    }
                }
            }
        }
    }

    private func stopNgrok(_ conn: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            NgrokMonitor.shared.performStop {
                self?.respond(conn, status: "200 OK", json: ["running": false, "tunnels": []])
            }
        }
    }

    // MARK: - Status / tunnel helpers (run off the main thread)

    private func statusJSON() -> [String: Any] {
        let running = isLocalPortOpen(Constants.ngrokAgentPort)
        let tunnels = running ? (fetchTunnelsOnce() ?? []) : []
        return ["running": running, "tunnels": tunnels]
    }

    /// Poll the ngrok agent API until at least one tunnel appears or `timeout`
    /// elapses. Blocking — must not be called on the main thread.
    private func tunnelURLsNow(timeout: TimeInterval) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isLocalPortOpen(Constants.ngrokAgentPort), let urls = fetchTunnelsOnce(), !urls.isEmpty {
                return urls
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        // A config with no tunnels (or a slow registration) legitimately yields
        // an empty list — return whatever the API reports now.
        return fetchTunnelsOnce() ?? []
    }

    private func fetchTunnelsOnce() -> [String]? {
        guard let url = URL(string: "http://127.0.0.1:\(Constants.ngrokAgentPort)/api/tunnels") else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String]?
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { semaphore.signal() }
            guard let data = data else { return }
            result = (try? JSONDecoder().decode(NgrokTunnelsResponse.self, from: data))?
                .tunnels.map { $0.public_url }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + Constants.Timeout.tunnelsFetch)
        return result
    }

    // MARK: - Response

    private func respondForbidden(_ conn: NWConnection) {
        respond(conn, status: "403 Forbidden", json: ["error": "missing X-NgrokMonitor-Control header"])
    }

    private func respond(_ conn: NWConnection, status: String, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
