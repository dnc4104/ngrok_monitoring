import Foundation

enum Constants {
    /// Local port the ngrok agent web UI / API listens on.
    static let ngrokAgentPort: UInt16 = 4040

    /// Search paths probed in order to locate the `ngrok` executable.
    static let ngrokSearchPaths: [String] = [
        "/opt/homebrew/bin/ngrok",
        "/usr/local/bin/ngrok",
        "/usr/bin/ngrok",
        "\(NSHomeDirectory())/.local/bin/ngrok",
        "\(NSHomeDirectory())/bin/ngrok",
    ]

    /// PATH fragment prepended to spawned ngrok processes so subcommands like
    /// `ngrok update` can find their own siblings.
    static let extraPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    enum Timeout {
        /// Wait after `ngrok start` to detect an immediate failure (bad config, etc).
        static let earlyStartProbe: TimeInterval = 1.5
        /// `URLSession` deadline for the tunnels-list call.
        static let tunnelsFetch: TimeInterval = 2
        /// `URLSession` deadline for the requests-list call.
        static let trafficFetch: TimeInterval = 3
        /// Cap on graceful ngrok termination before SIGKILL.
        static let gracefulStop: TimeInterval = 5
        /// Polling cadence for traffic / inactivity detection.
        static let trafficPoll: TimeInterval = 10
        /// Cadence for refreshing the tunnels list while running.
        static let tunnelRefresh: TimeInterval = 5
        /// Quick local-port probe deadline (milliseconds).
        static let portProbeMs: Int32 = 150
    }

    /// Locations probed for an existing `ngrok.yml` config file.
    static var ngrokConfigCandidates: [String] {
        [
            "\(NSHomeDirectory())/Library/Application Support/ngrok/ngrok.yml",
            "\(NSHomeDirectory())/.config/ngrok/ngrok.yml",
            "\(NSHomeDirectory())/.ngrok2/ngrok.yml",
        ]
    }
}
