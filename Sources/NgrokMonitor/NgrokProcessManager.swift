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
        guard !isRunning else {
            completion(nil)
            return
        }

        guard let ngrokPath = resolveNgrokPath() else {
            let searched = Constants.ngrokSearchPaths.joined(separator: ", ")
            completion(NSError(domain: "NgrokMonitor", code: 1, userInfo: [
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
                self?.handleTermination(exitCode: proc.terminationStatus, output: tail)
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

            // Detect immediate failure (e.g., bad config).
            DispatchQueue.global().asyncAfter(deadline: .now() + Constants.Timeout.earlyStartProbe) { [weak self, weak task] in
                guard let task = task else { return }
                if !task.isRunning && task.terminationStatus != 0 {
                    outputLock.lock()
                    let tail = recentOutput
                    outputLock.unlock()
                    DispatchQueue.main.async {
                        self?.isRunning = false
                        completion(NSError(domain: "NgrokMonitor", code: Int(task.terminationStatus), userInfo: [
                            NSLocalizedDescriptionKey: "ngrok exited (code \(task.terminationStatus)).\n\n\(tail.isEmpty ? "(no output)" : tail)"
                        ]))
                    }
                    return
                }
                DispatchQueue.main.async { completion(nil) }
            }
        } catch {
            completion(error)
        }
    }

    func stop(completion: ((Error?) -> Void)? = nil) {
        guard let proc = process, isRunning else {
            completion?(nil)
            return
        }

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
    }

    private func handleTermination(exitCode: Int32 = 0, output: String = "") {
        let wasRunning = self.isRunning
        self.isRunning = false
        self.process = nil
        self.fileHandle = nil
        self.onStateChange?(false)
        if wasRunning && exitCode != 0 {
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
