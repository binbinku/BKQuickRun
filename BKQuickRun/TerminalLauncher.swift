import AppKit
import Carbon
import Darwin

struct ScriptRunFiles: Equatable {
    let directory: URL

    private struct Request: Codable {
        let path: String
        let arguments: [String]
        let usesMultipleLogs: Bool?
    }

    var output: URL { file("output") }
    var logDirectory: URL { directory.appending(path: "logs", directoryHint: .isDirectory) }
    private var request: URL { file("request.json") }
    private var status: URL { file("status.json") }
    private var stop: URL { file("stop") }

    static func create() throws -> ScriptRunFiles {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "BKQuickRun-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return ScriptRunFiles(directory: url)
    }

    func prepareLogDirectory() throws {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    func writeRequest(path: String, arguments: [String], usesMultipleLogs: Bool) throws {
        let command = Request(path: path, arguments: arguments, usesMultipleLogs: usesMultipleLogs)
        try JSONEncoder().encode(command).write(to: request, options: .atomic)
    }

    func requestStop() throws { try Data().write(to: stop, options: .atomic) }
    func cancelLaunch() { try? FileManager.default.removeItem(at: request) }
    func remove() { try? FileManager.default.removeItem(at: directory) }

    func cancelPendingLaunch() throws -> Bool {
        guard let lock = try InstanceLock.acquire(in: directory) else { return false }
        defer { Darwin.close(lock) }
        // A worker uses this same lock before reading the request.
        do {
            try FileManager.default.removeItem(at: request)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return true
        }
        return true
    }

    func readStatus() -> ScriptRunStatus? {
        guard let data = try? Data(contentsOf: status) else { return nil }
        return try? JSONDecoder().decode(ScriptRunStatus.self, from: data)
    }

    var isWorkerRunning: Bool {
        let fd = Darwin.open(file("instance.lock").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK
    }

    func readOutput(source: ScriptLogSource?) -> String {
        let url = source.map { logDirectory.appending(path: $0.fileName, directoryHint: .notDirectory) } ?? output
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return "" }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return "" }
        do {
            let limit: UInt64 = 65_536
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > limit ? end - limit : 0)
            let data = try handle.read(upToCount: Int(limit)) ?? Data()
            let plain = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]|\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)",
                                      with: "", options: .regularExpression)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            return end > limit ? "… 仅显示最近的输出 …\n" + plain : plain
        } catch {
            return ""
        }
    }

    func runInTerminal() {
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        do {
            guard let lock = try InstanceLock.acquire(in: directory) else { return }
            defer { Darwin.close(lock) }
            guard readStatus() == nil, let data = try? Data(contentsOf: request) else { return }
            let command = try JSONDecoder().decode(Request.self, from: data)
            let foreground = tcgetpgrp(STDIN_FILENO)
            guard foreground == getpgrp() else { throw AppError("Terminal 无法提供交互式输入。") }
            signal(SIGTTOU, SIG_IGN)
            signal(SIGHUP, SIG_IGN)
            defer { tcsetpgrp(STDIN_FILENO, foreground) }
            let logs = command.usesMultipleLogs == true ? logDirectory : nil
            var process = try ScriptProcess.spawn(path: command.path, arguments: command.arguments, logDirectory: logs)
            writeStatus(.running)
            while true {
                if let result = process.poll() {
                    writeStatus(result)
                    return
                }
                if FileManager.default.fileExists(atPath: stop.path)
                    || !FileManager.default.fileExists(atPath: request.path)
                    || tcgetpgrp(STDIN_FILENO) == -1 {
                    process.stop()
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        } catch {
            writeStatus(.failed(error.localizedDescription))
        }
    }

    private func writeStatus(_ value: ScriptRunStatus) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: status, options: .atomic)
    }

    private func file(_ name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }
}

struct TerminalCommand {
    static func make(files: ScriptRunFiles, executable: URL) -> String {
        ["/usr/bin/script", "-aqF", files.output.path, executable.path, "--terminal-run", files.directory.path]
            .map(quote).joined(separator: " ")
    }

    private static func quote(_ value: String) -> String {
        // Keep Terminal's input on one line, including when a path or argument contains control characters.
        if value.utf8.contains(where: { $0 < 32 || $0 == 127 }) {
            var escaped = "$'"
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 0..<32, 127: escaped += String(format: "\\x%02x", scalar.value)
                case 39, 92: escaped += "\\" + String(scalar)
                default: escaped.unicodeScalars.append(scalar)
                }
            }
            return escaped + "'"
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum TerminalLauncher {
    private static let bundleID = "com.apple.Terminal"

    @MainActor
    static func run(files: ScriptRunFiles) async throws {
        guard let executable = Bundle.main.executableURL else { throw AppError("找不到 BKQuickRun 可执行文件。") }
        let command = TerminalCommand.make(files: files, executable: executable)
        let workspace = NSWorkspace.shared
        let terminal: NSRunningApplication
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            terminal = running
        } else {
            guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
                throw AppError("找不到系统 Terminal 应用。")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            terminal = try await workspace.openApplication(at: url, configuration: configuration)
        }

        let pid = terminal.processIdentifier
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try send(command, to: pid) })
            }
        }
        NSApp.yieldActivation(to: terminal)
        terminal.activate()
    }

    private static func send(_ command: String, to pid: pid_t) throws {
        // Terminal.sdef defines “do script” as coredosc. Omitting the target tab opens a new window.
        let event = NSAppleEventDescriptor(
            eventClass: UInt32(kAECoreSuite), eventID: 0x646F7363,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: Int16(kAutoGenerateReturnID), transactionID: Int32(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: command), forKeyword: UInt32(keyDirectObject))
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract, .canSwitchLayer], timeout: 60)
            if let code = reply.paramDescriptor(forKeyword: UInt32(keyErrorNumber))?.int32Value, code != 0 {
                let message = reply.paramDescriptor(forKeyword: UInt32(keyErrorString))?.stringValue
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(code), userInfo: message.map {
                    [NSLocalizedDescriptionKey: $0]
                })
            }
        } catch {
            throw launchError(error)
        }
    }

    static func launchError(_ error: Error) -> AppError {
        switch (error as NSError).code {
        case Int(errAEEventNotPermitted), Int(errAEEventWouldRequireUserConsent):
            return AppError("BKQuickRun 没有控制 Terminal 的权限。请在「系统设置 → 隐私与安全性 → 自动化」中允许 BKQuickRun 控制 Terminal。")
        case Int(errAETimeout):
            return AppError("Terminal 响应超时。请先检查 Terminal 中是否已打开脚本，再决定是否重试。")
        default:
            return AppError("无法在 Terminal 中启动脚本（\(error.localizedDescription)）。")
        }
    }
}
