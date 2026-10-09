import XCTest
@testable import CheckmateCore
@MainActor private final class RoutingEngine:EngineService {
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {
        EngineAnalysis(bestMove:fen.contains(" w ") ? "e2e4":"e7e5")
    }
}
@MainActor final class CompanionRoutingTests:XCTestCase {
    private func fixture()throws -> (GameSession,CompanionTools,URL) {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let session=try GameSession(engine:RoutingEngine()),tools=try CompanionTools(session:session),review=ReviewController()
        tools.reviewTools=ReviewTools(review:review,session:session,store:ReviewStore(directory:directory),analyzer:ReviewAnalyzer(engine:NativeEngine()))
        session.setConnection(enabled:true,role:"coach",lease:"fixture")
        return(session,tools,directory)
    }
    func testCandidatePreviewDoesNotDispatchToReviewTools()async throws {
        let (session,tools,directory)=try fixture();defer{try? FileManager.default.removeItem(at:directory)}
        let original=session.rules.fen
        let result=try await tools.call("preview_move",args:["sessionId":session.sessionId,"revision":session.revision,"from":"e2","to":"e4"],lease:"fixture") as! [String:Any]
        XCTAssertEqual((result["candidate"] as? [String:Any])?["to"] as? String,"e4")
        XCTAssertEqual(session.rules.fen,original)
    }
    func testShowPreviewUsesPracticeReadinessErrorWithReviewAdapterInstalled()async throws {
        let (session,tools,directory)=try fixture();defer{try? FileManager.default.removeItem(at:directory)}
        do {
            _ = try await tools.call("show_preview",args:["sessionId":session.sessionId,"revision":session.revision,"requestId":"show","positionId":session.positionId,"previewId":"missing","line":"candidate","ply":0],lease:"fixture")
            XCTFail("A preview without evaluation must be refused")
        } catch let failure as ProtocolFailure {XCTAssertEqual(failure.code,"PREVIEW_NOT_READY")}
    }
}
