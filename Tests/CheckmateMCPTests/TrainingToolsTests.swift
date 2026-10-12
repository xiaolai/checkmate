import XCTest
import Foundation
import CheckmateCore
@testable import CheckmateMCPKit

/// WI-007: the companion's training tools. Scoped to the learner's choice of Training, bound to the attempt and its
/// revision, recorded as help, and never a way to read stored answers or to drive training through generic tools.
@MainActor final class TrainingToolsTests:XCTestCase {
    private struct Fixture {let session:GameSession,player:LearningPlayer,controller:TrainingController,tools:CompanionTools,coordinator:WorkspaceTransitionCoordinator}
    private var requests=0
    private func fixture(only:[String]?=nil,attach:Bool=true)throws -> Fixture {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        var provider=try TrainingScenarioProvider.bundled()
        if let only {let all=provider.catalog.entries.flatMap{provider.scenarios(for:$0.id)};provider=try TrainingScenarioProvider(catalog:provider.catalog,scenarios:all.filter{only.contains($0.id)})}
        let controller=TrainingController(session:session,learning:player,provider:provider)
        let tools=try CompanionTools(session:session),coordinator=WorkspaceTransitionCoordinator(session:session,learning:player,review:ReviewController());coordinator.training=controller
        if attach {
            let training=TrainingTools(session:session,controller:controller)
            training.onStart={entry,resume in (try? coordinator.enter(prepared:coordinator.prepare(resume ? .trainingResume:.trainingExercise(entry:entry)),from:session.activity.place,wasReviewing:false)) != nil}
            tools.trainingTools=training
        }
        session.setConnection(enabled:true,role:"coach",lease:"lease")
        return Fixture(session:session,player:player,controller:controller,tools:tools,coordinator:coordinator)
    }
    private func args(_ f:Fixture,_ extra:[String:Any]=[:],exercise:Bool=false)->[String:Any] {
        requests+=1
        var a:[String:Any]=["sessionId":f.session.sessionId,"revision":f.session.revision,"requestId":"r\(requests)"]
        if exercise,let e=f.controller.exercise{a["attemptId"]=e.snapshot.id;a["sessionRevision"]=e.snapshot.revision}
        return a.merging(extra){_,new in new}
    }
    private func code(_ body:() async throws -> Any) async -> String? {do{_ = try await body();return nil}catch let failure as ProtocolFailure{return failure.code}catch{return "\(error)"}}
    private func json(_ value:Any)->String {String(decoding:(try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])) ?? Data(),as:UTF8.self)}
    private func capabilities(_ f:Fixture)->[String] {f.session.publicState()["capabilities"] as? [String] ?? ["missing"]}

    func testSchemasDescriptionsAndCapabilitiesFollowTheView()async throws {
        let names=Set(try ToolSchemas().names),metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("mcp-tools.json"))) as! [String:[String:Any]]
        XCTAssertTrue(TrainingTools.methods.isSubset(of:names));for name in TrainingTools.methods{XCTAssertNotNil(metadata[name]?["description"] as? String,name)}
        XCTAssertThrowsError(try ToolSchemas().parse("submit_training_action",args:["sessionId":"s","revision":0,"requestId":"r","attemptId":"a","sessionRevision":0,"kind":"teleport"]))
        XCTAssertThrowsError(try ToolSchemas().parse("submit_training_action",args:["sessionId":"s","revision":0,"requestId":"r","attemptId":"a","sessionRevision":0,"kind":"move","from":"z9","to":"a1"]))
        let f=try fixture();defer{f.player.shutdown()}
        XCTAssertFalse(capabilities(f).contains("start_training"),"practice advertises no training tools")
        f.controller.openLibrary();XCTAssertEqual(capabilities(f),["list_training_entries","start_training"])
        f.controller.begin(try f.controller.prepare(entry:"reach-target"))
        XCTAssertEqual(capabilities(f),["list_training_entries","start_training","end_training_attempt","submit_training_action","request_training_hint"])
        f.controller.reveal();XCTAssertEqual(capabilities(f),["list_training_entries","start_training","end_training_attempt"])
        // Without the tools attached, training advertises nothing (the read-only pilot contract).
        let bare=try fixture(attach:false);defer{bare.player.shutdown()};bare.controller.openLibrary();XCTAssertEqual(capabilities(bare),[])
        let list=await code{try await bare.tools.call("list_training_entries",args:[:],lease:"lease")};XCTAssertEqual(list,"UNSUPPORTED_MODE")
    }
    func testStartingNeedsTheLearnersChoiceOfTraining()async throws {
        let f=try fixture();defer{f.player.shutdown()}
        let refused=await code{try await f.tools.call("start_training",args:self.args(f,["entryId":"mate-in-one"]),lease:"lease")}
        XCTAssertEqual(refused,"LEARNER_CONSENT_REQUIRED");XCTAssertEqual(f.session.activity,.at(.practice),"the learner's game is never left")
        f.controller.openLibrary()
        let unknown=await code{try await f.tools.call("start_training",args:self.args(f,["entryId":"no-such-entry"]),lease:"lease")};XCTAssertEqual(unknown,"INVALID_ARGUMENT")
        let started=try await f.tools.call("start_training",args:args(f,["entryId":"mate-in-one"]),lease:"lease") as! [String:Any]
        XCTAssertEqual(f.session.activity,.at(.training(entry:"mate-in-one")));XCTAssertEqual((started["training"] as? [String:Any])?["entryId"] as? String,"mate-in-one")
        let list=try await f.tools.call("list_training_entries",args:[:],lease:"lease") as! [String:Any]
        XCTAssertEqual((list["entries"] as? [[String:Any]])?.count,15);XCTAssertEqual(list["resumableEntryId"] as? String,"mate-in-one")
    }
    func testStaleAttemptsAndRevisionsAreRefused()async throws {
        let f=try fixture(only:["mate-back-rank-w1"]);defer{f.player.shutdown()}
        f.controller.begin(try f.controller.prepare(entry:"mate-in-one"))
        let wrongAttempt=await code{try await f.tools.call("request_training_hint",args:self.args(f,exercise:true).merging(["attemptId":"other"]){_,n in n},lease:"lease")}
        XCTAssertEqual(wrongAttempt,"STALE_STATE")
        let old=args(f,exercise:true);f.controller.hint()
        let stale=await code{try await f.tools.call("request_training_hint",args:old.merging(["revision":f.session.revision,"requestId":"fresh"]){_,n in n},lease:"lease")}
        XCTAssertEqual(stale,"STALE_STATE","an old session revision of the attempt is refused")
        let early=await code{try await f.tools.call("end_training_attempt",args:self.args(f,["action":"next"],exercise:true),lease:"lease")};XCTAssertEqual(early,"ATTEMPT_ACTIVE")
        let oldSession=await code{try await f.tools.call("request_training_hint",args:self.args(f,exercise:true).merging(["revision":0]){_,n in n},lease:"lease")};XCTAssertEqual(oldSession,"STALE_STATE")
    }
    func testAgentHelpIsRecordedAndHintsStopBeforeTheAnswer()async throws {
        let f=try fixture(only:["mate-back-rank-w1"]);defer{f.player.shutdown()}
        f.controller.openLibrary();_ = try await f.tools.call("start_training",args:args(f,["entryId":"mate-in-one"]),lease:"lease")
        for _ in 0..<2 {_ = try await f.tools.call("request_training_hint",args:args(f,exercise:true),lease:"lease")}
        let limit=await code{try await f.tools.call("request_training_hint",args:self.args(f,exercise:true),lease:"lease")}
        XCTAssertEqual(limit,"HINT_LIMIT");XCTAssertFalse(f.controller.exercise?.finished ?? true,"no tool reveals the answer")
        let result=try await f.tools.call("submit_training_action",args:args(f,["kind":"move","from":"a1","to":"a8"],exercise:true),lease:"lease") as! [String:Any]
        XCTAssertEqual((result["training"] as? [String:Any])?["status"] as? String,"correct");XCTAssertEqual((result["training"] as? [String:Any])?["assisted"] as? Bool,true)
        let summary=try XCTUnwrap(f.session.state.training?.summaries["mate-in-one"])
        XCTAssertEqual(summary.firstTryNoRecordedHelp,0);XCTAssertEqual(summary.assistedCompletions,1)
        // Even with no hint first, an agent's submission is help.
        let g=try fixture(only:["mate-back-rank-w1"]);defer{g.player.shutdown()}
        g.controller.begin(try g.controller.prepare(entry:"mate-in-one"))
        _ = try await g.tools.call("submit_training_action",args:args(g,["kind":"move","from":"a1","to":"a8"],exercise:true),lease:"lease")
        XCTAssertEqual(g.session.state.training?.summaries["mate-in-one"]?.firstTryNoRecordedHelp,0);XCTAssertEqual(g.session.state.training?.attempts.last?.recordedHelp,true)
    }
    func testResultsNeverDiscloseStoredAnswers()async throws {
        let f=try fixture(only:["mate-back-rank-w1"]);defer{f.player.shutdown()}
        f.controller.openLibrary()
        var seen=[json(try await f.tools.call("list_training_entries",args:[:],lease:"lease"))]
        seen.append(json(try await f.tools.call("start_training",args:args(f,["entryId":"mate-in-one"]),lease:"lease")))
        seen.append(json(try await f.tools.call("get_session",args:[:],lease:"lease")))
        seen.append(json(try await f.tools.call("request_training_hint",args:args(f,exercise:true),lease:"lease")))
        seen.append(json(try await f.tools.call("submit_training_action",args:args(f,["kind":"move","from":"a1","to":"a2"],exercise:true),lease:"lease")))
        let before=seen.dropLast().joined()
        for secret in ["a1a8","Ra8","expected","\"moves\""]{XCTAssertFalse(before.contains(secret),"an unfinished exercise disclosed \(secret)")}
    }
    func testGenericToolsAndVoiceCannotDriveTraining()async throws {
        let f=try fixture(only:["mate-back-rank-w1"]);defer{f.player.shutdown()}
        f.controller.begin(try f.controller.prepare(entry:"mate-in-one"))
        let annotate=await code{try await f.tools.call("show_annotation",args:self.args(f,["positionId":f.session.positionId,"arrows":[["a1","a8"]],"highlights":[]]),lease:"lease")}
        XCTAssertEqual(annotate,"UNSUPPORTED_MODE","annotations cannot mark an answer unrecorded")
        let play=await code{try await f.tools.call("play_move",args:self.args(f),lease:"lease")};XCTAssertEqual(play,"UNSUPPORTED_MODE")
        let moves=await code{try await f.tools.call("get_legal_moves",args:["sessionId":f.session.sessionId,"revision":f.session.revision],lease:"lease")};XCTAssertEqual(moves,"UNSUPPORTED_MODE")
        // A review over the exercise owns the board: training tools wait.
        f.session.enterReview(document:nil)
        let reviewing=await code{try await f.tools.call("request_training_hint",args:self.args(f,exercise:true),lease:"lease")};XCTAssertEqual(reviewing,"REVIEW_ACTIVE")
        // The voice coach (its own lease, exclusive with the companion) may read but never drive an exercise.
        let v=try fixture(only:["mate-back-rank-w1"]);defer{v.player.shutdown()}
        v.session.setConnection(enabled:false,role:"coach");let voice=try v.session.openVoice()
        v.controller.begin(try v.controller.prepare(entry:"mate-in-one"))
        let seized=await code{try await v.tools.call("submit_training_action",args:self.args(v,["kind":"move","from":"a1","to":"a8"],exercise:true),lease:voice)}
        XCTAssertEqual(seized,"ROLE_FORBIDDEN");XCTAssertFalse(v.controller.exercise?.finished ?? true)
        let hint=await code{try await v.tools.call("request_training_hint",args:self.args(v,exercise:true),lease:voice)};XCTAssertEqual(hint,"ROLE_FORBIDDEN")
    }
    func testToolsAndTheBoardReachTheSameResult()async throws {
        for viaTool in [false,true] {
            let f=try fixture();defer{f.player.shutdown()}
            var next:UInt64=41;f.controller.seed={next+=1;return next}
            f.controller.begin(try f.controller.prepare(entry:"find-attackers"))
            let scenario=try XCTUnwrap(f.controller.exercise?.scenario),diagram=try XCTUnwrap(scenario.diagram),target=try XCTUnwrap(scenario.target)
            let answer=diagram.keys.filter{$0 != target && diagram[$0]!.hasPrefix(scenario.learner) && TrainingGeometry.attacks(from:$0,board:diagram).contains(target)}.sorted()
            if viaTool {
                _ = try await f.tools.call("submit_training_action",args:args(f,["kind":"select","squares":answer],exercise:true),lease:"lease")
                XCTAssertFalse(f.controller.exercise?.finished ?? true,"selecting never grades")
                _ = try await f.tools.call("submit_training_action",args:args(f,["kind":answer.isEmpty ? "none":"submit"],exercise:true),lease:"lease")
            } else {for square in answer{f.controller.click(square)};f.controller.submit(none:answer.isEmpty)}
            XCTAssertEqual(f.controller.exercise?.status,.correct,"via tool: \(viaTool)");XCTAssertEqual(f.session.training?.selected ?? [],answer)
            XCTAssertEqual(f.session.training?.assisted,viaTool,"only the agent's path is recorded as help")
        }
    }
}
