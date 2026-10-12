import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// Every change of a presentation's displayed frame drops the selection, inspection and annotations drawn for the
/// previous frame; a hidden presentation leaves the live board's selection alone.
final class CleanupSessionTests:XCTestCase {
    @MainActor private func demonstration(_ s:GameSession)throws {
        try s.demonstrate(title:"Opening",introduction:"Imagine",lines:[DemoLineInput(label:"Center",moves:[DemoStepInput(uci:"e2e4"),DemoStepInput(uci:"e7e5")])])
    }
    /// Selects a piece on the displayed frame and draws marks over it.
    @MainActor private func markFrame(_ s:GameSession,square:String,file:StaticString=#filePath,line:UInt=#line)throws {
        try s.select(square);s.annotate(arrows:[["e2","e4"]],highlights:[Highlight(sq:square,kind:"focus")])
        XCTAssertEqual(s.selected,square,file:file,line:line);XCTAssertNotNil(s.inspection,file:file,line:line);XCTAssertFalse(s.arrows.isEmpty,file:file,line:line)
    }
    @MainActor private func assertFrameCleared(_ s:GameSession,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertNil(s.selected,file:file,line:line);XCTAssertNil(s.inspection,file:file,line:line);XCTAssertTrue(s.destinations.isEmpty,file:file,line:line)
        XCTAssertTrue(s.arrows.isEmpty,file:file,line:line);XCTAssertTrue(s.highlights.isEmpty,file:file,line:line)
    }

    @MainActor func testSeekingADemonstrationClearsTheFrame()throws {
        let s=try GameSession(engine:nil);try demonstration(s);try s.seekDemo(line:0,ply:1)
        try markFrame(s,square:"e4");try s.seekDemo(line:0,ply:2);assertFrameCleared(s)
    }
    /// The reported gap: Play on a finished demonstration restarts it at frame zero.
    @MainActor func testReplayingAFinishedDemonstrationClearsTheFrame()throws {
        let s=try GameSession(engine:nil);try demonstration(s);try s.seekDemo(line:0,ply:2)
        try markFrame(s,square:"e5");s.playDemo()
        XCTAssertEqual(s.demonstration?.ply,0);XCTAssertEqual(s.demonstration?.playing,true);assertFrameCleared(s)
        s.pauseDemo()
    }
    @MainActor func testAutoplayAdvanceClearsTheFrame() async throws {
        let s=try GameSession(engine:nil);try demonstration(s);try markFrame(s,square:"e2");s.playDemo()
        XCTAssertEqual(s.selected,"e2","Starting from frame zero keeps the frame");XCTAssertEqual(s.demonstration?.ply,0)
        for _ in 0..<60 where s.demonstration?.ply==0 {try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertEqual(s.demonstration?.ply,1);assertFrameCleared(s);s.pauseDemo()
    }
    /// Pausing keeps the displayed frame, so the selection made on it still describes the board; closing returns to the game.
    @MainActor func testStoppingKeepsTheFrameAndClosingClearsIt()throws {
        let s=try GameSession(engine:nil);try demonstration(s);try s.seekDemo(line:0,ply:1);s.playDemo();try markFrame(s,square:"e4")
        s.pauseDemo();XCTAssertEqual(s.demonstration?.ply,1);XCTAssertEqual(s.selected,"e4");XCTAssertNotNil(s.inspection)
        s.closePresentation();XCTAssertNil(s.demonstration);XCTAssertNil(s.selected);XCTAssertNil(s.inspection);XCTAssertTrue(s.arrows.isEmpty)
    }
    @MainActor func testHiddenDemonstrationFrameChangesKeepTheLiveSelection()throws {
        let s=try GameSession(engine:nil);try demonstration(s);s.selectPresentation(false);try s.select("d2")
        XCTAssertEqual(s.selected,"d2");try s.seekDemo(line:0,ply:2);XCTAssertEqual(s.selected,"d2");XCTAssertNotNil(s.inspection)
    }

    @MainActor func testTestMoveAndPreviewStepsClearTheFrame() async throws {
        let s=try GameSession(engine:InstantCandidateEngine());try s.beginPreview();try markFrame(s,square:"e2")
        try await s.testMove(from:"e2",to:"e4");XCTAssertEqual(s.preview?.status,"ready");assertFrameCleared(s)
        let frames=try XCTUnwrap(s.preview?.evaluation?.candidateFrames);XCTAssertGreaterThan(frames.count,1)
        try markFrame(s,square:"e4");try s.previewAt(ply:0,line:"candidate");assertFrameCleared(s)
        try markFrame(s,square:"d2");try s.previewAt(ply:0,line:"recommended");assertFrameCleared(s)
        XCTAssertEqual(s.rules.history,[])
    }
    /// A cancelled analysis returns the preview to the real position: that is a frame change too.
    @MainActor func testCancelledTestMoveClearsTheFrame() async throws {
        let s=try GameSession(engine:StalledCandidateEngine());try s.beginPreview()
        let analysis=Task{try await s.testMove(from:"e2",to:"e4")}
        for _ in 0..<100 where s.preview?.status != "analyzing" {try await Task.sleep(nanoseconds:5_000_000)}
        XCTAssertEqual(s.preview?.status,"analyzing");try markFrame(s,square:"e4")
        analysis.cancel();_ = try? await analysis.value
        XCTAssertEqual(s.preview?.status,"choosing");XCTAssertEqual(s.preview?.displayFen,s.rules.fen);assertFrameCleared(s)
    }
}
@MainActor private final class InstantCandidateEngine:TestEngineService {func analyze(fen:String,skill:Int,budget:Int,multiPv:Int) async throws->EngineAnalysis {let r=try ChessRules(fen:fen);return EngineAnalysis(bestMove:r.moves().first?.uci)}}
@MainActor private final class StalledCandidateEngine:TestEngineService {func analyze(fen:String,skill:Int,budget:Int,multiPv:Int) async throws->EngineAnalysis {try await Task.sleep(nanoseconds:10_000_000_000);return EngineAnalysis(bestMove:nil)}}
