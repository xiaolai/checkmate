import Foundation
import Darwin

/// Registration is an explicit Settings action, never part of application startup.
public enum CompanionInstallation {
    public static func arguments(executable: URL) -> [String] {
        ["mcp", "add", "checkmate", "--", executable.path]
    }
    public static func register(executable: URL, codex: URL, skill: Data, home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.isExecutableFile(atPath: codex.path) else {
            throw CheckmateError.unavailable("Install Codex on this Mac first.")
        }
        let skillFile = home.appendingPathComponent(".codex/skills/checkmate-companion/SKILL.md")
        // Preserve an existing user-customized skill. Registration remains usable.
        if !FileManager.default.fileExists(atPath: skillFile.path) {
            try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try skill.write(to: skillFile, options: .atomic)
        }
        let process = Process(); process.executableURL = codex; process.arguments = arguments(executable: executable)
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        guard completion.wait(timeout: .now() + 20) == .success else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw CheckmateError.unavailable("Codex setup timed out. Try again after restarting Codex.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CheckmateError.unavailable("Codex setup failed. Check that Codex is installed and try again.") }
    }
    public static func installedCodex() -> URL? {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
