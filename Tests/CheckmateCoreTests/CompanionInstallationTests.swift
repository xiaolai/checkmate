import XCTest
import Foundation
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform
import CodexAuth


final class CompanionInstallationTests: XCTestCase {
    func testRegistrationUsesBundledExecutableAndNoNode() {
        XCTAssertEqual(CompanionInstallation.arguments(executable: URL(fileURLWithPath: "/Applications/Checkmate.app/Contents/MacOS/CheckmateMCP"), bundleIdentifier: "ai.xiaolai.checkmate"), ["mcp", "add", "checkmate", "--", "/Applications/Checkmate.app/Contents/MacOS/CheckmateMCP"])
        // A development build registers under its own name, pointed at its own data directory's connection file.
        XCTAssertEqual(CompanionInstallation.arguments(executable: URL(fileURLWithPath: "/tmp/Dev.app/Contents/MacOS/CheckmateMCP"), bundleIdentifier: "ai.xiaolai.checkmate.native-development", dataDirectory: URL(fileURLWithPath: "/tmp/dev-data")), ["mcp", "add", "checkmate-development", "--", "/tmp/Dev.app/Contents/MacOS/CheckmateMCP", "--connection-file", "/tmp/dev-data/companion/connection.json"])
    }
    func testRegistrationUsesIsolatedHomeAndPreservesExistingSkill() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = CompanionInstallation.skillFolder(home: root).appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("custom skill".utf8).write(to: skill)
        try CompanionInstallation.register(executable: URL(fileURLWithPath: "/usr/bin/true"), codex: URL(fileURLWithPath: "/usr/bin/true"), skill: Data("new skill".utf8), home: root)
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), "custom skill")
    }
    func testRegistrationInstallsSkillOnlyOnExplicitAction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try CompanionInstallation.register(executable: URL(fileURLWithPath: "/usr/bin/true"), codex: URL(fileURLWithPath: "/usr/bin/true"), skill: Data("companion skill".utf8), home: root)
        XCTAssertEqual(try String(contentsOf: CompanionInstallation.skillFolder(home: root).appendingPathComponent("SKILL.md"), encoding: .utf8), "companion skill")
    }
    private func executable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url);try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    func testFinderLaunchFindsPerUserCodexInstalls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at: root) }
        // The folders searched after PATH (sayso's lookup), each holding the codex it would find.
        func found() -> [URL] { CodexExecutable.candidates(home: root.path).map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }.filter { FileManager.default.isExecutableFile(atPath: $0.path) && $0.path.hasPrefix(root.path) } }
        XCTAssertTrue(found().isEmpty)
        XCTAssertNil(CompanionInstallation.installedCodex(home: root, environment: ["PATH": root.appendingPathComponent("bin").path]).flatMap { $0.path.hasPrefix(root.path) ? $0 : nil })
        try executable(root.appendingPathComponent(".nvm/versions/node/v9.0.0/bin/codex"))
        try executable(root.appendingPathComponent(".nvm/versions/node/v20.11.1/bin/codex"))
        let nvm = found()
        XCTAssertEqual(nvm.first?.path, root.appendingPathComponent(".nvm/versions/node/v20.11.1/bin/codex").path, "The newest nvm Node wins")
        try executable(root.appendingPathComponent(".local/bin/codex"))
        let personal = found()
        XCTAssertEqual(personal.first?.path, root.appendingPathComponent(".local/bin/codex").path)
        // PATH comes first: an explicit install on PATH wins over every per-user location.
        try executable(root.appendingPathComponent("bin/codex"))
        XCTAssertEqual(CompanionInstallation.installedCodex(home: root, environment: ["PATH": root.appendingPathComponent("bin").path])?.path, root.appendingPathComponent("bin/codex").path)
    }
    func testAnUnmodifiedOlderSkillIsUpdatedAndACustomizedOneIsKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tool = URL(fileURLWithPath: "/usr/bin/true"), skill = CompanionInstallation.skillFolder(home: root).appendingPathComponent("SKILL.md")
        XCTAssertEqual(CompanionInstallation.skillState(bundled: Data("v1".utf8), home: root), .notInstalled)
        XCTAssertEqual(try CompanionInstallation.register(executable: tool, codex: tool, skill: Data("v1".utf8), home: root), .current)
        XCTAssertEqual(CompanionInstallation.skillState(bundled: Data("v2".utf8), home: root), .outdated)
        XCTAssertEqual(try CompanionInstallation.register(executable: tool, codex: tool, skill: Data("v2".utf8), home: root), .current)
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), "v2")
        try Data("v2 with my notes".utf8).write(to: skill)
        XCTAssertEqual(try CompanionInstallation.register(executable: tool, codex: tool, skill: Data("v3".utf8), home: root), .customized)
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), "v2 with my notes")
    }
    /// A stand-in Codex that writes `script`'s output and exits as it says, in a fresh temporary folder.
    private func fakeCodex(_ script: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codex = root.appendingPathComponent("bin/codex"); try executable(codex)
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: codex); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        return (root, codex)
    }
    /// V-13: a failed setup keeps what Codex said: logged, and its first line offered under Details.
    func testAFailedSetupReportsWhatCodexSaid() throws {
        let (root, codex) = try fakeCodex("echo 'progress on stdout'\necho 'Error: could not write config.toml: Permission denied' >&2\necho 'second line' >&2\nexit 3")
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try CompanionInstallation.register(executable: tool, codex: codex, skill: Data("v1".utf8), home: root)) { error in
            let failure = error as? CompanionInstallation.CodexCommandFailure
            XCTAssertEqual(failure?.details, "Error: could not write config.toml: Permission denied")
            XCTAssertEqual(userFacingMessage(error, fallback: ""), "Codex setup failed. Check that Codex is installed and try again.")
        }
        XCTAssertThrowsError(try CompanionInstallation.unregister(codex: codex, home: root, bundledSkill: Data("v1".utf8))) { error in
            XCTAssertEqual((error as? CompanionInstallation.CodexCommandFailure)?.details, "Error: could not write config.toml: Permission denied")
            XCTAssertEqual(userFacingMessage(error, fallback: ""), "Codex could not remove the Checkmate connection. It may already be removed.")
        }
    }
    /// A Codex that says a great deal neither blocks on a full pipe nor makes the details unbounded.
    func testCodexOutputIsBoundedAndNeverBlocks() throws {
        let (root, codex) = try fakeCodex("head -c 400000 /dev/zero | tr '\\0' 'x' >&2\nhead -c 400000 /dev/zero | tr '\\0' 'y'\nexit 1")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try CompanionInstallation.unregister(codex: codex, home: root, bundledSkill: Data("v1".utf8))) { error in
            let details = (error as? CompanionInstallation.CodexCommandFailure)?.details ?? ""
            XCTAssertTrue(details.hasPrefix("xxxx")); XCTAssertLessThanOrEqual(details.count, CompanionInstallation.detailLimit)
        }
        XCTAssertNil(CompanionInstallation.firstLine(Data("\n\n  \n".utf8)), "nothing said, no details")
        XCTAssertEqual(CompanionInstallation.firstLine(Data("\n  warning: one\ntwo".utf8)), "warning: one")
    }

    // V-15: Codex's configuration is read as a file, never by running Codex, to see which Checkmate it starts.
    private func codexHome(_ config: String?) throws -> (URL, [String: String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let config { try Data(config.utf8).write(to: root.appendingPathComponent("config.toml")) }
        return (root, ["CODEX_HOME": root.path])
    }
    func testRegistrationIsReadFromCodexConfiguration() throws {
        let release = "ai.xiaolai.checkmate", development = "ai.xiaolai.checkmate.native-development"
        let cases: [(String?, String?, CompanionInstallation.Registration)] = [
            (nil, release, .absent),
            ("model = \"gpt-5\"\n", release, .absent),
            ("[mcp_servers.checkmate]\ncommand = \"/Applications/Checkmate.app/Contents/MacOS/CheckmateMCP\"\n", release, .registered(command: "/Applications/Checkmate.app/Contents/MacOS/CheckmateMCP")),
            ("[mcp_servers.checkmate]\ncommand = \"/Applications/Checkmate.app/Contents/MacOS/CheckmateMCP\"\n", development, .absent),
            ("# mine\n[mcp_servers.other]\ncommand = \"/bin/other\"\n\n[mcp_servers.checkmate-development]\nargs = [\"--connection-file\", '/tmp/a\"b.json']\ncommand = '/tmp/Check mate.app/Contents/MacOS/CheckmateMCP'  # literal\n[mcp_servers.checkmate-development.env]\nX = \"1\"\n", development, .registered(command: "/tmp/Check mate.app/Contents/MacOS/CheckmateMCP")),
            ("[mcp_servers.\"checkmate\"]\ncommand = \"/A\\\\B/Check\\u00e9.app/Contents/MacOS/CheckmateMCP\"\n", release, .registered(command: "/A\\B/Check\u{e9}.app/Contents/MacOS/CheckmateMCP")),
            ("[mcp_servers.checkmate]\nurl = \"http://127.0.0.1:1\"\n", release, .unreadable),
            ("mcp_servers.checkmate.command = \"/x\"\n", release, .unreadable),
            ("[mcp_servers.checkmate]\ncommand = \"\"\"\n/x\"\"\"\n", release, .unreadable),
        ]
        for (config, bundle, expected) in cases {
            let (root, environment) = try codexHome(config); defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertEqual(CompanionInstallation.registration(bundleIdentifier: bundle, environment: environment), expected, config ?? "no file")
        }
        let (root, environment) = try codexHome(String(repeating: "#", count: CompanionInstallation.configurationLimit + 1)); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(CompanionInstallation.registration(bundleIdentifier: release, environment: environment), .unreadable, "an oversized file is not read")
    }
    func testRegistrationIsComparedWithThisCopyOfCheckmate() throws {
        let (root, environment) = try codexHome(nil); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Checkmate.app/Contents/MacOS/CheckmateMCP"), link = root.appendingPathComponent("Linked.app")
        try executable(app); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Checkmate.app"))
        func check(_ command: String?) throws -> CompanionInstallation.SetupCheck {
            if let command { try Data("[mcp_servers.checkmate]\ncommand = \"\(command)\"\n".utf8).write(to: root.appendingPathComponent("config.toml")) }
            return CompanionInstallation.setupCheck(executable: app, bundleIdentifier: "ai.xiaolai.checkmate", environment: environment)
        }
        XCTAssertEqual(try check(nil), .notSetUp)
        XCTAssertEqual(try check(app.path), .current)
        XCTAssertEqual(try check(link.appendingPathComponent("Contents/MacOS/CheckmateMCP").path), .current, "a link to this copy is this copy")
        XCTAssertEqual(try check("/Volumes/Checkmate/Checkmate.app/Contents/MacOS/CheckmateMCP"), .stale(registered: "/Volumes/Checkmate/Checkmate.app/Contents/MacOS/CheckmateMCP"))
        try Data("[mcp_servers.checkmate]\nurl = \"x\"\n".utf8).write(to: root.appendingPathComponent("config.toml"))
        XCTAssertEqual(CompanionInstallation.setupCheck(executable: app, bundleIdentifier: "ai.xiaolai.checkmate", environment: environment), .unknown)
        XCTAssertTrue(CompanionInstallation.SetupCheck.stale(registered: "/x").registered); XCTAssertTrue(CompanionInstallation.SetupCheck.current.registered)
        XCTAssertTrue(CompanionInstallation.SetupCheck.unknown.registered, "an entry Checkmate cannot read is still Codex's registration")
        XCTAssertFalse(CompanionInstallation.SetupCheck.notSetUp.registered)
    }
    func testRemovingCodexSetupDeletesOnlyCheckmatesOwnSkill() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tool = URL(fileURLWithPath: "/usr/bin/true"), skill = Data("v1".utf8), folder = CompanionInstallation.skillFolder(home: root)
        try CompanionInstallation.register(executable: tool, codex: tool, skill: skill, home: root)
        XCTAssertEqual(try CompanionInstallation.unregister(codex: tool, home: root, bundledSkill: skill), .removed);XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try CompanionInstallation.register(executable: tool, codex: tool, skill: skill, home: root);try Data("my own notes".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(try CompanionInstallation.unregister(codex: tool, home: root, bundledSkill: skill), .kept);XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path),"An edited skill is kept")
    }
}
