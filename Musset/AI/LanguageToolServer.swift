import Darwin
import Foundation

/// The LanguageTool that ships inside Musset (Resources/LanguageTool: a trimmed Java runtime and the server),
/// started on the first check on a free port of this Mac only, and stopped after a quarter of an hour unused.
/// Nothing it reads leaves the Mac.
actor LanguageToolServer {
    static let shared = LanguageToolServer()

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Unused this long, the server stops and gives its memory back.
    static let idleLimit: TimeInterval = 15 * 60

    static let home: URL? = Bundle.main.resourceURL?.appendingPathComponent("LanguageTool")
    /// One Java runtime per architecture (a runtime can't be universal): `jre` for Apple silicon, `jre-x86_64` for Intel.
    #if arch(x86_64)
    private static let runtime = "jre-x86_64"
    #else
    private static let runtime = "jre"
    #endif
    static let java: URL? = home?.appendingPathComponent("\(runtime)/bin/java")
    /// Checked once: the editor asks for every paragraph it draws, and a disk check each time slowed every redraw.
    static let isBundled: Bool = java.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false

    /// The running process, for the app's last moments (`stopNow`), when an actor can't be awaited.
    nonisolated(unsafe) private static var current: Process?
    private static var pidFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Musset").appendingPathComponent("languagetool.pid")
    }

    private var process: Process?
    private var base: URL?
    private var lastUse = Date()
    private var starting: Task<URL, Error>?
    private var watcher: Task<Void, Never>?

    /// The server's address, started if needed (a few seconds the first time).
    func url() async throws -> URL {
        lastUse = Date()
        if let p = process, p.isRunning, let base { return base }
        if let s = starting { return try await s.value }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    func stop() {
        watcher?.cancel(); watcher = nil
        process?.terminate()
        process = nil; base = nil
        Self.current = nil
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    /// When Musset quits.
    nonisolated static func stopNow() {
        current?.terminate()
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func launch() async throws -> URL {
        guard let java = Self.java, let home = Self.home, Self.isBundled else {
            throw Failure(message: L("LanguageTool is missing from this copy of Musset."))
        }
        Self.killLeftover()
        let port = try Self.freePort()
        let p = Process()
        p.executableURL = java
        p.currentDirectoryURL = home.appendingPathComponent("languagetool")
        // Serial GC and a ceiling: one writer's paragraphs, not a web service.
        // Its own short temp folder (JNA unpacks its native helpers there) and a clean environment:
        // nothing of Musset's own (DYLD_* variables under Xcode, for one) reaches Java.
        let tmp = Self.pidFile.deletingLastPathComponent().appendingPathComponent("lt-tmp")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": tmp.path + "/"]
        p.arguments = ["-Xmx1g", "-XX:+UseSerialGC", "-Djava.awt.headless=true",
                       "-Djava.io.tmpdir=\(tmp.path)", "-Djna.tmpdir=\(tmp.path)",
                       "-cp", "languagetool-server.jar", "org.languagetool.server.HTTPServer", "--port", "\(port)"]
        // Its own words go to a log beside the pid file, for when something goes wrong.
        let log = Self.pidFile.deletingLastPathComponent().appendingPathComponent("languagetool.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        p.standardOutput = handle ?? FileHandle.nullDevice
        p.standardError = handle ?? FileHandle.nullDevice
        try p.run()
        process = p
        Self.current = p
        try? FileManager.default.createDirectory(at: Self.pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(p.processIdentifier)".write(to: Self.pidFile, atomically: true, encoding: .utf8)
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if !p.isRunning { stop(); throw Failure(message: L("LanguageTool stopped while starting.")) }
            if await LanguageTool.isUp(url) {
                base = url
                watch()
                return url
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        stop()
        throw Failure(message: L("LanguageTool took too long to start."))
    }

    private func watch() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                if await self.idle { await self.stop(); return }
            }
        }
    }

    private var idle: Bool { Date().timeIntervalSince(lastUse) > Self.idleLimit }

    /// A server left by a Musset that didn't quit cleanly: ended, if it is ours (our Java, by its path).
    private static func killLeftover() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer).hasSuffix("LanguageTool/\(runtime)/bin/java") {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// A port nobody uses on this Mac, from the system.
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0 else { throw Failure(message: "bind") }
        let named = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard named == 0 else { throw Failure(message: "getsockname") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
