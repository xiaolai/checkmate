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


/// Audit #9, #10, #25, #26: a development build's skill is separate from the released one, removal deletes only the
/// files Checkmate wrote, and removal reports whether the skill was removed, absent or kept.
final class CompanionFixInstallationTests: XCTestCase {
    private let tool = URL(fileURLWithPath: "/usr/bin/true"), release = "ai.xiaolai.checkmate", development = "ai.xiaolai.checkmate.native-development"
    private let skill = Data("---\nname: checkmate-companion\ndescription: test\n---\n\nBody\n".utf8)
    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testADevelopmentBuildNeverTouchesTheReleasedSkill() throws {
        let root = try home(), released = root.appendingPathComponent(".codex/skills/checkmate-companion/SKILL.md")
        try CompanionInstallation.register(executable: tool, codex: tool, skill: skill, bundleIdentifier: release, home: root)
        let before = try Data(contentsOf: released)
        XCTAssertEqual(try CompanionInstallation.register(executable: tool, codex: tool, skill: Data("---\nname: checkmate-companion\n---\nnewer\n".utf8), bundleIdentifier: development, home: root), .current)
        XCTAssertEqual(try Data(contentsOf: released), before, "Development setup does not overwrite the released skill")
        let own = root.appendingPathComponent(".codex/skills/checkmate-companion-development/SKILL.md")
        XCTAssertEqual(try String(contentsOf: own, encoding: .utf8), "---\nname: checkmate-companion-development\n---\nnewer\n", "The development copy is named after its own folder")
        XCTAssertEqual(try CompanionInstallation.unregister(codex: tool, bundleIdentifier: development, home: root, bundledSkill: Data("---\nname: checkmate-companion\n---\nnewer\n".utf8)), .removed)
        XCTAssertEqual(try Data(contentsOf: released), before, "Removing development setup keeps the released skill")
        XCTAssertEqual(CompanionInstallation.skillState(bundled: skill, bundleIdentifier: release, home: root), .current)
        XCTAssertEqual(CompanionInstallation.skillName(bundleIdentifier: release), "checkmate-companion")
        XCTAssertEqual(CompanionInstallation.skillName(bundleIdentifier: development), "checkmate-companion-development")
    }
    func testTheBundledSkillIsRenamedForDevelopment() throws {
        let bundled = try Data(contentsOf: NativeResources.url("companion-skill.md"))
        XCTAssertEqual(CompanionInstallation.installedText(bundled, bundleIdentifier: release), bundled)
        XCTAssertTrue(String(decoding: CompanionInstallation.installedText(bundled, bundleIdentifier: development), as: UTF8.self).hasPrefix("---\nname: checkmate-companion-development\n"), "The bundled frontmatter still has the shape the rename expects")
    }
    func testRemovingSetupKeepsFilesTheLearnerAddedToTheSkillFolder() throws {
        let root = try home(), folder = CompanionInstallation.skillFolder(home: root, bundleIdentifier: release)
        try CompanionInstallation.register(executable: tool, codex: tool, skill: skill, bundleIdentifier: release, home: root)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("echo mine".utf8).write(to: folder.appendingPathComponent("scripts/helper.sh"))
        XCTAssertEqual(try CompanionInstallation.unregister(codex: tool, bundleIdentifier: release, home: root, bundledSkill: skill), .removed)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("scripts/helper.sh"), encoding: .utf8), "echo mine", "A learner's own file survives")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".checkmate-installed.sha256").path))
        try CompanionInstallation.register(executable: tool, codex: tool, skill: skill, bundleIdentifier: release, home: root)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("scripts"))
        XCTAssertEqual(try CompanionInstallation.unregister(codex: tool, bundleIdentifier: release, home: root, bundledSkill: skill), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "A folder holding only Checkmate's files is removed")
    }
    func testRemovalDistinguishesAbsentFromKept() throws {
        let root = try home()
        XCTAssertEqual(try CompanionInstallation.unregister(codex: tool, bundleIdentifier: release, home: root, bundledSkill: skill), .absent, "No skill was installed, so none was kept")
        try CompanionInstallation.register(executable: tool, codex: tool, skill: skill, bundleIdentifier: release, home: root)
        try Data("my notes".utf8).write(to: CompanionInstallation.skillFolder(home: root, bundleIdentifier: release).appendingPathComponent("SKILL.md"))
        XCTAssertEqual(try CompanionInstallation.unregister(codex: tool, bundleIdentifier: release, home: root, bundledSkill: skill), .kept)
    }
}
