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
    private var preferencesWindowController: PreferencesWindowController?
    private var hotKeyItem: NSMenuItem?
    /// True from the moment a start is requested until ngrok is confirmed up (or
    /// failed). Drives the "starting…" feedback so a second hotkey press doesn't
    /// read as a stop.
    private var isStarting: Bool = false
    private var blinkTimer: Timer?
    private var blinkPhase: Bool = false

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
        // Look in Bundle.main first (canonical .app layout where build.sh drops PNGs
        // into Contents/Resources/), then fall back to Bundle.module for `swift run`
        // and other unbundled invocations.
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        guard let url, let img = NSImage(contentsOf: url) else {
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
        // Wire the inactivity/auto-stop callbacks at launch, not lazily from
        // menuWillOpen. The hotkey can start ngrok without ever opening the menu,
        // and without this the onInactivity callback stays nil → auto-stop dead.
        setupTrafficMonitor()
        applyHotKey(KeyboardShortcut.load())
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
        guard !isStarting else { return }
        isStarting = true
        updateStatusItemText()
        refreshDynamicItems()
        NgrokProcessManager.shared.start { [weak self] error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isStarting = false
                if let error = error {
                    self.showAlert(title: "Couldn’t start ngrok", message: error.localizedDescription)
                    self.postNotification(title: "Ngrok Monitor", body: "Couldn’t start ngrok — check the dialog for details.")
                    self.updateStatusItemText()
                    self.refreshDynamicItems()
                    return
                }
                self.updateStatusItemText()
                self.setupTrafficMonitor() // ensure auto-stop callbacks are wired (hotkey path may skip the menu)
                self.trafficMonitor.startMonitoring()
                self.fetchTunnels()
                self.scheduleTunnelRefresh()
                self.refreshDynamicItems()
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

    /// Toggle ngrok from the global hotkey: start if stopped, stop if running.
    @objc private func toggleNgrok() {
        guard !isStarting else { return } // already spinning up; ignore repeat presses
        // The hotkey never opens the menu, so our in-memory state can be stale
        // (menuWillOpen is what normally calls syncFromAPI). A live agent API on
        // :4040 means ngrok is actually running — reconcile here so we stop it
        // instead of firing a second `ngrok start` that ngrok rejects
        // (ERR_NGROK_334 "endpoint already online") and that fails silently.
        let isRunning = isLocalPortOpen(Constants.ngrokAgentPort)
            || NgrokProcessManager.shared.running
            || !tunnelURLs.isEmpty
        if isRunning {
            stopNgrok()
        } else {
            startNgrok()
        }
    }

    // MARK: - Global Hot Key

    /// Register (or clear) the global start/stop hotkey and refresh its menu label.
    private func applyHotKey(_ shortcut: KeyboardShortcut?) {
        GlobalHotKeyManager.shared.apply(shortcut) { [weak self] in
            self?.toggleNgrok()
        }
        refreshHotKeyItem(shortcut)
    }

    private func refreshHotKeyItem(_ shortcut: KeyboardShortcut?) {
        guard let item = hotKeyItem else { return }
        if let shortcut = shortcut, shortcut.hasRequiredModifier {
            item.title = "Start/Stop Shortcut: \(shortcut.displayString)"
        } else {
            item.title = "Start/Stop Shortcut: none"
        }
        item.attributedTitle = NSAttributedString(
            string: item.title,
            attributes: [.foregroundColor: NSColor.systemGray]
        )
    }

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            let controller = PreferencesWindowController(shortcut: KeyboardShortcut.load())
            controller.onShortcutChange = { [weak self] shortcut in
                if let shortcut = shortcut, shortcut.hasRequiredModifier {
                    shortcut.save()
                } else {
                    KeyboardShortcut.clear()
                }
                self?.applyHotKey(shortcut)
            }
            preferencesWindowController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
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
        if isStarting {
            button.title = ""
            button.toolTip = "Starting ngrok…"
            startBlinking()
            return
        }
        stopBlinking()
        let isRunning = NgrokProcessManager.shared.running || !tunnelURLs.isEmpty
        button.title = ""
        button.toolTip = nil
        button.image = makeNgrokIcon(running: isRunning)
        button.image?.accessibilityDescription = isRunning ? "Ngrok running" : "Ngrok stopped"
    }

    /// Blink the menu-bar icon green/black while ngrok is starting up.
    private func startBlinking() {
        guard blinkTimer == nil else { return }
        blinkPhase = false
        applyBlinkFrame()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.blinkPhase.toggle()
            self.applyBlinkFrame()
        }
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    private func applyBlinkFrame() {
        guard let button = statusItem.button else { return }
        button.image = makeNgrokIcon(running: blinkPhase)
        button.image?.accessibilityDescription = "Ngrok starting"
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
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

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let hotKey = NSMenuItem(title: "Start/Stop Shortcut: none", action: #selector(openPreferences), keyEquivalent: "")
        hotKey.target = self
        menu.addItem(hotKey)
        hotKeyItem = hotKey

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
            let statusIcon = isStarting ? "🟡" : (isRunning ? "🟢" : "⚫")
            let s = "\(statusIcon) Ngrok Monitor"
            title.title = s
            title.attributedTitle = NSAttributedString(
                string: s,
                attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]
            )
        }
        if let start = startItem {
            if isStarting {
                start.title = "⏳  Starting ngrok…"
                start.isEnabled = false
            } else {
                start.title = isRunning ? "▶  ngrok is running" : "▶  Start ngrok"
                start.isEnabled = !isRunning
            }
        }
        if let stop = stopItem {
            stop.isEnabled = isRunning && !isStarting
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
        if isStarting {
            text = "Status: Starting…"
        } else if isRunning {
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
        // Accessory (LSUIElement) apps aren't active, so a modal can open behind
        // the foreground window. Activate first so the user actually sees it.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Best-effort user notification (only when running as a real .app bundle).
    /// Acts as a fallback in case a modal still doesn't surface.
    private func postNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: "ngrok-start-failed", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
