import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-003: the new-exercise reducer. Hints, reveal, undo and retries are recorded help or practice, never first-try
/// evidence; rule errors and selection corrections follow the objective's policy; a stale exercise takes no input.
@MainActor final class TrainingSessionTests:XCTestCase {
    private let day=Date(timeIntervalSince1970:1_800_000_000)
    private func fixture(scenarios:[String]?=nil)throws -> (GameSession,LearningPlayer,TrainingController) {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        var provider=try TrainingScenarioProvider.bundled()
        if let scenarios {let all=provider.catalog.entries.flatMap{provider.scenarios(for:$0.id)};provider=try TrainingScenarioProvider(catalog:provider.catalog,scenarios:all.filter{scenarios.contains($0.id)})}
        let controller=TrainingController(session:session,learning:player,provider:provider)
        var seed:UInt64=7;controller.seed={seed+=1;return seed};controller.now={[day] in day}
        controller.calendar=Calendar(identifier:.gregorian);controller.calendar.timeZone=TimeZone(identifier:"UTC")!
        return (session,player,controller)
    }
    /// Walks the drill along a shortest route, one real attempt at a time.
    private func solveDrill(_ controller:TrainingController)throws {
        for _ in 0..<16 {
            let exercise=try XCTUnwrap(controller.exercise);guard !exercise.finished,let drill=exercise.scenario.drill,let state=exercise.drillState,let left=drill.distance(from:state) else{return}
            let step=try XCTUnwrap(drill.moves(state).first{move in drill.apply(state,to:move.to).flatMap{drill.distance(from:$0)}==left-1})
            controller.attempt(from:state.square,to:step.to,promotion:nil)
        }
    }
    func testDrillSolvedFirstTryIsTheOnlyNoRecordedHelpResult()throws {
        let (session,player,controller)=try fixture();defer{player.shutdown()}
        controller.openLibrary();XCTAssertEqual(session.activity,.at(.trainingLibrary));XCTAssertEqual(session.training?.view,"library")
        controller.begin(try controller.prepare(entry:"reach-target"))
        XCTAssertEqual(session.activity,.at(.training(entry:"reach-target")));XCTAssertEqual(session.mode,.training)
        let shown=try XCTUnwrap(session.training);XCTAssertEqual(shown.view,"exercise");XCTAssertEqual(shown.status,"active");XCTAssertEqual(shown.assisted,false)
        XCTAssertNil(session.publicState()["expected"],"no hidden answer is projected")
        XCTAssertNotNil(session.state.training?.active,"an unfinished exercise is saved for Continue")
        // A move the piece cannot make is corrected, never counted.
        let start=try XCTUnwrap(controller.exercise?.drillState?.square),drill=try XCTUnwrap(controller.exercise?.scenario.drill)
        let impossible=try XCTUnwrap(["a1","h8","a8","h1","d4","e5"].first{$0 != start && !drill.moves(drill.initial).map(\.to).contains($0) && $0 != drill.target})
        controller.attempt(from:start,to:impossible,promotion:nil)
        XCTAssertEqual(controller.exercise?.movesUsed,0);XCTAssertFalse(controller.exercise?.finished ?? true);XCTAssertTrue(controller.exercise?.feedback.contains("cannot move") ?? false)
        try solveDrill(controller)
        XCTAssertEqual(controller.exercise?.status,.correct)
        let training=try XCTUnwrap(session.state.training)
        XCTAssertNil(training.active);XCTAssertEqual(training.attempts.count,1);XCTAssertTrue(training.attempts[0].firstTryNoRecordedHelp)
        XCTAssertEqual(training.summaries["reach-target"]?.firstTryNoRecordedHelp,1);XCTAssertEqual(training.summaries["reach-target"]?.days,["2027-01-15"])
        XCTAssertEqual(session.training?.status,"correct")
        // The same board again is practice: never a second first try.
        controller.retry();XCTAssertTrue(controller.exercise?.snapshot.retry ?? false);try solveDrill(controller)
        XCTAssertEqual(session.state.training?.summaries["reach-target"]?.firstTryNoRecordedHelp,1);XCTAssertEqual(session.state.training?.summaries["reach-target"]?.practiceCompletions,1)
        XCTAssertFalse(session.state.training?.attempts.last?.firstTryNoRecordedHelp ?? true)
    }
    func testHintUndoAndRevealAreRecordedHelp()throws {
        let (session,player,controller)=try fixture();defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"reach-target",tier:2))
        controller.hint();XCTAssertEqual(controller.exercise?.hintLevel,1);XCTAssertNotNil(controller.exercise?.hintText);XCTAssertEqual(session.training?.assisted,true)
        controller.hint();XCTAssertEqual(controller.exercise?.hintLevel,2);XCTAssertTrue(controller.exercise?.hintText?.contains("shortest route") ?? false)
        try solveDrill(controller)
        let summary=try XCTUnwrap(session.state.training?.summaries["reach-target"])
        XCTAssertEqual(summary.assistedCompletions,1);XCTAssertEqual(summary.firstTryNoRecordedHelp,0,"a hinted success never counts as no recorded help")
        // Undo takes back a step and is recorded help.
        controller.next();let drill=try XCTUnwrap(controller.exercise?.scenario.drill),first=try XCTUnwrap(drill.moves(drill.initial).first{$0.to != drill.target})
        controller.attempt(from:drill.start,to:first.to,promotion:nil);XCTAssertEqual(controller.exercise?.movesUsed,1)
        controller.undo();XCTAssertEqual(controller.exercise?.movesUsed,0);XCTAssertEqual(controller.exercise?.drillState,drill.initial);XCTAssertEqual(controller.exercise?.snapshot.recordedHelp,true)
        // A third hint level is the reveal: shown, finished, never a success.
        controller.hint();controller.hint();controller.hint()
        XCTAssertEqual(controller.exercise?.status,.revealed);XCTAssertNotNil(controller.exercise?.solution)
        XCTAssertEqual(session.state.training?.summaries["reach-target"]?.revealed,1);XCTAssertEqual(session.state.training?.attempts.last?.outcome,.revealed)
    }
    func testMateInOneSelectionCorrectionWrongMoveAndRightMove()throws {
        let (session,player,controller)=try fixture(scenarios:["mate-back-rank-w1"]);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"mate-in-one"))
        // Choosing an opponent's piece is a selection correction.
        controller.click("g8");XCTAssertNil(controller.exercise?.picked);XCTAssertEqual(controller.exercise?.feedback,"Select one of your own pieces.")
        // An illegal rook move is corrected, not graded (selection-correction policy).
        controller.attempt(from:"a1",to:"b2",promotion:nil);XCTAssertFalse(controller.exercise?.finished ?? true);XCTAssertEqual(controller.exercise?.snapshot.actions,[])
        // A legal move that is not mate is a valid wrong answer.
        controller.click("a1");XCTAssertEqual(controller.exercise?.picked,"a1");controller.click("a7")
        XCTAssertEqual(controller.exercise?.status,.incorrect);XCTAssertEqual(session.state.training?.summaries["mate-in-one"]?.incorrect,1)
        XCTAssertEqual(controller.exercise?.board["a7"],"wr","the wrong move is shown played")
        // Once finished, further input is ignored.
        controller.attempt(from:"a7",to:"a8",promotion:nil);XCTAssertEqual(session.state.training?.attempts.count,1)
        controller.retry();controller.attempt(from:"a1",to:"a8",promotion:nil)
        XCTAssertEqual(controller.exercise?.status,.correct);XCTAssertEqual(session.state.training?.summaries["mate-in-one"]?.practiceCompletions,1,"the same position again is practice")
    }
    func testRecognitionSelectsWithoutGradingThenSubmits()throws {
        let (session,player,controller)=try fixture();defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"find-attackers"))
        let scenario=try XCTUnwrap(controller.exercise?.scenario),diagram=try XCTUnwrap(scenario.diagram),target=try XCTUnwrap(scenario.target)
        let answer=TrainingGeometry.attackers(of:target,color:Character(scenario.learner),board:diagram)
        let wrong=try XCTUnwrap(diagram.keys.first{!answer.contains($0) && $0 != target})
        controller.click(wrong);controller.click(wrong);controller.click(wrong)
        XCTAssertEqual(controller.exercise?.selection,[wrong]);XCTAssertFalse(controller.exercise?.finished ?? true,"selecting never grades")
        XCTAssertEqual(session.training?.selected,[wrong],"the learner's own selection is visible")
        controller.clearSelection();for square in answer.sorted(){controller.click(square)}
        if answer.isEmpty{controller.submit(none:true)}else{controller.submit()}
        XCTAssertEqual(controller.exercise?.status,.correct);XCTAssertEqual(session.state.training?.attempts.last?.firstTryNoRecordedHelp,true)
        if case .submit(let squares)=session.state.training?.active?.actions.last ?? .reveal{XCTFail("finished attempts are not kept active: \(squares)")}
    }
    func testResumeReplaysTheSavedAttemptExactly()throws {
        let (session,player,controller)=try fixture();defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"reach-target",tier:3))
        let drill=try XCTUnwrap(controller.exercise?.scenario.drill),first=try XCTUnwrap(drill.moves(drill.initial).first{$0.to != drill.target})
        controller.attempt(from:drill.start,to:first.to,promotion:nil);controller.hint()
        let board=controller.exercise?.board,revision=controller.exercise?.snapshot.revision
        controller.leave();XCTAssertEqual(session.activity,.at(.trainingLibrary));XCTAssertNotNil(controller.resumable)
        // A fresh controller over the saved state resumes the same board, help and revision.
        let restored=try JSONDecoder().decode(ApplicationState.self,from:JSONEncoder().encode(session.state))
        let session2=try GameSession(engine:nil,state:restored),player2=try LearningPlayer(session:session2);defer{player2.shutdown()}
        let controller2=TrainingController(session:session2,learning:player2)
        controller2.begin(try controller2.prepareResume())
        XCTAssertEqual(controller2.exercise?.board,board);XCTAssertEqual(controller2.exercise?.movesUsed,1);XCTAssertEqual(controller2.exercise?.hintLevel,1)
        XCTAssertEqual(controller2.exercise?.snapshot.recordedHelp,true);XCTAssertGreaterThan(controller2.exercise?.snapshot.revision ?? 0,revision ?? 0)
        XCTAssertEqual(session2.state.training?.attempts.count,0,"resuming is not a new attempt")
        // An action that no longer applies fails the resume and changes nothing.
        var broken=restored;broken.training?.active?.actions.insert(.move(from:"a1",to:"h8",promotion:nil),at:0)
        let session3=try GameSession(engine:nil,state:broken),player3=try LearningPlayer(session:session3);defer{player3.shutdown()}
        let controller3=TrainingController(session:session3,learning:player3),before=session3.activity
        XCTAssertThrowsError(try controller3.prepareResume());XCTAssertEqual(session3.activity,before)
    }
    func testADrillResumeHonoursEveryTakeBack()throws {
        let (session,player,controller)=try fixture();defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"reach-target",tier:3))
        let drill=try XCTUnwrap(controller.exercise?.scenario.drill),steps=drill.moves(drill.initial).filter{$0.to != drill.target}
        XCTAssertGreaterThanOrEqual(steps.count,2,"fixture: two different first steps")
        controller.attempt(from:drill.start,to:steps[0].to,promotion:nil);controller.undo()
        controller.attempt(from:drill.start,to:steps[1].to,promotion:nil);controller.undo()
        controller.attempt(from:drill.start,to:steps[1].to,promotion:nil)
        let shown=controller.exercise?.drillState
        controller.leave()
        let restored=try JSONDecoder().decode(ApplicationState.self,from:JSONEncoder().encode(session.state))
        let session2=try GameSession(engine:nil,state:restored),player2=try LearningPlayer(session:session2);defer{player2.shutdown()}
        let controller2=TrainingController(session:session2,learning:player2)
        controller2.begin(try controller2.prepareResume())
        XCTAssertEqual(controller2.exercise?.drillState,shown);XCTAssertEqual(controller2.exercise?.movesUsed,1,"earlier take-backs are replayed, not skipped")
        // A take-back with nothing to take back fails the resume instead of crashing.
        var broken=restored;broken.training?.active?.actions=[.undo]
        let session3=try GameSession(engine:nil,state:broken),player3=try LearningPlayer(session:session3);defer{player3.shutdown()}
        XCTAssertThrowsError(try TrainingController(session:session3,learning:player3).prepareResume())
    }
    func testStartingAnotherAbandonsTheUnfinishedAttempt()throws {
        let (session,player,controller)=try fixture();defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"reach-target"));controller.leave()
        controller.begin(try controller.prepare(entry:"find-attackers"))
        XCTAssertEqual(session.state.training?.summaries["reach-target"]?.abandoned,1);XCTAssertEqual(session.state.training?.active?.entry,"find-attackers")
        XCTAssertEqual(session.state.training?.summaries["reach-target"]?.clusters,[],"an abandoned board is not a practised cluster")
    }
    func testFailedPreparationChangesNothingAndStaleInputIsIgnored()throws {
        let (session,player,controller)=try fixture(scenarios:[]);defer{player.shutdown()}
        let before=session.activity
        XCTAssertThrowsError(try controller.prepare(entry:"mate-in-one"));XCTAssertThrowsError(try controller.prepare(entry:"pawn-duel"),"legacy games open through playLegacy");XCTAssertThrowsError(try controller.prepare(entry:"no-such-entry"))
        XCTAssertEqual(session.activity,before);XCTAssertNil(session.state.training)
        controller.begin(try controller.prepare(entry:"reach-target"));let exercise=controller.exercise
        // Once the learner has moved on, the old exercise takes no input.
        player.startMini(.queenVsPawns,fromLibrary:true);XCTAssertEqual(session.mode,.training)
        controller.hint();controller.attempt(from:exercise?.drillState?.square ?? "a1",to:"a2",promotion:nil);controller.reveal()
        XCTAssertEqual(session.state.training?.active?.actions ?? [],[],"no action reached the hidden exercise")
    }
    func testReadOnlyTrainingRefusesNewWork()throws {
        let (session,player,controller)=try fixture();defer{player.shutdown()}
        session.state.trainingRaw = .object(["version":.number(9)]);session.state.trainingIssue="future"
        XCTAssertThrowsError(try controller.prepare(entry:"reach-target"));XCTAssertNil(controller.resumable)
        XCTAssertEqual(session.state.trainingRaw,.object(["version":.number(9)]))
    }
    func testReviewOverAnExerciseReturnsToIt()throws {
        let (session,player,controller)=try fixture();defer{player.shutdown()}
        let coordinator=WorkspaceTransitionCoordinator(session:session,learning:player,review:ReviewController());coordinator.training=controller
        controller.begin(try controller.prepare(entry:"reach-target"))
        session.enterReview(document:nil);XCTAssertTrue(session.reviewSuspended)
        controller.hint();XCTAssertEqual(controller.exercise?.hintLevel,0,"the review owns the board")
        try coordinator.enter(prepared:try coordinator.prepare(.returnToGame),from:.training(entry:"reach-target"),wasReviewing:true)
        XCTAssertEqual(session.activity,.at(.training(entry:"reach-target")));XCTAssertEqual(session.training?.entryId,"reach-target")
        controller.hint();XCTAssertEqual(controller.exercise?.hintLevel,1)
    }
    // MARK: WI-005 exercises
    func testEscapeCheckGradesARawIllegalAttemptAsAWrongAnswer()throws {
        let (session,player,controller)=try fixture(scenarios:["esc-pinned-defender-w1"]);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"escape-check"));let board=controller.exercise?.board
        controller.attempt(from:"e2",to:"c2",promotion:nil)
        XCTAssertEqual(controller.exercise?.status,.incorrect,"the pinned queen's capture is a rule error, graded");XCTAssertEqual(controller.exercise?.board,board,"the board does not change")
        XCTAssertEqual(session.state.training?.summaries["escape-check"]?.incorrect,1)
        controller.retry();controller.attempt(from:"e1",to:"d2",promotion:nil);XCTAssertEqual(controller.exercise?.status,.correct,"any legal escape counts")
    }
    func testKingSafeSquaresAcceptsNoneWhenTheKingHasNoMove()throws {
        let (_,player,controller)=try fixture(scenarios:["kss-no-king-move-b1"]);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"king-safe-squares"))
        XCTAssertEqual(controller.exercise?.scenario.id,"kss-no-king-move-b1","fixture: with no practice board left, the reserved board is served")
        controller.submit(none:true);XCTAssertEqual(controller.exercise?.status,.correct)
    }
    func testClassificationChoosesOneOfFourLabels()throws {
        let (session,player,controller)=try fixture(scenarios:["cls-corner-stalemate-w1"]);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"check-mate-stalemate"))
        XCTAssertEqual(session.training?.choices,TrainingStatus.choices)
        controller.choose("Checkmate");XCTAssertEqual(controller.exercise?.status,.incorrect)
        controller.retry();controller.choose("Not a label");XCTAssertFalse(controller.exercise?.finished ?? true,"an unknown label is ignored")
        controller.choose("Stalemate");XCTAssertEqual(controller.exercise?.status,.correct)
    }
}
