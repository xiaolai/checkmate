import CheckmateDomain
import CheckmateSupport
import CodexAuth
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
        try runCodex(codex, arguments(executable: executable, bundleIdentifier: bundleIdentifier), environment: environment,
                     timedOut: "Codex setup timed out. Try again after restarting Codex.", failed: "Codex setup failed. Check that Codex is installed and try again.")
        return skillState(bundled: skill, bundleIdentifier: bundleIdentifier, home: home)
    }
    /// Undoes Set up Codex: removes this build's MCP registration and Checkmate's own skill copy. A customized
    /// skill is kept, and so is anything else the learner added to its folder.
    @discardableResult public static func unregister(codex: URL, bundleIdentifier: String? = Bundle.main.bundleIdentifier, home: URL = FileManager.default.homeDirectoryForCurrentUser, bundledSkill: Data, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> SkillRemoval {
        if NativePolicy.silent, let real = installedCodex(), codex.resolvingSymlinksInPath() == real.resolvingSymlinksInPath() {
            throw CheckmateError.unavailable("Codex setup is disabled during automation.")
        }
        let name = isRelease(bundleIdentifier) ? "checkmate" : "checkmate-development"
        try runCodex(codex, ["mcp", "remove", name], environment: environment,
                     timedOut: "Codex did not respond. Try again after restarting Codex.", failed: "Codex could not remove the Checkmate connection. It may already be removed.")
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
    /// A Codex command that exited with an error: `message` for the learner, and the first line Codex wrote to its
    /// error output, if any, for Details.
    public struct CodexCommandFailure: Error, UserFacingError, Equatable {
        public let message: String, details: String?
        public var userFacingMessage: String { message }
    }
    /// The most of Codex's error output kept, in bytes, and the most of its first line shown, in characters.
    static let outputLimit = 16_384
    public static let detailLimit = 300
    /// The first non-blank line of `output`, trimmed and cut to `detailLimit`, or nil when there is none.
    public static func firstLine(_ output: Data) -> String? {
        String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }.map { String($0.prefix(detailLimit)) }
    }
    /// Runs Codex for at most 20 seconds. Both outputs are drained to the end so a talkative Codex never blocks on a
    /// full pipe; standard output is discarded and the start of the error output kept, logged, and reported on failure.
    private static func runCodex(_ codex: URL, _ arguments: [String], environment: [String: String], timedOut: String, failed: String) throws {
        let process = Process(); process.executableURL = codex; process.arguments = arguments; process.environment = environment
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        let completion = DispatchSemaphore(value: 0); process.terminationHandler = { _ in completion.signal() }
        try process.run()
        let drained = DispatchGroup(), kept = ErrorOutput()
        for (handle, keep) in [(output.fileHandleForReading, false), (errors.fileHandleForReading, true)] {
            DispatchQueue.global().async(group: drained) {
                while true {
                    let chunk: Data
                    do { guard let read = try handle.read(upToCount: 4096), !read.isEmpty else { return }; chunk = read }
                    catch { NativeLog.companion.error("Reading Codex output failed: \(String(describing: error), privacy: .public)"); return }
                    if keep { kept.append(chunk) }
                }
            }
        }
        let command = arguments.prefix(2).joined(separator: " ")
        guard completion.wait(timeout: .now() + 20) == .success else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            NativeLog.companion.error("codex \(command, privacy: .public) timed out")
            throw CheckmateError.unavailable(timedOut)
        }
        process.waitUntilExit()
        // A process Codex started may still hold the pipes open; the result waits for it only briefly.
        _ = drained.wait(timeout: .now() + 2)
        let said = kept.data, text = String(decoding: said, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            NativeLog.companion.error("codex \(command, privacy: .public) exited \(process.terminationStatus, privacy: .public): \(text, privacy: .public)")
            throw CodexCommandFailure(message: failed, details: firstLine(said))
        }
        if !said.isEmpty { NativeLog.companion.info("codex \(command, privacy: .public): \(text, privacy: .public)") }
    }
    /// The first `outputLimit` bytes of Codex's error output, appended from the draining thread.
    private final class ErrorOutput: @unchecked Sendable {
        private let lock = NSLock(); private var buffer = Data()
        func append(_ chunk: Data) { lock.withLock { if buffer.count < CompanionInstallation.outputLimit { buffer.append(chunk.prefix(CompanionInstallation.outputLimit - buffer.count)) } } }
        var data: Data { lock.withLock { buffer } }
    }

    /// The Checkmate MCP entry in Codex's configuration, read as a file because `codex mcp get` may write: none,
    /// one that starts `command`, or one Checkmate cannot read (another form, or TOML beyond what it parses).
    public enum Registration: Equatable { case absent, registered(command: String), unreadable }
    /// Codex's configuration is a small file; anything bigger is not read.
    public static let configurationLimit = 1_048_576
    static func configurationURL(home: URL, environment: [String: String]) -> URL {
        guard let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty else { return home.appendingPathComponent(".codex/config.toml") }
        return URL(fileURLWithPath: codexHome, isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("config.toml")
    }
    public static func registration(bundleIdentifier: String? = Bundle.main.bundleIdentifier, home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment) -> Registration {
        let url = configurationURL(home: home, environment: environment)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let text: String
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= configurationLimit else { NativeLog.companion.error("Codex configuration is \(size, privacy: .public) bytes; not read"); return .unreadable }
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            NativeLog.companion.error("Codex configuration unreadable: \(String(describing: error), privacy: .public)")
            return .unreadable
        }
        return registration(in: text, name: isRelease(bundleIdentifier) ? "checkmate" : "checkmate-development")
    }
    /// Finds `[mcp_servers.<name>]` and its `command`. Only the form `codex mcp add` writes, and its hand-edited
    /// equivalents, is read: a table header, and a single-line basic or literal string. A dotted or inline-table
    /// definition, or a multiline command, is reported as unreadable rather than guessed.
    static func registration(in text: String, name: String) -> Registration {
        var inTable = false, found = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                let header = tableHeader(line)
                inTable = header == ["mcp_servers", name]; found = found || inTable
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            if !inTable {
                // `mcp_servers.<name>.command = …` or `mcp_servers = {…}` would define the entry without a header.
                let parts = key.split(separator: ".").map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
                if parts.first == "mcp_servers", parts.count == 1 || parts[1] == name { return .unreadable }
                continue
            }
            guard unquoted(key) == "command" else { continue }
            guard let command = stringValue(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)), !command.isEmpty else { return .unreadable }
            return .registered(command: command)
        }
        return found ? .unreadable : .absent
    }
    /// The dotted keys of a `[table]` header, or nil for an array of tables or an unterminated quote.
    private static func tableHeader(_ line: String) -> [String]? {
        guard !line.hasPrefix("[["), let close = line.lastIndex(of: "]") else { return nil }
        var keys: [String] = [], current = "", quote: Character?
        for character in line[line.index(after: line.startIndex)..<close] {
            if let open = quote { if character == open { quote = nil } else { current.append(character) }; continue }
            switch character {
            case "\"", "'": quote = character
            case ".": keys.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            default: current.append(character)
            }
        }
        keys.append(current.trimmingCharacters(in: .whitespaces))
        return quote == nil ? keys : nil
    }
    private static func unquoted(_ key: String) -> String {
        guard key.count >= 2, let first = key.first, first == key.last, first == "\"" || first == "'" else { return key }
        return String(key.dropFirst().dropLast())
    }
    /// The single-line basic or literal TOML string at the start of `value` (a comment may follow), or nil.
    private static func stringValue(_ value: String) -> String? {
        if value.hasPrefix("'''") || value.hasPrefix("\"\"\"") { return nil }
        guard let open = value.first, open == "\"" || open == "'" else { return nil }
        var result = "", characters = value.dropFirst().makeIterator()
        while let character = characters.next() {
            if character == open { return result }
            guard open == "\"", character == "\\" else { result.append(character); continue }
            guard let escaped = characters.next() else { return nil }
            switch escaped {
            case "\"": result.append("\""); case "\\": result.append("\\"); case "b": result.append("\u{8}"); case "t": result.append("\t")
            case "n": result.append("\n"); case "f": result.append("\u{c}"); case "r": result.append("\r")
            case "u", "U":
                var hex = ""
                for _ in 0..<(escaped == "u" ? 4 : 8) { guard let digit = characters.next() else { return nil }; hex.append(digit) }
                guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
                result.unicodeScalars.append(scalar)
            default: return nil
            }
        }
        return nil
    }
    /// Whether Codex starts this copy of Checkmate for chess MCP: not set up, this copy (through any link), another
    /// copy's path (a moved, renamed or deleted app), or an entry Checkmate cannot read.
    public enum SetupCheck: Equatable {
        case notSetUp, current, stale(registered: String), unknown
        /// Codex has a Checkmate registration of some kind.
        public var registered: Bool { self != .notSetUp }
    }
    public static func setupCheck(executable: URL, bundleIdentifier: String? = Bundle.main.bundleIdentifier, home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment) -> SetupCheck {
        switch registration(bundleIdentifier: bundleIdentifier, home: home, environment: environment) {
        case .absent: return .notSetUp
        case .unreadable: return .unknown
        case .registered(let command):
            let registered = URL(fileURLWithPath: command).resolvingSymlinksInPath().standardizedFileURL.path
            return registered == executable.resolvingSymlinksInPath().standardizedFileURL.path ? .current : .stale(registered: command)
        }
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
    /// The Codex executable, found as sayso finds it: an app opened from Finder gets a minimal PATH, so after PATH the
    /// usual install locations are searched too (Homebrew, /usr/local, ~/.local/bin, npm global, Volta, Bun, pnpm and
    /// every nvm Node, newest first). Only an absolute, executable regular file is returned.
    public static func installedCodex(home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        CodexExecutable.resolve(explicit: nil, path: environment["PATH"] ?? "", candidates: CodexExecutable.candidates(home: home.path)).map { URL(fileURLWithPath: $0) }
    }
}
