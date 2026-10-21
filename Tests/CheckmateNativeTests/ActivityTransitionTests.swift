import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// B8.2: where the learner is is one activity value with one transition function. Each test names the finding it
/// guards (dev-docs/audits/20261011-user-routes-audit.md) and drives the app model the way the UI and agents do.
/// An engine whose replies arrive only when the test finishes them.
@MainActor private final class HeldEngine:TestEngineService {
    var continuations:[CheckedContinuation<EngineAnalysis,Error>]=[]
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {try await withCheckedThrowingContinuation{continuations.append($0)}}
    func finish(_ index:Int,_ move:String){guard continuations.indices.contains(index) else{XCTFail("no engine request \(index)");return};continuations[index].resume(returning:EngineAnalysis(bestMove:move))}
}
@MainActor final class ActivityTransitionTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func document(_ pgn:String="1. e4 e5 2. Nf3 Nc6 *")throws -> GameDocument {try PGNImporter.parse(Data(pgn.utf8))[0]}
    /// A Pawn Duel game in its lesson, with the computer's reply to the learner's first move pending.
    private func miniReplyPending(_ model:NativeModel)async throws {
        var settings=model.session.state.settings;settings.pieceDuration=0;model.session.updateSettings(settings)
        // The settings observer runs on the next main-loop turn; let it pass so it cannot re-queue a cancelled reply.
        try await Task.sleep(for:.milliseconds(100))
        model.lesson(3);model.learning.startPawnDuel();model.learning.click("g2");model.learning.click("g4")
        XCTAssertTrue(model.learning.miniThinking,"fixture: the computer's reply is pending")
    }
    private func waitForMiniReply(_ model:NativeModel,plies:Int=2)async throws {for _ in 0..<60 where model.learning.miniGame?.history.count != plies{try await Task.sleep(for:.milliseconds(50))}}

    /// PL-1: every way out of a review stops its whole-game analysis, so a practice reply never waits behind it.
    func testEveryExitFromAReviewStopsItsWholeGameAnalysis()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let exits:[(String,(NativeModel)->Void)]=[
            ("Return to game",{$0.returnToGame()}),("Practice a game",{$0.practice()}),("a lesson",{$0.lesson(0)}),
            ("Quick puzzles",{$0.puzzles()}),("Review game",{$0.showReviewWorkspace()}),
            ("Practise here",{$0.practiceFromReview();$0.confirmPracticeFork(side:"b",preset:"custom")})]
        for (name,exit) in exits {
            let d=try document();XCTAssertTrue(model.openReview(d,draft:false));model.reviewAnalyzer.startBatch(d)
            XCTAssertTrue(model.reviewAnalyzer.batchRunning(d.id),"fixture: the batch runs")
            exit(model)
            XCTAssertFalse(model.reviewAnalyzer.batchRunning(d.id),"\(name) left the whole-game analysis holding the engine")
            model.practice();model.session.cancelWork()
        }
    }

    /// SH-9: importing progress from the review workspace ends in practice on the imported game; returning afterwards
    /// never restores the activity the workspace was entered from over it.
    func testImportFromTheReviewWorkspaceEndsInPracticeOnTheImportedGame()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.lesson(0);model.showReviewWorkspace();XCTAssertTrue(model.reviewWorkspace)
        var imported=model.session.state;let game=try ChessRules();try game.restore("1. e4 *");imported.practice.pgn=game.pgn;imported.practice.fen=game.fen;imported.practice.startPly=0;imported.settings.practiceSide="w"
        _ = try model.installImport(imported)
        XCTAssertEqual(model.session.activity,.at(.practice));XCTAssertFalse(model.reviewWorkspace);XCTAssertFalse(model.session.reviewSuspended)
        XCTAssertEqual(model.session.busyReason,"opponent","Stockfish replies on the imported game")
        model.returnToGame();XCTAssertEqual(model.session.mode,.practice,"leaving afterwards restored the lesson over the imported game")
        model.session.cancelWork()
    }

    /// RV-11: the Practise-here sheet belongs to the review position it was raised for. Any transition away clears it,
    /// so it never reappears over a later review.
    func testThePractiseHereRequestEndsWithItsReview()throws {
        let model=try NativeModel();defer{model.shutdown()}
        XCTAssertTrue(model.openReview(try document()));try model.review.select(2);model.practiceFromReview();XCTAssertTrue(model.practiceForkRequested)
        model.returnToGame();XCTAssertFalse(model.practiceForkRequested,"the sheet would reappear on the next review")
        XCTAssertTrue(model.openReview(try document("1. d4 d5 *")));XCTAssertFalse(model.practiceForkRequested)
        // Replaced under the sheet (an agent's open_review): Start practice is refused and the new review stays open.
        try model.review.select(1);model.practiceFromReview();let other=try document("1. c4 e5 *");XCTAssertTrue(model.openReview(other))
        XCTAssertFalse(model.practiceForkRequested,"a review replaced under the sheet keeps its request");let history=model.session.rules.history
        model.confirmPracticeFork(side:"w",preset:"custom");XCTAssertEqual(model.review.document?.id,other.id);XCTAssertEqual(model.session.rules.history,history)
        model.returnToGame();model.session.cancelWork()
    }

    /// RV-12: a draft review, the workspace and each saved review are separate sidebar rows, so choosing Review game
    /// from a draft is a real selection change that reaches the workspace.
    func testSidebarRowsKeepTheWorkspaceDistinctFromAnOpenReview()throws {
        let saved=UUID(),draft=UUID()
        let workspace=SidebarSelection.tag(.reviewing(ReviewVisit(document:nil,draft:false,returnTo:.practice)),saved:[saved],lessonIndex:0)
        let draftTag=SidebarSelection.tag(.reviewing(ReviewVisit(document:draft,draft:true,returnTo:.practice)),saved:[saved],lessonIndex:0)
        let savedTag=SidebarSelection.tag(.reviewing(ReviewVisit(document:saved,draft:false,returnTo:.lesson(index:2))),saved:[saved],lessonIndex:2)
        XCTAssertEqual(workspace,"review");XCTAssertEqual(draftTag,"review:draft");XCTAssertEqual(savedTag,"review:"+saved.uuidString)
        XCTAssertEqual(SidebarSelection.tag(.at(.miniGame(lessonIndex:3,kind:.pawnDuel)),saved:[],lessonIndex:3),"lesson:3")
        XCTAssertEqual(SidebarSelection.tag(.at(.puzzle(id:"extra-1")),saved:[],lessonIndex:0),"puzzles")
        XCTAssertEqual(SidebarSelection.tag(.at(.practice),saved:[],lessonIndex:0),"practice")
    }

    /// LE-5: Settings' lesson picker selects what to translate or preview. It never stops the lesson playing in the
    /// main window, nor a mini-game's pending computer reply.
    func testSettingsLessonPickerLeavesTheMainWindowActivityRunning()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        try await miniReplyPending(model);model.lessonLanguages.selectedLesson=(model.lessonLanguages.selectedLesson+1)%model.learning.library.lessons.count
        try await waitForMiniReply(model);XCTAssertEqual(model.learning.miniGame?.history.count,2,"the computer's reply stalled after the Settings picker changed")
        model.lesson(0);model.learning.play();XCTAssertTrue(model.learning.playing)
        model.lessonLanguages.selectedLesson=5;XCTAssertTrue(model.learning.playing,"the Settings picker stopped the lesson in the main window")
        model.learning.pause()
    }
    /// LE-5: playing a preview stops lesson narration (one narration channel) but not a mini-game's computer reply.
    func testPlayingAPreviewKeepsAMiniGameReplyComing()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        try await miniReplyPending(model);model.lessonLanguages.playPreview?(directory.appendingPathComponent("none.wav"))
        try await waitForMiniReply(model);XCTAssertEqual(model.learning.miniGame?.history.count,2,"a preview stalled the computer's reply")
    }

    /// TX-3: the review workspace is reported to agents as the workspace, whatever it was entered from, with review
    /// tools and no practice tools; voice cannot take the session there.
    func testTheWorkspaceIsReportedAsTheWorkspaceAndRefusesVoice()throws {
        let model=try NativeModel();defer{model.shutdown()}
        for enter in [{(m:NativeModel) in m.practice()},{(m:NativeModel) in m.lesson(0)},{(m:NativeModel) in m.puzzles()}] {
            enter(model);model.showReviewWorkspace()
            let state=model.session.publicState(),capabilities=state["capabilities"] as? [String] ?? []
            XCTAssertEqual(state["mode"] as? String,"review_workspace");XCTAssertEqual((state["display"] as? [String:Any])?["activeView"] as? String,"review_workspace")
            XCTAssertTrue(capabilities.contains("open_review") && capabilities.contains("list_review_games"),"\(capabilities)")
            XCTAssertFalse(capabilities.contains("get_legal_moves") || capabilities.contains("preview_move"),"practice tools offered in the workspace: \(capabilities)")
            XCTAssertThrowsError(try model.session.openVoice(),"voice took the session in the workspace")
            XCTAssertFalse(model.voiceMayConnect,"startup voice may connect in the workspace")
            model.returnToGame();model.session.cancelWork()
        }
        model.practice();XCTAssertTrue(model.voiceMayConnect,"control: voice may connect in practice")
    }

    /// TX-4: a mini-game's pending computer reply never plays behind a review opened over it, and Return to game
    /// brings the reply back.
    func testAMiniGameReplyWaitsForTheReviewOpenedOverIt()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        try await miniReplyPending(model);XCTAssertTrue(model.openReview(try document()))
        var settings=model.session.state.settings;settings.miniOpponentProfile="beginner";model.session.updateSettings(settings)
        try await Task.sleep(for:.milliseconds(900));XCTAssertEqual(model.learning.miniGame?.history.count,1,"the computer moved behind the review")
        model.returnToGame();XCTAssertEqual(model.session.activity,.at(.miniGame(lessonIndex:3,kind:.pawnDuel)))
        try await waitForMiniReply(model);XCTAssertEqual(model.learning.miniGame?.history.count,2,"Return to game did not bring the reply back")
    }

    /// TX-5: minimising the window is away like hiding it: the MCP connection is suspended and resumes on return.
    func testMinimisingSuspendsTheConnectionLikeHiding()throws {
        let model=try NativeModel();let game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        try model.companion.enable(role:"coach");XCTAssertFalse(model.session.suspended)
        let delegate:NSWindowDelegate=game
        delegate.windowDidMiniaturize?(Notification(name:NSWindow.didMiniaturizeNotification,object:game.window))
        XCTAssertTrue(model.session.suspended,"minimising left agents and Stockfish running against a hidden board")
        delegate.windowDidDeminiaturize?(Notification(name:NSWindow.didDeminiaturizeNotification,object:game.window))
        XCTAssertFalse(model.session.suspended)
        model.setAway(true);XCTAssertTrue(model.session.suspended);model.setAway(false);XCTAssertFalse(model.session.suspended)
        model.companion.disable()
    }
    /// TX-5: going away during Try a move's analysis returns the preview to choosing, never to an analysis error.
    func testAwayDuringTryAMoveReturnsToChoosing()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        try model.companion.enable(role:"coach");try model.session.beginPreview()
        // As the board does: the second click of Try a move starts the session's own analysis work.
        try model.session.select("e2");try model.session.select("e4")
        for _ in 0..<40 where model.session.preview?.status != "analyzing"{try await Task.sleep(for:.milliseconds(5))};XCTAssertEqual(model.session.preview?.status,"analyzing","fixture: the analysis runs")
        model.setAway(true);for _ in 0..<40 where model.session.preview?.status=="analyzing"{try await Task.sleep(for:.milliseconds(25))}
        XCTAssertEqual(model.session.preview?.status,"choosing");XCTAssertNil(model.session.preview?.error)
        model.setAway(false);model.companion.disable()
    }

    /// TX-8: leaving a review with sidebar Practice keeps the game's Try a move exactly as Return to game does.
    func testPracticeFromAReviewKeepsTheGamesPresentation()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.practice();try model.session.beginPreview();let preview=model.session.preview?.id,position=model.session.positionId
        XCTAssertTrue(model.openReview(try document()));model.practice()
        XCTAssertEqual(model.session.preview?.id,preview,"Practice a game discarded the Try a move");XCTAssertEqual(model.session.positionId,position)
        model.session.closePresentation();model.session.cancelWork()
    }

    /// Check Yourself, from a finished lesson, opens that lesson's first puzzle as the puzzle activity.
    func testCheckYourselfOpensTheLessonsFirstPuzzle()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let fork=try XCTUnwrap(model.learning.library.lessons.firstIndex{$0.id=="fork"});model.lesson(fork);model.learning.pause()
        model.checkYourself(fork);XCTAssertEqual(model.session.activity,.at(.puzzle(id:"course:fork:1")));XCTAssertEqual(model.learning.topic,"The Fork")
    }
    /// Codex objection 1: the displayed puzzle is part of the activity; leaving it for a review and returning shows it again.
    func testAReviewOverAPuzzleReturnsToThatPuzzle()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.puzzles();XCTAssertEqual(model.session.activity,.at(.puzzleLibrary))
        model.learning.openPuzzle(id:"extra-1");XCTAssertEqual(model.session.activity,.at(.puzzle(id:"extra-1")));XCTAssertEqual(model.learning.activePuzzle?.id,"extra-1")
        XCTAssertTrue(model.openReview(try document()));XCTAssertEqual(model.session.activity,.reviewing(ReviewVisit(document:model.review.document?.id,draft:false,returnTo:.puzzle(id:"extra-1"))))
        model.returnToGame();XCTAssertEqual(model.session.activity,.at(.puzzle(id:"extra-1")));XCTAssertEqual(model.learning.activePuzzle?.id,"extra-1");XCTAssertEqual(model.session.lesson?.lessonId,"extra-1")
    }
    /// Codex objection 2: a lesson left for a review keeps its transcript position.
    func testAReviewOverALessonReturnsToTheSameStep()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.lesson(1);model.learning.seek(step:3);XCTAssertTrue(model.openReview(try document()))
        model.returnToGame();XCTAssertEqual(model.session.activity,.at(.lesson(index:1)));XCTAssertEqual(model.learning.step,3);XCTAssertEqual(model.session.lesson?.step,3)
    }
    /// Codex objection 4: an entry that fails leaves the source intact. A saved review whose cursor is not in its record
    /// does not close the open review it would have replaced.
    func testAFailedEntryLeavesTheOpenReviewInPlace()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let open=try document();XCTAssertTrue(model.openReview(open,draft:false));try model.review.select(2)
        let broken=try document("1. d4 d5 *"),saved=SavedReview(schemaVersion:1,document:broken,cursor:99,branches:[],updatedAt:Date())
        XCTAssertFalse(model.openReview(broken,saved:saved))
        XCTAssertEqual(model.review.document?.id,open.id,"a failed open closed the review it would have replaced");XCTAssertEqual(model.review.nodeID,2)
        XCTAssertEqual(model.session.activity,.reviewing(ReviewVisit(document:open.id,draft:false,returnTo:.practice)))
        model.returnToGame();model.session.cancelWork()
    }
    // Codex refute of the B8.2 implementation (dev-docs/audits/20261011-b8-codex-refute.md, second review): each check.
    private func settle()async{for _ in 0..<30{await Task.yield()}}
    /// 1. A navigation made while the draft question is up (an agent's call during the modal) is not overwritten by
    /// the older request when the question returns.
    func testANavigationDuringTheDraftQuestionIsNotOverwritten()throws {
        let model=try NativeModel();defer{model.shutdown()}
        XCTAssertTrue(model.openReview(try document(),draft:true));try model.review.select(1);try model.review.beginBranch();try model.review.playBranch("c7c5")
        var nested=false
        model.askAboutDraft={_ in if !nested{nested=true;model.askAboutDraft={_ in .discard};model.puzzles()};return .discard}
        XCTAssertFalse(model.returnToGame(),"the older request reported success")
        XCTAssertEqual(model.session.activity,.at(.puzzleLibrary),"the request made during the question was overwritten")
    }
    /// 2. Away pauses play whether or not the MCP broker runs: no opponent reply is computed or committed while away.
    func testAwayHoldsTheOpponentWithoutTheBroker()async throws {
        let model=try NativeModel();defer{model.shutdown()};let engine=HeldEngine();model.session.engine=engine
        XCTAssertFalse(model.companion.enabled);try model.session.playWhite(from:"e2",to:"e4");await settle();XCTAssertEqual(engine.continuations.count,1)
        model.setAway(true);XCTAssertTrue(model.session.suspended);XCTAssertFalse(model.session.busy,"the reply kept running while away")
        engine.finish(0,"e7e5");await settle();XCTAssertEqual(model.session.rules.history,["e4"],"a reply was played while away")
        model.setAway(false);await settle();XCTAssertFalse(model.session.suspended);XCTAssertEqual(engine.continuations.count,2,"returning did not resume the reply")
        engine.finish(1,"c7c5");await settle();XCTAssertEqual(model.session.rules.history,["e4","c5"])
    }
    /// 3. An import whose state cannot be written changes nothing: playback, the connection and the activity stay.
    func testAnImportThatCannotBeWrittenChangesNothing()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.lesson(0);model.learning.play();try model.companion.enable(role:"coach")
        try? FileManager.default.removeItem(at:model.store.url);try FileManager.default.createDirectory(at:model.store.url,withIntermediateDirectories:true)
        var imported=model.session.state;imported.settings.skill=imported.settings.skill==3 ? 4:3
        XCTAssertThrowsError(try model.installImport(imported))
        XCTAssertEqual(model.session.activity,.at(.lesson(index:0)));XCTAssertTrue(model.learning.playing,"a failed import stopped the lesson");XCTAssertTrue(model.companion.enabled,"a failed import disabled the connection")
        XCTAssertNotEqual(model.session.state.settings.skill,imported.settings.skill)
        model.learning.pause();model.companion.disable();try? FileManager.default.removeItem(at:model.store.url)
    }
    /// 4. Agents waiting for any change see the activity change: entering and leaving the workspace advance the cursor.
    func testActivityChangesAdvanceTheAgentCursor()throws {
        let model=try NativeModel();defer{model.shutdown()}
        var cursor=model.session.cursor;model.showReviewWorkspace();XCTAssertGreaterThan(model.session.cursor,cursor,"entering the workspace was invisible to wait_for_change")
        cursor=model.session.cursor;model.returnToGame();XCTAssertGreaterThan(model.session.cursor,cursor,"leaving the workspace was invisible to wait_for_change")
        model.session.cancelWork()
    }
    /// 5. The practice briefing is refused while the game is hidden under the workspace or a review.
    func testTheTurnBriefIsRefusedOutsidePractice()async throws {
        let model=try NativeModel();defer{model.shutdown()};model.session.setConnection(enabled:true,role:"coach",lease:"lease")
        _ = try await model.companion.tools.call("get_turn_brief",args:[:],lease:"lease")
        model.showReviewWorkspace()
        do{_ = try await model.companion.tools.call("get_turn_brief",args:[:],lease:"lease");XCTFail("the workspace gave a practice briefing")}catch{}
        XCTAssertTrue(model.openReview(try document()))
        do{_ = try await model.companion.tools.call("get_turn_brief",args:[:],lease:"lease");XCTFail("a review gave a practice briefing")}catch{}
        model.returnToGame();model.session.setConnection(enabled:false,role:"coach");model.session.cancelWork()
    }
    /// 6. The puzzle library stays the puzzle library: pausing narration or a review over it never publishes a lesson.
    func testThePuzzleLibraryProjectionSurvivesPausesAndReviews()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.puzzles();model.learning.pauseNarration()
        XCTAssertEqual(model.session.lesson?.mode,"quick_puzzle");XCTAssertEqual(model.session.lesson?.lessonId,"puzzle-library")
        XCTAssertTrue(model.openReview(try document()));model.returnToGame()
        XCTAssertEqual(model.session.activity,.at(.puzzleLibrary));XCTAssertEqual(model.session.lesson?.mode,"quick_puzzle");XCTAssertEqual(model.session.publicState()["mode"] as? String,"quick_puzzle")
    }
    /// 7. Return to game is an explicit resume outside a review too: it releases a failed restore's held reply.
    func testReturnToGameReleasesAFailedRestoreHold()async throws {
        let model=try NativeModel();defer{model.shutdown()};let engine=HeldEngine();model.session.engine=engine
        try model.session.playWhite(from:"e2",to:"e4");await settle();model.session.cancelWork()
        let broken=try document("1. d4 d5 *");XCTAssertFalse(model.openReview(broken,saved:SavedReview(schemaVersion:1,document:broken,cursor:99,branches:[],updatedAt:Date())))
        XCTAssertTrue(model.restoreResumePending,"fixture: the failed restore holds the reply")
        model.returnToGame();await settle();XCTAssertFalse(model.restoreResumePending,"Return to game kept the game paused");XCTAssertEqual(engine.continuations.count,2,"no reply after Return to game")
        engine.finish(0,"e7e5");engine.finish(1,"e7e5");await settle();model.session.cancelWork()
    }
}
