import AppKit
import Foundation

final class NgrokProcessManager {
    static let shared = NgrokProcessManager()

    private var process: Process?
    private var fileHandle: FileHandle?
    private var isRunning: Bool = false
    private var onStateChange: ((Bool) -> Void)?

    var running: Bool { isRunning }

    func syncFromAPI() {
        guard isLocalPortOpen(Constants.ngrokAgentPort) else { return }
        guard let url = URL(string: "http://127.0.0.1:\(Constants.ngrokAgentPort)/api/tunnels") else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            reachable = data != nil
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 1)
        if reachable && !isRunning {
            isRunning = true
        }
    }

    func currentVersion() -> String? {
        guard let path = resolveNgrokPath() else { return nil }
        let task = Process()
        task.launchPath = path
        task.arguments = ["--version"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch {
            log.error("ngrok --version failed to launch: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if let match = output.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) {
            return String(output[match])
        }
        return nil
    }

    func runUpdate(completion: @escaping (_ output: String, _ success: Bool) -> Void) {
        guard let path = resolveNgrokPath() else {
            completion("ngrok executable not found.", false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = path
            task.arguments = ["update"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"].map { "\($0):\(Constants.extraPATH)" }) ?? Constants.extraPATH
            task.environment = env
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
            } catch {
                DispatchQueue.main.async {
                    completion("Failed to launch ngrok update: \(error.localizedDescription)", false)
                }
                return
            }
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8) ?? ""
            // Strip ngrok's structured log lines (start with "t=" timestamp) so the
            // user just sees the actual update result.
            let cleaned = raw
                .components(separatedBy: .newlines)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !trimmed.isEmpty && !trimmed.hasPrefix("t=")
                }
                .joined(separator: "\n")
            DispatchQueue.main.async {
                completion(cleaned.isEmpty ? "(no output)" : cleaned, task.terminationStatus == 0)
            }
        }
    }

    private func resolveNgrokPath() -> String? {
        for path in Constants.ngrokSearchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    func start(completion: @escaping (Error?) -> Void) {
        // Deliver the outcome exactly once, on the main thread. Both the startup
        // probe and the termination handler can race to report; whichever lands
        // first wins and the other becomes a no-op. This guarantees the caller's
        // "starting" UI state always resolves (no stuck blinking).
        var didComplete = false
        func finish(_ error: Error?) {
            let deliver = {
                guard !didComplete else { return }
                didComplete = true
                completion(error)
            }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }

        guard !isRunning else {
            finish(nil)
            return
        }

        guard let ngrokPath = resolveNgrokPath() else {
            let searched = Constants.ngrokSearchPaths.joined(separator: ", ")
            finish(NSError(domain: "NgrokMonitor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ngrok executable not found. Looked in: \(searched). Install ngrok (brew install ngrok) or add it to one of those paths."
            ]))
            return
        }

        let task = Process()
        task.launchPath = ngrokPath
        task.arguments = ["start", "--all", "--log=stdout"]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { "\($0):\(Constants.extraPATH)" }) ?? Constants.extraPATH
        task.environment = env

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        var recentOutput = ""
        let outputLock = NSLock()

        task.terminationHandler = { [weak self] proc in
            outputLock.lock()
            let tail = recentOutput
            outputLock.unlock()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !didComplete {
                    // ngrok died inside the startup window (e.g. ERR_NGROK_334,
                    // session limit, bad config). Report it through `completion`
                    // so the caller shows one visible alert, and skip
                    // handleTermination's separate dialog to avoid double alerts.
                    self.isRunning = false
                    self.process = nil
                    self.fileHandle = nil
                    finish(NSError(domain: "NgrokMonitor", code: Int(proc.terminationStatus), userInfo: [
                        NSLocalizedDescriptionKey: "ngrok exited (code \(proc.terminationStatus)).\n\n\(tail.isEmpty ? "(no output)" : tail)"
                    ]))
                } else {
                    self.handleTermination(exitCode: proc.terminationStatus, output: tail)
                }
            }
        }

        do {
            try task.run()
            self.process = task
            self.fileHandle = pipe.fileHandleForReading
            self.isRunning = true

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handler in
                let data = handler.availableData
                guard !data.isEmpty else {
                    handler.readabilityHandler = nil
                    return
                }
                if let text = String(data: data, encoding: .utf8) {
                    outputLock.lock()
                    recentOutput = String((recentOutput + text).suffix(4000))
                    outputLock.unlock()
                    if let self = self {
                        DispatchQueue.main.async {
                            self.parseNgrokOutput(text)
                        }
                    }
                }
            }

            // Confirm startup after a short probe. Capture `task` strongly so the
            // probe always runs even if the process already died and self.process
            // was cleared — otherwise the completion could leak and the caller's
            // "starting" state would never resolve.
            DispatchQueue.global().asyncAfter(deadline: .now() + Constants.Timeout.earlyStartProbe) {
                if !task.isRunning && task.terminationStatus != 0 {
                    outputLock.lock()
                    let tail = recentOutput
                    outputLock.unlock()
                    finish(NSError(domain: "NgrokMonitor", code: Int(task.terminationStatus), userInfo: [
                        NSLocalizedDescriptionKey: "ngrok exited (code \(task.terminationStatus)).\n\n\(tail.isEmpty ? "(no output)" : tail)"
                    ]))
                } else {
                    finish(nil)
                }
            }
        } catch {
            self.isRunning = false
            finish(error)
        }
    }

    func stop(completion: ((Error?) -> Void)? = nil) {
        if let proc = process, isRunning {
            proc.terminate()

            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                proc.waitUntilExit()
                semaphore.signal()
            }
            let timeout = semaphore.wait(timeout: .now() + Constants.Timeout.gracefulStop)

            if timeout == .timedOut {
                let killTask = Process()
                killTask.launchPath = "/bin/kill"
                killTask.arguments = ["-9", String(proc.processIdentifier)]
                do {
                    try killTask.run()
                } catch {
                    log.error("SIGKILL of ngrok pid \(proc.processIdentifier) failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            self.process = nil
            self.fileHandle = nil
            self.isRunning = false
            completion?(nil)
            return
        }

        // We don't own a Process, but ngrok may still be alive from a previous
        // app session (or started outside the app). If the agent port is up,
        // terminate whatever holds it so the toggle does the obvious thing
        // instead of silently no-opping.
        if isLocalPortOpen(Constants.ngrokAgentPort), let pid = pidListeningOnAgentPort() {
            let killTask = Process()
            killTask.launchPath = "/bin/kill"
            killTask.arguments = ["-TERM", String(pid)]
            do {
                try killTask.run()
                killTask.waitUntilExit()
            } catch {
                log.error("failed to terminate unowned ngrok pid \(pid): \(error.localizedDescription, privacy: .public)")
            }
        }
        self.isRunning = false
        completion?(nil)
    }

    /// PID of whatever process is listening on the ngrok agent port, or nil.
    /// Used to reclaim an ngrok the app didn't spawn.
    private func pidListeningOnAgentPort() -> Int32? {
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["-nP", "-iTCP:\(Constants.ngrokAgentPort)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch {
            log.error("lsof for ngrok agent port failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        let firstLine = out.split(whereSeparator: { $0.isNewline }).first.map(String.init)
        return firstLine.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func handleTermination(exitCode: Int32 = 0, output: String = "") {
        let wasRunning = self.isRunning
        self.isRunning = false
        self.process = nil
        self.fileHandle = nil
        self.onStateChange?(false)
        if wasRunning && exitCode != 0 {
            // Repaint the menu-bar icon to "stopped" and bring the alert to the
            // front — as an accessory (LSUIElement) app, a modal otherwise opens
            // behind the foreground window and looks like nothing happened.
            NgrokMonitor.shared.updateTunnelURLs([])
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "ngrok exited"
            alert.informativeText = "Exit code \(exitCode)\n\n\(output.isEmpty ? "(no output)" : output)"
            alert.runModal()
        }
    }

    private func parseNgrokOutput(_ text: String) {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(".ngrok.") || trimmed.contains("ngrok-free.app") || trimmed.contains("ngrok.io") {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                for part in parts {
                    if part.hasPrefix("http://") || part.hasPrefix("https://") {
                        NgrokMonitor.shared.updateTunnelURL(part)
                    }
                }
            }
        }
    }
}
