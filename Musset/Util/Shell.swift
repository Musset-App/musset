import Foundation

/// Runs command-line tools from a GUI app, with the user's login-shell PATH
/// (Homebrew, asdf, ~/.local/bin) so claude and codex resolve. Typst and pandoc ship inside the app.
enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    /// Environment for child processes: the login PATH, without variables
    /// that would make the claude CLI bill an API key instead of the OAuth login.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_CODE") || key == "CLAUDECODE" {
            env.removeValue(forKey: key)
        }
        env["PATH"] = loginPath
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env
    }()

    static let loginPath: String = {
        let fallback = [
            "\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.asdf/shims",
            "/opt/homebrew/bin", "/usr/local/bin", "/Library/TeX/texbin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "echo __MUSSET_PATH__$PATH"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return fallback }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.contains("__MUSSET_PATH__") }) else { return fallback }
        let path = String(line.components(separatedBy: "__MUSSET_PATH__").last ?? "")
        return path.isEmpty ? fallback : path + ":" + fallback
    }()

    static func which(_ tool: String) -> String? {
        for dir in loginPath.split(separator: ":") {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// A tool shipped in the app's Resources/bin (typst, pandoc), else the one on the login PATH.
    static func bundledOrPath(_ tool: String, resources: URL? = Bundle.main.resourceURL) -> String? {
        if let bundled = resources?.appendingPathComponent("bin/\(tool)"),
           FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        return which(tool)
    }

    static func makeProcess(_ tool: String, _ args: [String], cwd: URL?) throws -> Process {
        let p = Process()
        guard let exe = tool.hasPrefix("/") ? tool : which(tool) else {
            throw NSError(domain: "Musset", code: 127, userInfo: [NSLocalizedDescriptionKey: L("\(tool) not found on PATH")])
        }
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        if let cwd { p.currentDirectoryURL = cwd }
        return p
    }

    /// Blocking run; call from a background task.
    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, stdin: String? = nil) throws -> Result {
        let p = try makeProcess(tool, args, cwd: cwd)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let input = Pipe()
        p.standardInput = input
        try p.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        // Read both pipes concurrently so large outputs can't deadlock.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    /// `run` waits for the process to end, so it waits on a thread of its own, never on one of Swift's shared ones:
    /// those are as many as the Mac has cores, and a few imports at once (Scrivener runs pandoc eight at a time) could hold
    /// them all, leaving nothing to finish the work. CI's three-core Macs stalled there.
    static func runAsync(_ tool: String, _ args: [String], cwd: URL? = nil, stdin: String? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Swift.Result<Shell.Result, Error> { try run(tool, args, cwd: cwd, stdin: stdin) })
            }
        }
    }

    /// Streams stdout line by line. Returns the process so callers can cancel it.
    static func stream(_ tool: String, _ args: [String], cwd: URL?, stdin: String? = nil,
                       onLine: @escaping @Sendable (String) -> Void,
                       onExit: @escaping @Sendable (Int32, String) -> Void) throws -> Process {
        let p = try makeProcess(tool, args, cwd: cwd)
        let out = Pipe(), err = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input
        let buffer = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { return }
            for line in buffer.append(data) { onLine(line) }
        }
        let errBuffer = LineBuffer()
        err.fileHandleForReading.readabilityHandler = { h in _ = errBuffer.append(h.availableData) }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            if let rest = buffer.flush() { onLine(rest) }
            onExit(proc.terminationStatus, errBuffer.all)
        }
        try p.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        return p
    }
}

final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private var everything = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        everything.append(data)
        pending.append(data)
        var lines: [String] = []
        while let idx = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<idx], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...idx)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    var all: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: everything, as: UTF8.self)
    }
}
