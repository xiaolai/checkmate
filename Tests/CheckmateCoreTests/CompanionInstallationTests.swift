import XCTest
import Foundation
@testable import CheckmateCore

final class CompanionInstallationTests: XCTestCase {
    func testRegistrationUsesBundledExecutableAndNoNode() {
        XCTAssertEqual(CompanionInstallation.arguments(executable: URL(fileURLWithPath: "/Applications/Checkmate.app/Contents/MacOS/CheckmateMCP")), ["mcp", "add", "checkmate", "--", "/Applications/Checkmate.app/Contents/MacOS/CheckmateMCP"])
    }
    func testRegistrationUsesIsolatedHomeAndPreservesExistingSkill() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".codex/skills/checkmate-companion/SKILL.md")
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
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".codex/skills/checkmate-companion/SKILL.md"), encoding: .utf8), "companion skill")
    }
}
