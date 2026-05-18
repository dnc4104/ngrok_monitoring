import AppKit
import Foundation
import ServiceManagement
import UserNotifications

final class NgrokMonitor: NSObject, NSMenuDelegate {
    static let shared: NgrokMonitor = NgrokMonitor()

    private let statusItem: NSStatusItem
    private var menu: NSMenu!
    private var trafficMonitor: TrafficMonitor = TrafficMonitor()
    private var tunnelURLs: [String] = []
    private var trafficLog: [TrafficLogEntry] = []
    private var lastTrafficTime: Date? = nil
    private var currentTimeoutIndex: Int = 1 // 5 minutes default
    private var ngrokVersion: String?
    private var statusLineItem: NSMenuItem?
    private var titleItem: NSMenuItem?
    private var startItem: NSMenuItem?
    private var stopItem: NSMenuItem?
    private var versionItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var noTunnelsItem: NSMenuItem?
    private var tunnelPool: [NSMenuItem] = []
    private var lastSeenItem: NSMenuItem?
    private var noTrafficItem: NSMenuItem?
    private var trafficPool: [NSMenuItem] = []
    private var timeoutMenuItems: [NSMenuItem] = []
    private var menuTickTimer: Timer?
    private var menuTickCount: Int = 0
    private var trafficFetchInFlight: Bool = false
    private let maxTunnelSlots = 16
    private let maxTrafficSlots = 5

    private let timeoutOptions: [(String, TimeInterval)] = [
        ("1 minute", 60),
        ("5 minutes", 300),
        ("10 minutes", 600),
        ("30 minutes", 1800),
    ]

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        super.init()
        setupStatusItem()
    }

    private static let blackIcon: NSImage? = loadIcon("ngrok-black")
    private static let greenIcon: NSImage? = loadIcon("ngrok-green")

    private static func loadIcon(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else {
            log.error("missing icon resource: \(name, privacy: .public).png")
            return nil
        }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = false
        return img
    }

    private func makeNgrokIcon(running: Bool) -> NSImage? {
        return running ? Self.greenIcon : Self.blackIcon
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            button.image = makeNgrokIcon(running: false)
            button.title = ""
        }
        menu.delegate = self
        menu.autoenablesItems = false
        buildMenu()
        refreshDynamicItems()
        statusItem.menu = menu
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let version = NgrokProcessManager.shared.currentVersion()
            DispatchQueue.main.async {
                self?.ngrokVersion = version
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if trafficMonitor.timer == nil {
            setupTrafficMonitor()
        }
        NgrokProcessManager.shared.syncFromAPI()
        var apiReachable = false
        fetchTunnelsBackground { success in apiReachable = success }
        if apiReachable {
            fetchTrafficBackground()
        } else {
            tunnelURLs.removeAll()
            trafficLog.removeAll()
            lastTrafficTime = nil
        }
        refreshDynamicItems()
        updateStatusItemText()

        menuTickTimer?.invalidate()
        menuTickCount = 0
        let tick = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.menuTickCount += 1
            self.refreshDynamicItems()
            self.updateStatusItemText()
            if self.menuTickCount % 2 == 0 {
                self.refreshTrafficDataInBackground()
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        menuTickTimer = tick
    }

    private func fetchTunnelsBackground(completion: ((Bool) -> Void)? = nil) {
        guard isLocalPortOpen(Constants.ngrokAgentPort) else {
            self.tunnelURLs = []
            completion?(false)
            return
        }
        guard let url = URL(string: "http://127.0.0.1:\(Constants.ngrokAgentPort)/api/tunnels") else {
            completion?(false)
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        var urls: [String] = []
        var success = false

        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data {
                do {
                    let response = try JSONDecoder().decode(NgrokTunnelsResponse.self, from: data)
                    urls = response.tunnels.map { $0.public_url }
                    success = true
                } catch {
                    log.debug("tunnels decode skipped: \(error.localizedDescription, privacy: .public)")
                }
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + Constants.Timeout.tunnelsFetch)
        self.tunnelURLs = urls
        completion?(success)
    }

    private func fetchTrafficBackground() {
        guard isLocalPortOpen(Constants.ngrokAgentPort) else { return }
        guard let url = URL(string: "http://127.0.0.1:\(Constants.ngrokAgentPort)/api/requests/http") else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var entries: [TrafficLogEntry] = []

        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { semaphore.signal() }
            guard let data = data else { return }
            do {
                let decoded = try JSONDecoder().decode(NgrokRequestsResponse.self, from: data)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fallback = ISO8601DateFormatter()
                for req in decoded.allRequests {
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
            } catch {
                log.error("failed to decode /api/requests/http: \(error.localizedDescription, privacy: .public)")
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + Constants.Timeout.trafficFetch)

        if !entries.isEmpty {
            self.trafficLog = Array(entries.sorted { $0.timestamp > $1.timestamp }.prefix(20))
            self.lastTrafficTime = entries.map { $0.timestamp }.max()
        } else {
            self.trafficLog.removeAll()
            self.lastTrafficTime = nil
        }
    }

    private func setupTrafficMonitor() {
        trafficMonitor.onInactivity = { [weak self] in
            guard let self = self else { return }
            self.autoStopNgrok()
        }
        trafficMonitor.onTrafficUpdate = { [weak self] entries in
            guard let self = self else { return }
            self.trafficLog.insert(contentsOf: entries, at: 0)
            self.trafficLog = Array(self.trafficLog.prefix(20))
        }
        trafficMonitor.currentTimeout = timeoutOptions[currentTimeoutIndex].1
    }

    // MARK: - Actions

    @objc private func startNgrok() {
        NgrokProcessManager.shared.start { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.showAlert(title: "Error", message: "Failed to start ngrok: \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                self.updateStatusItemText()
                self.trafficMonitor.startMonitoring()
                self.fetchTunnels()
                self.scheduleTunnelRefresh()
            }
        }
    }

    @objc private func stopNgrok() {
        NgrokProcessManager.shared.stop { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.tunnelURLs.removeAll()
                self.trafficLog.removeAll()
                self.trafficMonitor.stopMonitoring()
                self.updateStatusItemText()
            }
        }
    }

    @objc private func selectTimeout(_ sender: NSMenuItem) {
        currentTimeoutIndex = sender.tag
        trafficMonitor.currentTimeout = timeoutOptions[currentTimeoutIndex].1
        trafficMonitor.resetTrafficTimer()
        for (i, item) in timeoutMenuItems.enumerated() {
            item.state = (i == currentTimeoutIndex) ? .on : .off
        }
    }

    @objc private func openURL(_ sender: NSMenuItem) {
        if let urlString = sender.representedObject as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NgrokProcessManager.shared.stop()
        trafficMonitor.stopMonitoring()
        NSApp.terminate(self)
    }

    // MARK: - Tunnel Management

    private var tunnelRefreshTimer: Timer?

    private func scheduleTunnelRefresh() {
        tunnelRefreshTimer?.invalidate()
        let t = Timer(timeInterval: Constants.Timeout.tunnelRefresh, repeats: true) { [weak self] _ in
            self?.fetchTunnels()
        }
        RunLoop.main.add(t, forMode: .common)
        tunnelRefreshTimer = t
    }

    private func fetchTunnels() {
        guard isLocalPortOpen(Constants.ngrokAgentPort) else { return }
        let url = URL(string: "http://127.0.0.1:\(Constants.ngrokAgentPort)/api/tunnels")!
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            guard let data = data else { return }
            do {
                let response = try JSONDecoder().decode(NgrokTunnelsResponse.self, from: data)
                let urls = response.tunnels.map { $0.public_url }
                DispatchQueue.main.async {
                    self.updateTunnelURLs(urls)
                }
            } catch {
                log.debug("tunnels poll decode skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
        task.resume()
    }

    func updateTunnelURLs(_ urls: [String]) {
        tunnelURLs = urls
        updateStatusItemText()
    }

    func updateTunnelURL(_ url: String) {
        if !tunnelURLs.contains(url) {
            tunnelURLs.append(url)
        }
        updateStatusItemText()
    }

    // MARK: - UI Updates

    private func updateStatusItemText() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.updateStatusItemText() }
            return
        }
        guard let button = statusItem.button else { return }
        let isRunning = NgrokProcessManager.shared.running || !tunnelURLs.isEmpty
        button.title = ""
        button.image = makeNgrokIcon(running: isRunning)
        button.image?.accessibilityDescription = isRunning ? "Ngrok running" : "Ngrok stopped"
    }

    private func buildMenu() {
        menu.removeAllItems()

        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        titleItem = title

        menu.addItem(NSMenuItem.separator())

        let start = NSMenuItem(title: "", action: #selector(startNgrok), keyEquivalent: "")
        start.target = self
        menu.addItem(start)
        startItem = start

        let stop = NSMenuItem(title: "⏹  Stop ngrok", action: #selector(stopNgrok), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        stopItem = stop

        menu.addItem(NSMenuItem.separator())

        let urlSectionTitle = NSMenuItem(title: "Tunnels", action: nil, keyEquivalent: "")
        urlSectionTitle.isEnabled = false
        menu.addItem(urlSectionTitle)

        let noTunnels = NSMenuItem(title: "  No tunnels active", action: nil, keyEquivalent: "")
        noTunnels.isEnabled = false
        noTunnels.attributedTitle = NSAttributedString(
            string: "  No tunnels active",
            attributes: [.foregroundColor: NSColor.systemGray]
        )
        menu.addItem(noTunnels)
        noTunnelsItem = noTunnels

        tunnelPool.removeAll()
        for _ in 0..<maxTunnelSlots {
            let item = NSMenuItem(title: "", action: #selector(openURL(_:)), keyEquivalent: "")
            item.target = self
            item.isHidden = true
            menu.addItem(item)
            tunnelPool.append(item)
        }

        menu.addItem(NSMenuItem.separator())

        let trafficTitle = NSMenuItem(title: "Recent Traffic", action: nil, keyEquivalent: "")
        trafficTitle.isEnabled = false
        menu.addItem(trafficTitle)

        let lastSeen = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        lastSeen.isEnabled = false
        lastSeen.isHidden = true
        menu.addItem(lastSeen)
        lastSeenItem = lastSeen

        let noTraffic = NSMenuItem(title: "  No traffic yet", action: nil, keyEquivalent: "")
        noTraffic.isEnabled = false
        noTraffic.attributedTitle = NSAttributedString(
            string: "  No traffic yet",
            attributes: [.foregroundColor: NSColor.systemGray]
        )
        menu.addItem(noTraffic)
        noTrafficItem = noTraffic

        trafficPool.removeAll()
        for _ in 0..<maxTrafficSlots {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.isHidden = true
            menu.addItem(item)
            trafficPool.append(item)
        }

        menu.addItem(NSMenuItem.separator())

        let timeoutTitle = NSMenuItem(title: "Auto-stop after inactivity", action: nil, keyEquivalent: "")
        timeoutTitle.isEnabled = false
        menu.addItem(timeoutTitle)

        timeoutMenuItems.removeAll()
        for (index, (label, _)) in timeoutOptions.enumerated() {
            let item = NSMenuItem(title: label, action: #selector(selectTimeout(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = (index == currentTimeoutIndex) ? .on : .off
            menu.addItem(item)
            timeoutMenuItems.append(item)
        }

        menu.addItem(NSMenuItem.separator())

        let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        statusLineItem = statusLine
        refreshStatusLine()

        menu.addItem(NSMenuItem.separator())

        let ver = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)
        versionItem = ver

        let editConfigItem = NSMenuItem(title: "Edit ngrok config…", action: #selector(editNgrokConfig), keyEquivalent: "")
        editConfigItem.target = self
        menu.addItem(editConfigItem)

        let updateItem = NSMenuItem(title: "Check for ngrok update…", action: #selector(checkForNgrokUpdate), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let launch = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        menu.addItem(launch)
        launchAtLoginItem = launch

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func editNgrokConfig() {
        let candidates = Constants.ngrokConfigCandidates
        let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
        guard let path = path else {
            let alert = NSAlert()
            alert.messageText = "ngrok config not found"
            alert.informativeText = "Couldn't find ngrok.yml in any of:\n\n" + candidates.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func toggleLaunchAtLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Launch at login"
            alert.informativeText = "Couldn't change the setting: \(error.localizedDescription)\n\nIf you're running an unsigned debug build, install the .app to /Applications and try again."
            alert.alertStyle = .warning
            alert.runModal()
        }
        refreshLaunchAtLoginItem()
    }

    private func refreshLaunchAtLoginItem() {
        guard let item = launchAtLoginItem else { return }
        let enabled = SMAppService.mainApp.status == .enabled
        item.state = enabled ? .on : .off
    }

    @objc private func checkForNgrokUpdate() {
        NgrokProcessManager.shared.runUpdate { [weak self] output, success in
            guard let self = self else { return }
            DispatchQueue.global(qos: .utility).async {
                let version = NgrokProcessManager.shared.currentVersion()
                DispatchQueue.main.async {
                    self.ngrokVersion = version
                }
            }
            let alert = NSAlert()
            alert.messageText = success ? "ngrok update" : "ngrok update failed"
            alert.informativeText = output
            alert.alertStyle = success ? .informational : .warning
            alert.runModal()
        }
    }

    private func refreshTunnelsSection() {
        noTunnelsItem?.isHidden = !tunnelURLs.isEmpty
        for (idx, slot) in tunnelPool.enumerated() {
            if idx < tunnelURLs.count {
                let url = tunnelURLs[idx]
                let shortURL = url
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                let newTitle = "  📎 \(shortURL)"
                if slot.title != newTitle { slot.title = newTitle }
                slot.representedObject = url
                slot.toolTip = "Click to open: \(url)"
                slot.isHidden = false
            } else {
                slot.isHidden = true
            }
        }
    }

    private func refreshDynamicItems() {
        let isRunning = NgrokProcessManager.shared.running || !tunnelURLs.isEmpty

        if let title = titleItem {
            let statusIcon = isRunning ? "🟢" : "⚫"
            let s = "\(statusIcon) Ngrok Monitor"
            title.title = s
            title.attributedTitle = NSAttributedString(
                string: s,
                attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]
            )
        }
        if let start = startItem {
            start.title = isRunning ? "▶  ngrok is running" : "▶  Start ngrok"
            start.isEnabled = !isRunning
        }
        if let stop = stopItem {
            stop.isEnabled = isRunning
        }
        if let ver = versionItem {
            let label = ngrokVersion.map { "ngrok v\($0)" } ?? "ngrok (version unknown)"
            ver.title = label
            ver.attributedTitle = NSAttributedString(
                string: label,
                attributes: [.foregroundColor: NSColor.systemGray]
            )
        }
        refreshTunnelsSection()
        refreshTrafficSection()
        refreshStatusLine()
        refreshLaunchAtLoginItem()
    }

    private func refreshTrafficSection() {
        if let lastTraffic = lastTrafficTime, let lastSeen = lastSeenItem {
            let ago = Date().timeIntervalSince(lastTraffic)
            let agoStr: String
            if ago < 60 {
                agoStr = String(format: "%.0fs ago", ago)
            } else if ago < 3600 {
                agoStr = String(format: "%.0fmin ago", ago / 60)
            } else {
                agoStr = String(format: "%.1fh ago", ago / 3600)
            }
            let s = "  Last seen: \(agoStr)"
            if lastSeen.title != s { lastSeen.title = s }
            lastSeen.attributedTitle = NSAttributedString(
                string: s,
                attributes: [.foregroundColor: NSColor.systemGray]
            )
            lastSeen.isHidden = false
        } else {
            lastSeenItem?.isHidden = true
        }

        let recentEntries = Array(trafficLog.prefix(maxTrafficSlots))
        noTrafficItem?.isHidden = !recentEntries.isEmpty
        for (idx, slot) in trafficPool.enumerated() {
            if idx < recentEntries.count {
                let entry = recentEntries[idx]
                let newTitle = "  \(entry.formattedTime)  \(entry.description)"
                if slot.title != newTitle { slot.title = newTitle }
                slot.isHidden = false
            } else {
                slot.isHidden = true
            }
        }
    }

    private func refreshTrafficDataInBackground() {
        guard !trafficFetchInFlight else { return }
        trafficFetchInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            NgrokProcessManager.shared.syncFromAPI()
            var apiReachable = false
            self.fetchTunnelsBackground { success in apiReachable = success }
            if apiReachable {
                self.fetchTrafficBackground()
            } else {
                self.tunnelURLs.removeAll()
                self.trafficLog.removeAll()
                self.lastTrafficTime = nil
            }
            DispatchQueue.main.async {
                self.trafficFetchInFlight = false
                self.refreshDynamicItems()
                self.updateStatusItemText()
            }
        }
    }

    private func refreshStatusLine() {
        guard let item = statusLineItem else { return }
        let isRunning = NgrokProcessManager.shared.running || !tunnelURLs.isEmpty
        let text: String
        if isRunning {
            let timeoutLabel = timeoutOptions[currentTimeoutIndex].0
            let remaining = formatRemaining(trafficMonitor.timeUntilTimeout)
            text = "Status: Running | Auto-stop: \(timeoutLabel) (\(remaining) left)"
        } else {
            text = "Status: Stopped"
        }
        item.title = text
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.systemGray]
        )
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTickTimer?.invalidate()
        menuTickTimer = nil
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let rem = s % 60
        if m < 60 { return rem == 0 ? "\(m)m" : "\(m)m \(rem)s" }
        let h = m / 60
        let mRem = m % 60
        return mRem == 0 ? "\(h)h" : "\(h)h \(mRem)m"
    }

    // MARK: - Auto Stop

    private func autoStopNgrok() {
        guard NgrokProcessManager.shared.running else { return }

        // UNUserNotificationCenter requires a proper .app bundle with a bundle identifier.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                let content = UNMutableNotificationContent()
                content.title = "Ngrok Monitor"
                content.body = "Auto-stopping ngrok due to inactivity"
                content.sound = .default
                let request = UNNotificationRequest(identifier: "auto-stop", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)
            }
        } else {
            log.info("auto-stopping ngrok due to inactivity (notification skipped: unbundled)")
        }

        NgrokProcessManager.shared.stop { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.tunnelURLs.removeAll()
                self.trafficLog.removeAll()
                self.trafficMonitor.stopMonitoring()
                self.updateStatusItemText()
            }
        }
    }

    // MARK: - Alerts

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
