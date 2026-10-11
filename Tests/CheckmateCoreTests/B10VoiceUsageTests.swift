import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// B10 low findings for the usage ledger (ST-7, ST-8, ST2-2) and the progress import report (ST-3).
@MainActor final class B10VoiceUsageTests:XCTestCase {
    private func directory()->URL {FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}

    // ST2-2
    func testAnUnreadableHistoryStillTracksThisSessionWithoutTouchingTheFile()async throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)};try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file=root.appendingPathComponent("usage-v1.json"),original=Data("unreadable".utf8);try original.write(to:file)
        let ledger=UsageLedger(directory:root);XCTAssertTrue(ledger.unavailable);XCTAssertNotNil(ledger.storageError)
        let id=ledger.begin(activity:.lessonRecording,provider:"realtime",sessionID:"session");ledger.record(operationID:id,providerID:"response",tokens:UsageTokens(total:7),status:.completed)
        XCTAssertEqual(ledger.records.count,1,"Paid activity is tracked in memory");XCTAssertEqual(ledger.totals().total,7)
        try await Task.sleep(nanoseconds:250_000_000);XCTAssertEqual(try Data(contentsOf:file),original,"The preserved file is never overwritten")
        try ledger.clear();try await ledger.flush()
        XCTAssertEqual(UsageLedger(directory:root).totals().total,7,"Clear starts the new history with this session's activity")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path).filter{$0.hasPrefix("usage-v1.unreadable-")}.count,1)
    }

    // ST-8
    func testAnOlderCumulativeSnapshotNeverReplacesANewerOne() {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let ledger=UsageLedger(directory:root),id=ledger.begin(activity:.translation,provider:"codex",sessionID:"a")
        ledger.record(operationID:id,providerID:"turn",tokens:UsageTokens(input:20,output:8,total:28),status:.completed,cumulative:true)
        ledger.record(operationID:id,providerID:"turn",tokens:UsageTokens(input:10,output:5,total:15),status:.running,cumulative:true)
        XCTAssertEqual(ledger.records.first?.tokens?.total,28,"A snapshot that went down arrived out of order");XCTAssertEqual(ledger.records.first?.status,.completed)
        ledger.record(operationID:id,providerID:"turn",tokens:UsageTokens(input:21,output:9,total:30),status:.completed,cumulative:true)
        XCTAssertEqual(ledger.totals().total,30,"Late growth is still recorded")
        let other=ledger.begin(activity:.translation,provider:"codex",sessionID:"b")
        ledger.record(operationID:other,providerID:"turn",tokens:UsageTokens(total:12),status:.running,cumulative:true)
        ledger.record(operationID:other,providerID:"turn",tokens:nil,status:.failed,cumulative:true)
        XCTAssertEqual(ledger.records.last?.status,.failed);XCTAssertEqual(ledger.records.last?.tokens?.total,12,"A final record without counters keeps the known ones")
    }

    // ST-7
    func testASuccessfulFlushClearsAStaleSaveError()async throws {
        let parent=directory();defer{try? FileManager.default.removeItem(at:parent)};try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let root=parent.appendingPathComponent("ledger");try Data("not a directory".utf8).write(to:root)
        let ledger=UsageLedger(directory:root);_=ledger.begin(activity:.translation,provider:"codex",sessionID:"a")
        for _ in 0..<200{if ledger.storageError != nil{break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(ledger.storageError,"Usage history could not be saved.","The write failed while the directory was blocked")
        try FileManager.default.removeItem(at:root);try await ledger.flush()
        XCTAssertNil(ledger.storageError,"After the space is freed, a successful save clears the warning");XCTAssertEqual(UsageLedger(directory:root).records.count,1)
    }

    // ST-3
    func testImportedMiniGamesAreReportedAsRecovered()throws {
        var archive=ApplicationState();archive.miniGames=[:]
        var state=ApplicationState();let report=try LegacyImporter.apply(JSONEncoder().encode(archive),to:&state,course:CourseLibrary())
        XCTAssertFalse(report.ignored.contains("miniGames"),"Mini-games are imported, never skipped");XCTAssertTrue(report.recovered.contains("miniGames"))
        XCTAssertNotNil(state.miniGames)
    }
}
