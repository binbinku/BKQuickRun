import AppKit
import Combine
import Darwin
import Foundation

struct ScriptRunID: Hashable {
    let script: UUID
    let variant: UUID?
}

enum ScriptRunStatus: Codable, Equatable {
    case starting, running, stopping, stopped, finished, failed(String)

    var label: String {
        switch self {
        case .starting: "启动中"
        case .running: "运行中"
        case .stopping: "停止中"
        case .stopped: "已停止"
        case .finished: "已结束"
        case .failed(let reason): reason
        }
    }
}

@MainActor
final class ScriptRuns: ObservableObject {
    enum InputState {
        case unavailable, ready, sending, closed
    }

    struct Run: Identifiable {
        let id: ScriptRunID
        let name: String
        let files: ScriptRunFiles
        let logSources: [ScriptLogSource]
        var status: ScriptRunStatus
        var inputState: InputState
    }

    private enum Job {
        case background(ScriptProcess)
        case terminal(startDeadline: DispatchTime)
    }

    @Published private(set) var runs: [ScriptRunID: Run] = [:]
    private var jobs: [ScriptRunID: Job] = [:]
    private var monitor: Timer?
    private var whenStopped: (() -> Void)?
    private var isShuttingDown = false

    var activeRuns: [Run] { jobs.keys.compactMap { runs[$0] }.sorted { $0.name < $1.name } }
    var hasActiveRuns: Bool { !jobs.isEmpty }

    func start(id: ScriptRunID, name: String, path: String, arguments: [String], inTerminal: Bool,
               logSources: [ScriptLogSource], acceptsInput: Bool = false) throws {
        guard jobs[id] == nil, !isShuttingDown else { return }
        _ = try ScriptFile.validate(path).invocation(arguments: arguments)
        let files = try ScriptRunFiles.create()
        let job: Job
        do {
            if !logSources.isEmpty { try files.prepareLogDirectory() }
            if inTerminal {
                try files.writeRequest(path: path, arguments: arguments, usesMultipleLogs: !logSources.isEmpty)
                job = .terminal(startDeadline: .now() + .seconds(75))
            } else {
                let logDirectory = logSources.isEmpty ? nil : files.logDirectory
                job = .background(try ScriptProcess.spawn(path: path, arguments: arguments, output: files.output,
                                                          logDirectory: logDirectory, acceptsInput: acceptsInput))
            }
        } catch {
            files.remove()
            throw error
        }

        runs[id]?.files.remove()
        jobs[id] = job
        runs[id] = Run(id: id, name: name, files: files, logSources: logSources,
                       status: inTerminal ? .starting : .running,
                       inputState: acceptsInput && !inTerminal ? .ready : .unavailable)
        startMonitorIfNeeded()

        if inTerminal {
            Task {
                do {
                    try await TerminalLauncher.run(files: files)
                    if isCurrentTerminal(id, files: files) {
                        jobs[id] = .terminal(startDeadline: .now() + .seconds(15))
                    }
                } catch {
                    guard isCurrentTerminal(id, files: files), runs[id]?.status == .starting,
                          files.readStatus() == nil, !files.isWorkerRunning else { return }
                    files.cancelLaunch()
                    finish(id, status: .failed(error.localizedDescription))
                }
            }
        }
    }

    func sendInput(_ line: String, to id: ScriptRunID, files: ScriptRunFiles) async throws {
        guard !line.contains(where: \.isNewline) else { throw AppError("请一次发送一行。") }
        guard let run = runs[id], run.files == files, run.status == .running,
              case .background(let process) = jobs[id], let channel = process.inputChannel else {
            throw AppError("这次运行已无法接收输入。")
        }
        switch run.inputState {
        case .ready: break
        case .sending: throw AppError("上一行仍在发送。")
        case .closed, .unavailable: throw AppError("脚本的输入已关闭。")
        }

        runs[id]?.inputState = .sending
        let data = Data((line + "\n").utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        let code: Int32 = await withCheckedContinuation { continuation in
            channel.write(offset: 0, data: data, queue: .main) { done, _, error in
                if done { continuation.resume(returning: error) }
            }
        }
        if runs[id]?.files == files, runs[id]?.inputState == .sending {
            runs[id]?.inputState = code == 0 ? .ready : .closed
        }
        guard code != 0 else { return }
        channel.close(flags: .stop)
        switch code {
        case EPIPE: throw AppError("脚本已关闭输入，无法继续发送。")
        case ECANCELED: throw AppError("脚本已停止，发送未完成。")
        default:
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            throw AppError("无法发送输入（\(error.localizedDescription)）。")
        }
    }

    func stop(_ id: ScriptRunID) throws {
        guard let job = jobs[id], let run = runs[id], run.status != .stopping else { return }
        switch job {
        case .background(var process):
            if let result = process.poll() {
                finish(id, status: result)
                return
            }
            process.stop()
            process.inputChannel?.close(flags: .stop)
            jobs[id] = .background(process)
        case .terminal:
            if run.status == .starting, try run.files.cancelPendingLaunch() {
                finish(id, status: .stopped)
                return
            }
            try run.files.requestStop()
        }
        setStatus(.stopping, for: id)
    }

    func stopAll(onStopped: @escaping () -> Void) {
        isShuttingDown = true
        whenStopped = onStopped
        for id in Array(jobs.keys) {
            do {
                try stop(id)
            } catch {
                // The worker also stops when its request is removed. Keep its lock and status
                // available so the monitor can wait for the worker to finish.
                runs[id]?.files.cancelLaunch()
                setStatus(.stopping, for: id)
            }
        }
        finishIfIdle()
    }

    func removeOutputFiles() {
        for run in runs.values { run.files.remove() }
    }

    private func isCurrentTerminal(_ id: ScriptRunID, files: ScriptRunFiles) -> Bool {
        if case .terminal = jobs[id] { return runs[id]?.files == files }
        return false
    }

    private func startMonitorIfNeeded() {
        guard monitor == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkProcesses() }
        }
        timer.tolerance = 0.075
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        monitor = timer
    }

    private func checkProcesses() {
        for (id, job) in jobs {
            switch job {
            case .background(let process):
                if let result = process.poll() { finish(id, status: result) }
            case .terminal(let startDeadline):
                if let run = runs[id] { checkTerminal(run, startDeadline: startDeadline) }
            }
        }
        finishIfIdle()
    }

    private func checkTerminal(_ run: Run, startDeadline: DispatchTime) {
        if let status = run.files.readStatus(), status != .running {
            finish(run.id, status: status)
        } else if run.files.isWorkerRunning {
            if run.status == .starting, run.files.readStatus() == .running {
                setStatus(.running, for: run.id)
            } else if run.status == .starting, startDeadline <= .now() {
                run.files.cancelLaunch()
                setStatus(.stopping, for: run.id)
            }
        } else if run.status != .starting {
            if let status = run.files.readStatus(), status != .running {
                finish(run.id, status: status)
            } else {
                finish(run.id, status: run.status == .stopping ? .stopped : .failed("Terminal 已结束"))
            }
        } else if startDeadline <= .now() {
            run.files.cancelLaunch()
            finish(run.id, status: .failed("Terminal 未能启动脚本"))
        }
    }

    private func setStatus(_ status: ScriptRunStatus, for id: ScriptRunID) {
        runs[id]?.status = status
        if status != .running, let inputState = runs[id]?.inputState, inputState != .unavailable {
            runs[id]?.inputState = .closed
        }
    }

    private func finish(_ id: ScriptRunID, status: ScriptRunStatus) {
        if case .background(let process) = jobs.removeValue(forKey: id) {
            process.inputChannel?.close(flags: .stop)
        }
        setStatus(status, for: id)
    }

    private func finishIfIdle() {
        guard jobs.isEmpty else { return }
        monitor?.invalidate()
        monitor = nil
        let completion = whenStopped
        whenStopped = nil
        completion?()
    }
}

struct ScriptProcess {
    let pid: pid_t
    let inputChannel: DispatchIO?
    var stopDeadline: DispatchTime?

    static func spawn(path: String, arguments: [String], output: URL? = nil,
                      logDirectory: URL? = nil, acceptsInput: Bool = false) throws -> ScriptProcess {
        let file = try ScriptFile.validate(path)
        let invocation = try file.invocation(arguments: arguments)
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        var inputPipe: [Int32] = [-1, -1]
        defer {
            for fd in inputPipe where fd >= 0 { Darwin.close(fd) }
        }
        let directory = file.url.deletingLastPathComponent().path
        if #available(macOS 26, *) {
            try check(posix_spawn_file_actions_addchdir(&actions, directory))
        } else {
            try check(posix_spawn_file_actions_addchdir_np(&actions, directory))
        }
        if let output {
            if acceptsInput {
                if pipe(&inputPipe) == -1 { try check(errno) }
                for fd in inputPipe {
                    if fcntl(fd, F_SETFD, FD_CLOEXEC) == -1 { try check(errno) }
                }
                if fcntl(inputPipe[1], F_SETNOSIGPIPE, 1) == -1 { try check(errno) }
                try check(posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO))
            } else {
                try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
            }
            try check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_WRONLY | O_CREAT | O_APPEND, 0o600))
            try check(posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO))
        } else {
            for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
                try check(posix_spawn_file_actions_addinherit_np(&actions, fd))
            }
        }

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        try check(posix_spawnattr_setsigmask(&attributes, &emptyMask))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGQUIT, SIGCHLD, SIGTTOU, SIGTTIN, SIGTSTP] { sigaddset(&defaults, signal) }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        var flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        if output == nil { flags |= POSIX_SPAWN_START_SUSPENDED }
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))

        var environment = ProcessInfo.processInfo.environment
        if let logDirectory { environment["BKQUICKRUN_LOG_DIR"] = logDirectory.path }
        return try withCStringVector(environment.map { "\($0.key)=\($0.value)" }) { env in
            func launch(_ command: [String]) throws -> (pid_t, Int32) {
                try withCStringVector(command) { argv in
                    var pid: pid_t = 0
                    let result = posix_spawn(&pid, command[0], &actions, &attributes, argv, env)
                    return (pid, result)
                }
            }

            var (pid, result) = try launch(invocation)
            if result == ENOEXEC, file.isExecutable {
                (pid, result) = try launch(["/bin/bash"] + invocation)
            }
            try check(result)
            if output == nil {
                if tcsetpgrp(STDIN_FILENO, pid) != 0 || kill(pid, SIGCONT) != 0 {
                    let code = errno
                    kill(-pid, SIGKILL)
                    while waitpid(pid, nil, 0) == -1 && errno == EINTR {}
                    try check(code)
                }
            }
            let inputFD = inputPipe[1]
            let channel: DispatchIO?
            if inputFD >= 0 {
                channel = DispatchIO(type: .stream, fileDescriptor: inputFD, queue: .global()) { _ in
                    Darwin.close(inputFD)
                }
                inputPipe[1] = -1
            } else {
                channel = nil
            }
            return ScriptProcess(pid: pid, inputChannel: channel)
        }
    }

    mutating func stop() {
        guard stopDeadline == nil else { return }
        kill(-pid, SIGTERM)
        kill(-pid, SIGCONT)
        stopDeadline = .now() + .seconds(2)
    }

    func poll() -> ScriptRunStatus? {
        var info = siginfo_t()
        // Leave the leader waitable until cleanup so its process group ID cannot be reused.
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
            return errno == ECHILD ? .failed("无法读取退出状态") : nil
        }
        guard info.si_pid == pid else {
            if let stopDeadline, stopDeadline <= .now() { kill(-pid, SIGKILL) }
            return nil
        }

        kill(-pid, SIGKILL)
        while waitpid(pid, nil, 0) == -1 && errno == EINTR {}
        if stopDeadline != nil { return .stopped }
        if info.si_code == CLD_EXITED {
            return info.si_status == 0 ? .finished : .failed("退出码 \(info.si_status)")
        }
        return .failed("信号 \(info.si_status)")
    }

    private static func withCStringVector<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        var pointers = strings.map { strdup($0) }
        defer { for pointer in pointers { free(pointer) } }
        guard !pointers.contains(nil) else { throw AppError("无法分配启动参数所需的内存。") }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }

    private static func check(_ code: Int32) throws {
        guard code != 0 else { return }
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        throw AppError("无法启动脚本（\(error.localizedDescription)）。")
    }
}
