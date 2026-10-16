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
