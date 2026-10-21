import XCTest
import CheckmateCore
@testable import CheckmateApplication

/// A first run is a data folder with no saved progress of any kind (L-20): the saved state, its backups, and a state set
/// aside as unreadable all mean the learner has been here before.
final class FirstRunTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}
    override func tearDown(){try? FileManager.default.removeItem(at:directory)}
    func testOnlyAFolderWithoutSavedProgressIsAFirstRun()throws {
        let store=StateStore(directory:directory)
        XCTAssertFalse(try store.hasSavedProgress(),"no data folder yet")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try Data("lock".utf8).write(to:directory.appendingPathComponent("instance.lock"))
        XCTAssertFalse(try store.hasSavedProgress(),"a folder holding only other files has no progress")
        for name in ["state-v1.json","state-v1.backup.json","state-v1.first-launch-1.0.json","state-unreadable-\(UUID().uuidString).json"] {
            let file=directory.appendingPathComponent(name);try Data("{}".utf8).write(to:file)
            XCTAssertTrue(try store.hasSavedProgress(),"\(name) is saved progress")
            try FileManager.default.removeItem(at:file)
        }
    }
    func testAFolderThatCannotBeReadIsAnErrorNotAFirstRun()throws {
        try Data("not a folder".utf8).write(to:directory)
        XCTAssertThrowsError(try StateStore(directory:directory).hasSavedProgress(),"a data folder that is a file is a problem to report, never a reason to welcome the learner again")
    }
}
