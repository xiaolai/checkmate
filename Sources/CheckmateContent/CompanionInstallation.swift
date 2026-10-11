import CheckmateDomain
import CheckmateSupport
import CheckmateAssets
import Foundation
import Darwin
import CryptoKit

/// Registration is an explicit Settings action, never part of application startup.
public enum CompanionInstallation {
    /// The released app registers `checkmate`. Any other build registers `checkmate-development` with its own
    /// connection file, so a development build never replaces the released registration or talks to the released app.
    public static func arguments(executable: URL, bundleIdentifier: String? = Bundle.main.bundleIdentifier, dataDirectory: URL = ApplicationDataPaths.defaultDirectory()) -> [String] {
        if isRelease(bundleIdentifier) { return ["mcp", "add", "checkmate", "--", executable.path] }
        return ["mcp", "add", "checkmate-development", "--", executable.path, "--connection-file", dataDirectory.appendingPathComponent("companion/connection.json").path]
    }
    /// The installed companion skill compared with this version's. Checkmate records the hash of the text it wrote,
    /// so an unmodified older copy can be updated while a learner's own edits are never overwritten.
    public enum SkillState: Equatable { case notInstalled, current, outdated, customized }
    /// What removing the setup did with the skill: removed Checkmate's copy, found none, or kept the learner's edits.
    public enum SkillRemoval: Equatable { case removed, absent, kept }
    static func isRelease(_ bundleIdentifier: String?) -> Bool { bundleIdentifier == "ai.xiaolai.checkmate" }
    /// Like the MCP registration, a development build's skill has its own name and folder, so installing or removing it
    /// never touches the released app's skill.
    public static func skillName(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String { isRelease(bundleIdentifier) ? "checkmate-companion" : "checkmate-companion-development" }
    public static func skillFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL { home.appendingPathComponent(".codex/skills/" + skillName(bundleIdentifier: bundleIdentifier)) }
    static func skillFile(home: URL, bundleIdentifier: String?) -> URL { skillFolder(home: home, bundleIdentifier: bundleIdentifier).appendingPathComponent("SKILL.md") }
    static func markerFile(home: URL, bundleIdentifier: String?) -> URL { skillFolder(home: home, bundleIdentifier: bundleIdentifier).appendingPathComponent(".checkmate-installed.sha256") }
    /// The skill text this build installs: a development build renames the bundled skill to match its folder.
    static func installedText(_ bundled: Data, bundleIdentifier: String?) -> Data {
        let released = "---\nname: checkmate-companion\n", text = String(decoding: bundled, as: UTF8.self)
        guard !isRelease(bundleIdentifier), text.hasPrefix(released) else { return bundled }
        return Data(("---\nname: " + skillName(bundleIdentifier: bundleIdentifier) + "\n" + text.dropFirst(released.count)).utf8)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func skillState(bundled: Data, bundleIdentifier: String? = Bundle.main.bundleIdentifier, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SkillState {
        let bundled = installedText(bundled, bundleIdentifier: bundleIdentifier)
        guard let installed = try? Data(contentsOf: skillFile(home: home, bundleIdentifier: bundleIdentifier)) else { return .notInstalled }
        if installed == bundled { return .current }
        // Without a matching record of what Checkmate wrote, the copy may hold the learner's edits.
        guard let recorded = try? String(contentsOf: markerFile(home: home, bundleIdentifier: bundleIdentifier), encoding: .utf8), recorded.trimmingCharacters(in: .whitespacesAndNewlines) == hash(installed) else { return .customized }
        return .outdated
    }
    @discardableResult public static func register(executable: URL, codex: URL, skill: Data, bundleIdentifier: String? = Bundle.main.bundleIdentifier, home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> SkillState {
        guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.isExecutableFile(atPath: codex.path) else {
            throw CheckmateError.unavailable("Install Codex on this Mac first.")
        }
        // Automation never registers with the learner's real Codex (tests pass a stand-in executable).
        if NativePolicy.silent, let real = installedCodex(), codex.resolvingSymlinksInPath() == real.resolvingSymlinksInPath() {
            throw CheckmateError.unavailable("Codex setup is disabled during automation.")
        }
        let skillFile = skillFile(home: home, bundleIdentifier: bundleIdentifier), state = skillState(bundled: skill, bundleIdentifier: bundleIdentifier, home: home)
        let text = installedText(skill, bundleIdentifier: bundleIdentifier)
        // Install or update Checkmate's own copy; a customized skill is kept. Registration remains usable either way.
        if state == .notInstalled || state == .outdated {
            try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try text.write(to: skillFile, options: .atomic)
        }
        // A current copy is exactly Checkmate's text too: record it, or a missing or stale marker makes the next update see it as customized.
        if state != .customized { try Data(hash(text).utf8).write(to: markerFile(home: home, bundleIdentifier: bundleIdentifier), options: .atomic) }
        let process = Process(); process.executableURL = codex; process.arguments = arguments(executable: executable, bundleIdentifier: bundleIdentifier)
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
        return skillState(bundled: skill, bundleIdentifier: bundleIdentifier, home: home)
    }
    /// Undoes Set up Codex: removes this build's MCP registration and Checkmate's own skill copy. A customized
    /// skill is kept, and so is anything else the learner added to its folder.
    @discardableResult public static func unregister(codex: URL, bundleIdentifier: String? = Bundle.main.bundleIdentifier, home: URL = FileManager.default.homeDirectoryForCurrentUser, bundledSkill: Data, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> SkillRemoval {
        if NativePolicy.silent, let real = installedCodex(), codex.resolvingSymlinksInPath() == real.resolvingSymlinksInPath() {
            throw CheckmateError.unavailable("Codex setup is disabled during automation.")
        }
        let name = isRelease(bundleIdentifier) ? "checkmate" : "checkmate-development"
        let process = Process(); process.executableURL = codex; process.arguments = ["mcp", "remove", name]; process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let completion = DispatchSemaphore(value: 0); process.terminationHandler = { _ in completion.signal() }
        try process.run()
        guard completion.wait(timeout: .now() + 20) == .success else { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw CheckmateError.unavailable("Codex did not respond. Try again after restarting Codex.") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CheckmateError.unavailable("Codex could not remove the Checkmate connection. It may already be removed.") }
        switch skillState(bundled: bundledSkill, bundleIdentifier: bundleIdentifier, home: home) {
        case .notInstalled: return .absent
        case .customized: return .kept
        case .current, .outdated: break
        }
        // Only the two files Checkmate wrote are removed; the folder goes only once nothing else is left in it.
        try FileManager.default.removeItem(at: skillFile(home: home, bundleIdentifier: bundleIdentifier))
        try? FileManager.default.removeItem(at: markerFile(home: home, bundleIdentifier: bundleIdentifier))
        let folder = skillFolder(home: home, bundleIdentifier: bundleIdentifier)
        if (try FileManager.default.contentsOfDirectory(atPath: folder.path)).isEmpty { try FileManager.default.removeItem(at: folder) }
        return .removed
    }
    /// Why Set up Codex must not register this copy, or nil. Codex keeps the registered path, so it must outlive this
    /// launch: a translocated app runs from a randomized temporary path, and a disk image disappears on eject.
    public static func launchLocationProblem(bundle: URL) -> String? {
        if bundle.path.contains("/AppTranslocation/") {
            return "macOS is running Checkmate from a temporary location, so Codex could not find it later. Quit Checkmate, move it to the Applications folder in Finder, open it from there, then choose Set up Codex."
        }
        var volume = statfs()
        if statfs(bundle.path, &volume) == 0, volume.f_flags & UInt32(MNT_RDONLY) != 0 {
            return "Checkmate is running from a read-only disk image, which disappears when it is ejected. Drag Checkmate to the Applications folder, open it from there, then choose Set up Codex."
        }
        return nil
    }
    /// An app opened from Finder gets a minimal PATH, so the usual per-user install locations are searched too
    /// (npm global, Volta, Bun, pnpm, ~/.local/bin and the newest nvm Node), after Homebrew and the inherited PATH.
    public static func installedCodex(home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        candidates(home: home, environment: environment).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    static func candidates(home: URL, environment: [String: String]) -> [URL] {
        let fixed = ["/opt/homebrew/bin", "/usr/local/bin"] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let personal = [".local/bin", ".npm-global/bin", ".volta/bin", ".bun/bin", "Library/pnpm"].map { home.appendingPathComponent($0).path }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let nodes = ((try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { nvm.appendingPathComponent($0).appendingPathComponent("bin").path }
        return (fixed + personal + nodes).filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
    }
}
