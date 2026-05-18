import Foundation

final class TrafficMonitor {
    var timer: Timer?
    private var lastTrafficTime: Date = Date()
    private var latestRequestSeen: Date = .distantPast
    private var inactivityTimeout: TimeInterval = 300 // 5 minutes default
    var onInactivity: (() -> Void)?
    var onTrafficUpdate: (([TrafficLogEntry]) -> Void)?
    private var session = URLSession.shared

    var currentTimeout: TimeInterval {
        get { inactivityTimeout }
        set {
            inactivityTimeout = newValue
            lastTrafficTime = Date() // Reset on change
        }
    }

    var timeUntilTimeout: TimeInterval {
        max(0, inactivityTimeout - Date().timeIntervalSince(lastTrafficTime))
    }

    func startMonitoring(interval: TimeInterval = Constants.Timeout.trafficPoll) {
        stopMonitoring()
        // .common run loop mode so the timer keeps firing while an NSMenu is being tracked.
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkTraffic()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        checkTraffic()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func checkTraffic() {
        guard isLocalPortOpen(Constants.ngrokAgentPort) else { return }
        let url = URL(string: "http://127.0.0.1:\(Constants.ngrokAgentPort)/api/requests/http")!
        let task = session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            guard let data = data else { return }
            do {
                let response = try JSONDecoder().decode(NgrokRequestsResponse.self, from: data)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fallback = ISO8601DateFormatter()
                var entries: [TrafficLogEntry] = []
                for req in response.allRequests {
                    guard let timeStr = req.time else { continue }
                    let ts = formatter.date(from: timeStr) ?? fallback.date(from: timeStr)
                    guard let ts = ts else { continue }
                    entries.append(TrafficLogEntry(
                        timestamp: ts,
                        remoteAddr: req.effectiveIP,
                        bytesIn: 0,
                        bytesOut: 0,
                        method: req.method,
                        path: req.path
                    ))
                }
                let newestSeenInBatch = entries.map { $0.timestamp }.max() ?? .distantPast
                let newEntries = entries.filter { $0.timestamp > self.latestRequestSeen }
                if !newEntries.isEmpty {
                    self.latestRequestSeen = newestSeenInBatch
                    self.lastTrafficTime = Date()
                    DispatchQueue.main.async {
                        self.onTrafficUpdate?(newEntries)
                    }
                } else {
                    if newestSeenInBatch > self.latestRequestSeen {
                        self.latestRequestSeen = newestSeenInBatch
                    }
                    let inactivityDuration = Date().timeIntervalSince(self.lastTrafficTime)
                    if inactivityDuration >= self.inactivityTimeout {
                        DispatchQueue.main.async {
                            self.onInactivity?()
                        }
                    }
                }
            } catch {
                // ngrok may not be fully started — API can briefly return non-JSON.
                log.debug("traffic decode skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
        task.resume()
    }

    func resetTrafficTimer() {
        lastTrafficTime = Date()
    }
}
