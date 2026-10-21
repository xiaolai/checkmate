import XCTest
import CheckmateCore
import CheckmateTestSupport
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// A lesson's exercise is judged by replaying the learner's moves; it lives in the lesson and never in the practice game.
final class LessonAttemptTests:XCTestCase {
    private func fingerprint(_ fen:String,_ moves:[String]=[])throws -> String {let r=try ChessRules(fen:fen);for m in moves{try r.move(uci:m)};return LessonAttemptJudge.fingerprint(r.fen)}
    private let castleFEN="4k3/8/8/8/8/8/8/R3K2R w KQ - 0 1"
    private func castling()throws -> LessonPractice {
        LessonPractice(fen:castleFEN,goal:"Castle kingside.",beat:"test:0",teaching:[LessonTeachingNode(fingerprint:try fingerprint(castleFEN),accepted:["e1g1"])],checkpoints:[.init(kind:.castle,label:"Castle kingside")],opponent:.beginner,hints:["Tuck the king away.","Look at the king and the h1 rook."],offTrack:"Castle instead.",mistakes:["e1c1":"Kingside, please."],success:"You castled.")
    }
    private let lineFEN="4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"
    /// e2-e4 (answered e8-e7), then e4-e5 completes the opening; e2-e3 is refuted by e8-d7.
    private func line()throws -> LessonPractice {
        LessonPractice(fen:lineFEN,goal:"Push.",beat:"test:0",teaching:[
            LessonTeachingNode(fingerprint:try fingerprint(lineFEN),accepted:["e2e4"],replies:["e2e4":"e8e7","e2e3":"e8d7"],next:["e2e4":1]),
            LessonTeachingNode(fingerprint:try fingerprint(lineFEN,["e2e4","e8e7"]),accepted:["e4e5"])],checkpoints:[.init(kind:.graph,label:"Push twice")],opponent:.beginner,hints:["a","b"],offTrack:"Off track.",success:"Pushed.")
    }
    private func judge(_ p:LessonPractice,_ moves:[String],playOn:Bool=false)throws -> LessonAttemptJudgement {try LessonAttemptJudge.judge(p,moves:moves,playOn:playOn,rules:ChessRules())}

    // MARK: Judge
    func testCastlingIsAchievedByTheCastlingMoveOnly()throws {
        let p=try castling()
        var j=try judge(p,[]);XCTAssertEqual(j.phase,.yourTurn);XCTAssertEqual(j.done,[false]);XCTAssertEqual(j.node,0)
        j=try judge(p,["e1g1"]);XCTAssertEqual(j.phase,.achieved);XCTAssertEqual(j.done,[true]);XCTAssertTrue(j.achieved);XCTAssertEqual(j.feedback,"You castled.")
        j=try judge(p,["e1g1"],playOn:true);XCTAssertEqual(j.phase,.playingOn)
        j=try judge(p,["e1f1"]);XCTAssertEqual(j.phase,.offTrack);XCTAssertEqual(j.feedback,"Castle instead.");XCTAssertFalse(j.achieved)
        j=try judge(p,["e1c1"]);XCTAssertEqual(j.feedback,"Kingside, please.","a named mistake has its own explanation")
        XCTAssertThrowsError(try judge(p,["e1f1","e8e7"]),"nothing may follow an off-track move without an authored refutation")
        XCTAssertThrowsError(try judge(p,["e1e3"]),"an illegal move is never judged")
    }
    func testOpeningRepliesNodesAndRefutations()throws {
        let p=try line()
        var j=try judge(p,["e2e4"]);XCTAssertEqual(j.phase,.computerTurn);XCTAssertEqual(j.authoredReply,"e8e7")
        j=try judge(p,["e2e4","e8e7"]);XCTAssertEqual(j.phase,.yourTurn);XCTAssertEqual(j.node,1);XCTAssertNil(j.authoredReply)
        j=try judge(p,["e2e4","e8e7","e4e5"]);XCTAssertEqual(j.phase,.achieved);XCTAssertNil(j.node)
        XCTAssertThrowsError(try judge(p,["e2e4","e8d8"]),"a reply other than the authored one is not this definition's record")
        j=try judge(p,["e2e3"]);XCTAssertEqual(j.phase,.offTrack);XCTAssertEqual(j.authoredReply,"e8d7","the refutation is due")
        j=try judge(p,["e2e3","e8d7"]);XCTAssertEqual(j.phase,.offTrack);XCTAssertNil(j.authoredReply,"shown once")
        XCTAssertThrowsError(try judge(p,["e2e3","e8d7","e3e4"]))
    }
    func testEnPassantThenPromotionInAnyOrderAndAnExpiredChance()throws {
        let fen="6k1/5ppp/P7/3pP3/8/8/5PPP/6K1 w - d6 0 1"
        let p=LessonPractice(fen:fen,goal:"",beat:"t:0",checkpoints:[.init(kind:.enPassant,label:"Capture en passant"),.init(kind:.promote,label:"Promote")],opponent:.beginner)
        var j=try judge(p,["e5d6"]);XCTAssertEqual(j.phase,.computerTurn);XCTAssertEqual(j.done,[true,false])
        j=try judge(p,["e5d6","g8f8","a6a7","f8e8","a7a8n"]);XCTAssertEqual(j.phase,.achieved,"any promotion counts");XCTAssertEqual(j.done,[true,true])
        j=try judge(p,["a6a7"]);XCTAssertEqual(j.phase,.failed);XCTAssertTrue(j.feedback!.contains("en passant"))
    }
    func testMateSucceedsAndStalemateIsARecoverableFailure()throws {
        let fen="k7/8/1K6/8/8/8/7Q/8 w - - 0 1"
        let p=LessonPractice(fen:fen,goal:"",beat:"t:0",checkpoints:[.init(kind:.mate,label:"Checkmate")],opponent:.defender)
        var j=try judge(p,["h2h8"]);XCTAssertEqual(j.phase,.achieved);XCTAssertNotNil(j.ending,"the game is over: no Play on")
        j=try judge(p,["h2c7"]);XCTAssertEqual(j.phase,.failed);XCTAssertTrue(j.feedback!.hasPrefix("Stalemate"));XCTAssertTrue(j.feedback!.contains("Undo"))
    }
    func testPawnCheckpointsCountInEitherOrder()throws {
        let fen="4k3/8/8/3p4/4P3/8/6P1/4K3 w - - 0 1"
        let p=LessonPractice(fen:fen,goal:"",beat:"t:0",checkpoints:[.init(kind:.pawnAdvance,label:"Advance"),.init(kind:.pawnCapture,label:"Capture")],opponent:.beginner)
        var j=try judge(p,["e4d5"]);XCTAssertEqual(j.done,[false,true]);XCTAssertEqual(j.phase,.computerTurn)
        j=try judge(p,["e4d5","e8e7","g2g4"]);XCTAssertEqual(j.done,[true,true]);XCTAssertEqual(j.phase,.achieved)
    }
    func testCastlingBecomesImpossibleOnceTheKingMovesOutsideAnOpening()throws {
        let p=LessonPractice(fen:castleFEN,goal:"",beat:"t:0",checkpoints:[.init(kind:.castle,label:"Castle")],opponent:.beginner)
        let j=try judge(p,["e1e2"]);XCTAssertEqual(j.phase,.failed);XCTAssertTrue(j.feedback!.contains("no longer castle"))
    }
    func testAttackQueenCountsAnAttackOrAQueenThatIsGone()throws {
        let fen="4k3/8/8/3q4/8/8/8/R3K3 w - - 0 1"
        let p=LessonPractice(fen:fen,goal:"",beat:"t:0",checkpoints:[.init(kind:.attackQueen,label:"Chase the queen")],opponent:.beginner)
        XCTAssertEqual(try judge(p,["a1d1"]).phase,.achieved,"the rook on d1 attacks the queen on d5");XCTAssertEqual(try judge(p,["a1b1"]).phase,.computerTurn)
        let gone=LessonPractice(fen:"4k3/8/8/8/8/8/8/R3K3 w - - 0 1",goal:"",beat:"t:0",checkpoints:[.init(kind:.attackQueen,label:"Chase the queen")],opponent:.beginner)
        XCTAssertEqual(try judge(gone,["a1b1"]).phase,.achieved,"no queen left to chase")
    }
    func testDefinitionIDFollowsRulesNotWording()throws {
        let a=try castling(),b=LessonPractice(fen:a.fen,goal:"Other words.",beat:a.beat,teaching:a.teaching,checkpoints:a.checkpoints,opponent:a.opponent,hints:["x","y"],offTrack:"z",success:"w")
        XCTAssertEqual(a.definitionID,b.definitionID)
        let relabelled=LessonPractice(fen:a.fen,goal:a.goal,beat:a.beat,teaching:a.teaching,checkpoints:[.init(kind:.castle,label:"Tuck the king away",tactic:"x",gain:1)],opponent:a.opponent)
        XCTAssertEqual(a.definitionID,relabelled.definitionID,"a checkpoint's wording and audit-only fields do not restart a saved attempt")
        let c=LessonPractice(fen:a.fen,goal:a.goal,beat:a.beat,teaching:a.teaching,checkpoints:[.init(kind:.castle,label:"Castle kingside"),.init(kind:.mate,label:"Mate")],opponent:a.opponent)
        XCTAssertNotEqual(a.definitionID,c.definitionID)
    }

    // MARK: Controller
    @MainActor private func controller(engine:EngineService?=nil)throws -> (GameSession,LessonAttemptController) {
        let s=try GameSession(engine:engine),c=try LessonAttemptController(session:s);c.replyDelay={.zero};return (s,c)
    }
    @MainActor private func settle(_ c:LessonAttemptController)async throws {for _ in 0..<400 where c.thinking{try await Task.sleep(for:.milliseconds(5))}}
    @MainActor func testClickingCastlesSavesAndRecordsTheAchievementOnce()async throws {
        let (s,c)=try controller(),p=try castling(),practiceGame=s.rules.pgn
        c.open(lessonID:"test",practice:p);XCTAssertTrue(c.learnerToMove)
        c.click("e1");XCTAssertEqual(c.selected,"e1");XCTAssertTrue(c.destinations.contains("g1"))
        // A legal move off the opening is played, then explained: a named mistake with its own words.
        c.click("c1");XCTAssertEqual(c.phase,.offTrack);XCTAssertEqual(c.judgement?.feedback,"Kingside, please.");XCTAssertFalse(c.learnerToMove)
        c.undo();XCTAssertEqual(c.record?.moves,[])
        c.click("e1");c.click("g1");XCTAssertEqual(c.phase,.achieved);XCTAssertEqual(c.board["f1"],"wr")
        XCTAssertEqual(s.state.lessonAttempts?["test"]?.moves,["e1g1"]);XCTAssertEqual(s.state.course.practised,["test"])
        c.undo();XCTAssertEqual(c.record?.moves,[]);XCTAssertEqual(c.phase,.yourTurn);XCTAssertEqual(s.state.course.practised,["test"],"what was achieved stays achieved")
        c.click("e1");c.click("g1");XCTAssertEqual(s.state.course.practised,["test"],"recorded once")
        XCTAssertEqual(s.rules.pgn,practiceGame,"the practice game is never touched");XCTAssertTrue(s.state.practice.previousGame.isEmpty,"nor kept aside as a previous game")
        let first=c.record!.id;c.restart();XCTAssertNotEqual(c.record!.id,first);XCTAssertEqual(c.record?.moves,[])
    }
    @MainActor func testAuthoredRepliesAndAStaleReplyIsDropped()async throws {
        let (_,c)=try controller(),p=try line()
        c.open(lessonID:"line",practice:p);c.click("e2");c.click("e4")
        try await settle(c);XCTAssertEqual(c.record?.moves,["e2e4","e8e7"]);XCTAssertEqual(c.phase,.yourTurn)
        c.click("e4");c.click("e5");XCTAssertEqual(c.phase,.achieved)
        c.restart();c.replyDelay={.milliseconds(200)};c.click("e2");c.click("e4");XCTAssertTrue(c.thinking)
        c.undo();try await Task.sleep(for:.milliseconds(300));XCTAssertEqual(c.record?.moves,[],"an undone move's reply never lands")
    }
    @MainActor func testOffTrackRefutationIsShownThenUndoneTogether()async throws {
        let (_,c)=try controller(),p=try line()
        c.open(lessonID:"line",practice:p);c.click("e2");c.click("e3")
        try await settle(c);XCTAssertEqual(c.record?.moves,["e2e3","e8d7"]);XCTAssertEqual(c.phase,.offTrack);XCTAssertFalse(c.learnerToMove)
        c.undo();XCTAssertEqual(c.record?.moves,[]);XCTAssertEqual(c.phase,.yourTurn)
    }
    @MainActor func testLeavingDuringTheComputersTurnWaitsForResumeOnReturn()async throws {
        let engine=ScriptedDefender();engine.holding=true
        let (s,c)=try controller(engine:engine)
        let fen="4k3/8/8/8/8/8/4P3/4K3 w - - 0 1",p=LessonPractice(fen:fen,goal:"",beat:"t:0",checkpoints:[.init(kind:.mate,label:"Mate")],opponent:.defender)
        c.open(lessonID:"mate",practice:p);c.click("e2");c.click("e4");XCTAssertTrue(c.thinking)
        for _ in 0..<400 where engine.requests.isEmpty{try await Task.sleep(for:.milliseconds(5))};XCTAssertEqual(engine.requests.count,1,"the reply is in flight, held by the engine")
        c.suspend();XCTAssertTrue(c.waitingToResume);engine.release();try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(c.record?.moves,["e2e4"],"the suspended reply never lands")
        c.close();c.open(lessonID:"mate",practice:p);XCTAssertTrue(c.waitingToResume,"a restored computer turn waits");XCTAssertEqual(engine.requests.count,1)
        c.resume();try await settle(c);XCTAssertEqual(c.record?.moves.count,2);XCTAssertEqual(engine.requests.last?.profile,.skill(20),"the defender answers mate exercises")
        XCTAssertEqual(s.state.lessonAttempts?["mate"]?.moves.count,2)
    }
    @MainActor func testPlayOnUsesTheBeginnerOpponentAfterSuccess()async throws {
        let engine=ScriptedDefender()
        let (_,c)=try controller(engine:engine),p=try castling()
        c.open(lessonID:"test",practice:p);c.click("e1");c.click("g1");XCTAssertEqual(c.phase,.achieved);XCTAssertFalse(c.thinking,"no reply until the learner chooses to play on")
        c.playOn();try await settle(c);XCTAssertEqual(c.record?.moves.count,2);XCTAssertEqual(c.phase,.playingOn);XCTAssertTrue(c.learnerToMove)
    }
    @MainActor func testAChangedDefinitionStartsAgainAndAnUnreplayableRecordToo()throws {
        let (s,c)=try controller(),p=try castling()
        s.state.lessonAttempts=["test":LessonAttemptRecord(definition:"old",moves:["e1g1"])]
        c.open(lessonID:"test",practice:p);XCTAssertEqual(c.record?.moves,[]);XCTAssertTrue(c.notice!.contains("changed"))
        c.close();s.state.lessonAttempts=["test":LessonAttemptRecord(definition:p.definitionID,moves:["e1e5"])]
        c.open(lessonID:"test",practice:p);XCTAssertEqual(c.record?.moves,[]);XCTAssertTrue(c.notice!.contains("could not be replayed"))
    }
    @MainActor func testHintsAreStagedAndTheThirdShowsTheOpeningMove()throws {
        let (_,c)=try controller(),p=try castling()
        c.open(lessonID:"test",practice:p);c.hint();XCTAssertEqual(c.hints,["Tuck the king away."]);c.hint();XCTAssertEqual(c.hints.count,2);XCTAssertTrue(c.canShowMove)
        c.hint();XCTAssertEqual(c.hintArrow,["e1","g1"]);XCTAssertEqual(c.record?.hints,3);XCTAssertTrue(c.frame.arrows.contains(["e1","g1"]))
        c.click("e1");c.click("g1");XCTAssertNil(c.hintArrow,"a played move clears the shown hint")
    }
    /// Off track, Hint only explains: the hint count and its word ladder stay where they were.
    @MainActor func testAHintOffTrackChangesNothingButExplains()throws {
        let (s,c)=try controller(),p=try castling()
        c.open(lessonID:"test",practice:p);c.hint();XCTAssertEqual(c.record?.hints,1)
        c.click("e1");c.click("c1");XCTAssertEqual(c.phase,.offTrack)
        c.hint();XCTAssertEqual(c.record?.hints,1);XCTAssertEqual(s.state.lessonAttempts?["test"]?.hints,1,"nor saved");XCTAssertNil(c.hintArrow)
        XCTAssertEqual(c.notice,"Undo your last move first, then ask again.")
        c.undo();c.hint();XCTAssertEqual(c.hints,["Tuck the king away.","Look at the king and the h1 rook."],"the word ladder goes on")
    }
    /// Success with no hint in that attempt is recorded apart from success with help; both are practised.
    @MainActor func testAnUnaidedSuccessIsRecordedApartFromAHelpedOne()throws {
        let (s,c)=try controller(),p=try castling()
        c.open(lessonID:"helped",practice:p);c.hint();c.click("e1");c.click("g1");XCTAssertEqual(c.phase,.achieved)
        XCTAssertEqual(s.state.course.practised,["helped"]);XCTAssertNil(s.state.course.unaided)
        c.restart();c.click("e1");c.click("g1");XCTAssertEqual(s.state.course.unaided,["helped"],"a fresh attempt without hints counts")
        c.close();c.open(lessonID:"alone",practice:p);c.click("e1");c.click("g1");c.undo();c.click("e1");c.click("g1")
        XCTAssertEqual(s.state.course.practised,["helped","alone"]);XCTAssertEqual(s.state.course.unaided,["helped","alone"],"recorded once")
        var bad=s.state;bad.course.unaided=(0..<201).map{"lesson-\($0)"};XCTAssertThrowsError(try StateStore.validate(bad))
    }
    /// Restart asks first only once more than the first exchange (two moves) would be lost.
    @MainActor func testRestartNeedsConfirmationOnlyAfterTheFirstExchange()async throws {
        let (_,c)=try controller(),p=try line()
        c.open(lessonID:"line",practice:p);XCTAssertFalse(c.restartNeedsConfirmation)
        c.click("e2");c.click("e4");try await settle(c);XCTAssertEqual(c.record?.moves.count,2);XCTAssertFalse(c.restartNeedsConfirmation)
        c.click("e4");c.click("e5");XCTAssertEqual(c.record?.moves.count,3);XCTAssertTrue(c.restartNeedsConfirmation)
        c.restart();XCTAssertFalse(c.restartNeedsConfirmation)
    }
    func testSavedAttemptsRoundTripAndAreBounded()throws {
        var state=ApplicationState();state.lessonAttempts=["castling":LessonAttemptRecord(definition:"abc",id:"id",moves:["e1g1"],playOn:true,hints:2)];state.course.practised=["castling"]
        let decoded=try JSONDecoder().decode(ApplicationState.self,from:JSONEncoder().encode(state))
        XCTAssertEqual(decoded.lessonAttempts,state.lessonAttempts);XCTAssertEqual(decoded.course.practised,["castling"]);XCTAssertTrue(decoded.unknownFields.isEmpty)
        try StateStore.validate(decoded)
        var bad=state;bad.lessonAttempts?["castling"]?.moves=["e1g9"];XCTAssertThrowsError(try StateStore.validate(bad))
        bad=state;bad.lessonAttempts?["castling"]?.hints=4;XCTAssertThrowsError(try StateStore.validate(bad))
        // A damaged attempt is dropped alone; the rest of the progress loads.
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as? [String:Any]);object["lessonAttempts"]=["castling":["moves":3],"pin":["definition":"d","id":"i","moves":[],"playOn":false,"hints":0]]
        let partial=try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(Array(partial.lessonAttempts!.keys),["pin"])
    }

    // MARK: Review findings
    func testARefutationThatEndsTheGameReportsTheRealResult()throws {
        let fen="rnbqkbnr/pppp1ppp/8/4p3/8/5P2/PPPPP1PP/RNBQKBNR w KQkq - 0 2"
        let p=LessonPractice(fen:fen,goal:"",beat:"t:0",teaching:[LessonTeachingNode(fingerprint:try fingerprint(fen),accepted:["e2e4"],replies:["g2g4":"d8h4"])],checkpoints:[.init(kind:.graph,label:"Develop")],opponent:.beginner,offTrack:"Not that.")
        let j=try judge(p,["g2g4","d8h4"]);XCTAssertEqual(j.phase,.failed);XCTAssertEqual(j.ending?.result,"0-1");XCTAssertTrue(j.feedback!.contains("computer won"),j.feedback!)
    }
    func testSuccessStaysAfterTheGameIsLaterLost()throws {
        let fen="r3k3/8/8/8/8/8/5PPP/4K2R w K - 0 1"
        let p=LessonPractice(fen:fen,goal:"",beat:"t:0",checkpoints:[.init(kind:.castle,label:"Castle")],opponent:.beginner,success:"Castled.")
        let j=try judge(p,["e1g1","a8a7","f1a1","a7a1"],playOn:true)
        XCTAssertTrue(j.achieved);XCTAssertEqual(j.phase,.finished);XCTAssertEqual(j.ending?.result,"0-1");XCTAssertTrue(j.feedback!.contains("computer won"))
    }
    func testAnOpeningThatDoesNotMatchItsPositionIsNeverJudged()throws {
        let p=LessonPractice(fen:castleFEN,goal:"",beat:"t:0",teaching:[LessonTeachingNode(fingerprint:"8/8/8/8/8/8/8/8 w",accepted:["e1g1"])],checkpoints:[.init(kind:.castle,label:"Castle")],opponent:.beginner)
        XCTAssertThrowsError(try judge(p,[]));XCTAssertThrowsError(try judge(p,["e1g1"]))
    }
    @MainActor func testAReviewOverTheLessonOwnsTheBoard()throws {
        let (s,c)=try controller(),p=try castling()
        s.enter(.at(.lesson(index:0)));c.open(lessonID:"test",practice:p)
        s.enter(.reviewing(ReviewVisit(document:UUID(),draft:false,returnTo:.lesson(index:0))))
        XCTAssertFalse(c.learnerToMove);c.click("e1");c.click("g1");XCTAssertEqual(c.record?.moves,[],"nothing reaches the attempt behind a review")
        c.play(from:"e1",to:"g1",promotion:nil);XCTAssertEqual(c.record?.moves,[])
        s.enter(.at(.lesson(index:0)));XCTAssertTrue(c.learnerToMove)
    }
    /// Authored hints, mistakes and off-track words describe the starting position; later decisions get general words.
    @MainActor func testAuthoredWordsDescribeOnlyTheStartingPosition()async throws {
        XCTAssertEqual(try judge(line(),["e2e3"]).feedback,"Off track.")
        let later=try judge(line(),["e2e4","e8e7","e1d2"]);XCTAssertEqual(later.phase,.offTrack);XCTAssertEqual(later.feedback,LessonAttemptJudge.laterOffTrack)
        let (_,c)=try controller(),p=try line()
        c.open(lessonID:"line",practice:p);c.hint();XCTAssertEqual(c.hints,["a"])
        c.click("e2");c.click("e4");try await settle(c);XCTAssertEqual(c.hints,[],"word hints about the start are not shown over another position")
        XCTAssertTrue(c.canShowMove);c.hint();XCTAssertEqual(c.hintArrow,["e4","e5"],"after a move, Hint shows the next move")
        c.restart();c.hint();XCTAssertEqual(c.hints,["a"])
        let (_,k)=try controller(),castle=try castling()
        k.open(lessonID:"test",practice:castle);k.click("e1");k.click("d2")
        k.undo();k.click("e1");k.click("c1");XCTAssertEqual(k.judgement?.feedback,"Kingside, please.","a mistake at the start keeps its words")
    }
    /// A promotion choice is bound to the attempt shown: leaving and returning, or undoing to an equal history, ends it.
    @MainActor func testAPromotionChoiceNeverRevivesOnAnEqualHistory()async throws {
        let (_,c)=try controller(),p=try line()
        c.open(lessonID:"line",practice:p);let offered=c.identity
        c.close();c.open(lessonID:"line",practice:p);XCTAssertEqual(c.record?.moves,[]);XCTAssertNotEqual(c.identity,offered,"left and returned")
        let returned=c.identity;c.click("e2");c.click("e4");try await settle(c);c.undo();XCTAssertEqual(c.record?.moves,[]);XCTAssertNotEqual(c.identity,returned,"undone to the same history")
    }
    /// A hidden or minimised app holds play, as Practice does: a reply that arrives meanwhile waits for Resume.
    @MainActor func testAHiddenAppHoldsTheComputersReply()async throws {
        let engine=ScriptedDefender();engine.holding=true
        let (s,c)=try controller(engine:engine)
        let p=LessonPractice(fen:lineFEN,goal:"",beat:"t:0",checkpoints:[.init(kind:.mate,label:"Mate")],opponent:.defender)
        c.open(lessonID:"mate",practice:p);c.click("e2");c.click("e4")
        for _ in 0..<400 where engine.requests.isEmpty{try await Task.sleep(for:.milliseconds(5))};XCTAssertEqual(engine.requests.count,1)
        s.setConnection(enabled:false,role:s.companionRole,suspended:true);engine.release();try await settle(c)
        XCTAssertEqual(c.record?.moves,["e2e4"],"no reply lands while the app is away");XCTAssertEqual(s.state.lessonAttempts?["mate"]?.moves,["e2e4"]);XCTAssertTrue(c.waitingToResume)
        c.resume();XCTAssertTrue(c.waitingToResume,"still away");XCTAssertEqual(engine.requests.count,1)
        s.setConnection(enabled:false,role:s.companionRole,suspended:false);c.resume();try await settle(c);XCTAssertEqual(c.record?.moves.count,2)
    }
    @MainActor func testIdentityNamesTheExactHistoryAndResetsAreAnnounced()async throws {
        let (_,c)=try controller(),p=try line();var resets=0;c.onReset={resets+=1}
        c.open(lessonID:"line",practice:p);c.click("e2");c.click("e3");try await settle(c);let offTrack=c.identity
        c.undo();c.click("e2");c.click("e4");try await settle(c)
        XCTAssertEqual(c.record?.moves.count,2);XCTAssertNotEqual(c.identity,offTrack,"the same number of moves by another route is another position")
        c.restart();XCTAssertEqual(resets,2,"undo and restart each drop queued sounds and animations")
        c.click("e2");c.clearSelection();XCTAssertNil(c.selected);c.click("e4");XCTAssertEqual(c.record?.moves,[],"a cleared selection plays nothing")
    }
    @MainActor func testARefusedDropExplainsANamedMistake()throws {
        let (_,c)=try controller(),p=LessonPractice(fen:"r2q1rk1/p1pnbppp/bp1ppn2/8/3PP3/2N1BN2/PPPQ1PPP/R3K2R w KQ - 2 10",goal:"",beat:"t:0",checkpoints:[.init(kind:.castle,label:"Castle")],opponent:.beginner,mistakes:["e1g1":"The bishop covers f1."])
        c.open(lessonID:"rules",practice:p);c.click("e1");XCTAssertFalse(c.destinations.contains("g1"),"fixture: kingside castling is illegal here")
        c.refused(from:"e1",to:"g1");XCTAssertEqual(c.notice,"The bishop covers f1.");XCTAssertEqual(c.record?.moves,[])
        c.click("g1");XCTAssertEqual(c.notice,"The bishop covers f1.","a click explains it the same way")
    }
    @MainActor func testAnEngineFailurePausesAndResumeRetries()async throws {
        let engine=ScriptedDefender();engine.failure=CheckmateError.unavailable("down")
        let (_,c)=try controller(engine:engine),p=LessonPractice(fen:"4k3/8/8/8/8/8/4P3/4K3 w - - 0 1",goal:"",beat:"t:0",checkpoints:[.init(kind:.mate,label:"Mate")],opponent:.defender)
        c.open(lessonID:"mate",practice:p);c.click("e2");c.click("e4");try await settle(c)
        XCTAssertTrue(c.waitingToResume);XCTAssertTrue(c.notice!.contains("Resume"));XCTAssertEqual(c.record?.moves,["e2e4"],"a failed reply is never a move")
        engine.failure=nil;c.resume();try await settle(c);XCTAssertEqual(c.record?.moves.count,2);XCTAssertFalse(c.waitingToResume)
    }
    @MainActor func testOpeningAnExerciseSavesNothingUntilTheLearnerPlays()throws {
        let (s,c)=try controller(),p=try castling()
        s.state.lessonAttempts=["test":LessonAttemptRecord(definition:"old",moves:["e1g1"])]
        c.open(lessonID:"test",practice:p);XCTAssertEqual(s.state.lessonAttempts?["test"]?.definition,"old","a replaced attempt stays until the learner plays")
        c.click("e1");c.click("g1");XCTAssertEqual(s.state.lessonAttempts?["test"]?.definition,p.definitionID)
    }
    func testUnknownAttemptFieldsAndUnreadableRecordsSurviveASave()throws {
        var state=ApplicationState();state.lessonAttempts=["castling":LessonAttemptRecord(definition:"d",id:"i",moves:[])]
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as? [String:Any])
        object["lessonAttempts"]=["castling":["definition":"d","id":"i","moves":[],"playOn":false,"hints":0,"futureEvidence":[1,2]],"pin":["version":9]]
        let decoded=try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(Array(decoded.lessonAttempts!.keys),["castling"])
        let written=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(decoded)) as? [String:Any])
        // Through JSON text, as a save writes it, so numbers compare as numbers.
        let saved=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONSerialization.data(withJSONObject:ApplicationState.merged(written,decoded.unknownFields,nested:decoded.unknownNestedFields))) as? [String:Any])
        let attempts=try XCTUnwrap(saved["lessonAttempts"] as? [String:Any])
        XCTAssertEqual((attempts["castling"] as? [String:Any])?["futureEvidence"] as? [Int],[1,2],"a newer build's field on a known record is written back")
        XCTAssertEqual((attempts["pin"] as? [String:Any])?["version"] as? Int,9,"an unreadable record is kept, not dropped")
    }
    func testAchievementsAreBoundedOnTheirOwn()throws {
        var state=ApplicationState();state.course.practised=(0..<201).map{"lesson-\($0)"}
        XCTAssertNil(state.lessonAttempts);XCTAssertThrowsError(try StateStore.validate(state))
    }
}

/// Every lesson exercise in the course, through the lesson player: its invitation step is the playable board, its
/// narration ending never leaves it, and following each authored opening reaches the opening's checkpoint.
final class LessonExerciseContentTests:XCTestCase {
    @MainActor func testEveryExerciseIsPlayableOnItsInvitationStep()async throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);defer{p.shutdown()}
        s.state.settings.autoAdvance=true;s.state.settings.pauseForPractice=false
        let lessons=p.library.lessons.indices.filter{p.library.lessons[$0].practice != nil}
        XCTAssertEqual(lessons.count,13)
        for index in lessons {
            let lesson=p.library.lessons[index],practice=try XCTUnwrap(lesson.practice)
            XCTAssertTrue(practice.playable,lesson.id);XCTAssertEqual(practice.hints?.count,2,lesson.id)
            p.openLesson(index:index,resume:false);let step=try XCTUnwrap(p.invitationStep,lesson.id)
            XCTAssertEqual(step,lesson.beats.count-1,"\(lesson.id): the exercise is the lesson's last step")
            p.seek(step:step);XCTAssertTrue(p.attemptStep,lesson.id);XCTAssertEqual(p.frame.board,try ChessRules(fen:practice.fen).board,lesson.id)
            XCTAssertEqual(s.lesson?.attempt?.phase,"yourTurn",lesson.id);XCTAssertEqual(s.lesson?.pieces,p.frame.board,"agents see the board the learner plays")
            // Narration ending over the exercise never moves on, even with auto-advance and no practice pause.
            p.play();p.advance(by:p.duration+1);XCTAssertEqual(p.lessonIndex,index,lesson.id);XCTAssertEqual(p.step,step,lesson.id)
        }
    }
    /// An exercise bound to a step with more explanation after it: narration ending over it still never leaves it.
    @MainActor func testNarrationEndingOverAnExerciseBeforeTheLastStepStaysOnIt()throws {
        var course=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("course.json"))) as? [String:Any])
        var lessons=try XCTUnwrap(course["lessons"] as? [[String:Any]]);let index=try XCTUnwrap(lessons.firstIndex{$0["id"] as? String=="castling"})
        var practice=try XCTUnwrap(lessons[index]["practice"] as? [String:Any]);let beats=try XCTUnwrap(lessons[index]["beats"] as? [[String:Any]])
        practice["beat"]=beats[beats.count-2]["id"];lessons[index]["practice"]=practice;course["lessons"]=lessons
        let library=try JSONDecoder().decode(CourseLibrary.self,from:JSONSerialization.data(withJSONObject:course))
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s,course:library);defer{p.shutdown()}
        s.state.settings.autoAdvance=true;s.state.settings.pauseForPractice=false
        p.openLesson(index:index,resume:false);let step=try XCTUnwrap(p.invitationStep);XCTAssertEqual(step,beats.count-2)
        p.seek(step:step);XCTAssertTrue(p.attemptStep);let identity=p.attempt.identity
        p.play();p.advance(by:p.duration+1)
        XCTAssertEqual(p.lessonIndex,index);XCTAssertEqual(p.step,step,"auto-advance did not leave the exercise");XCTAssertFalse(p.playing)
        XCTAssertTrue(p.attempt.active);XCTAssertEqual(p.attempt.identity,identity);XCTAssertEqual(s.lesson?.attempt?.phase,"yourTurn")
    }
    /// "Chase the queen" passes once White attacks or takes the queen, so every such exercise must start with one.
    func testEveryAttackQueenCheckpointStartsWithABlackQueen()throws {
        let library=try CourseLibrary(),chases=library.lessons.filter{$0.practice?.checkpoints?.contains{$0.kind == .attackQueen}==true}
        XCTAssertFalse(chases.isEmpty,"fixture: the course has a queen-chasing exercise")
        for lesson in chases {XCTAssertTrue(try ChessRules(fen:XCTUnwrap(lesson.practice).fen).board.values.contains("bq"),lesson.id)}
    }
    /// Continue past a skipped exercise claims only that the lesson was explored; doing the exercise claims practice.
    @MainActor func testContinuingPastASkippedExerciseIsExploredNotPractised()throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);defer{p.shutdown()}
        let index=try XCTUnwrap(p.library.lessons.firstIndex{$0.id=="castling"});XCTAssertEqual(p.status(index:index),.notStarted)
        p.openLesson(index:index,resume:false);p.seek(step:try XCTUnwrap(p.invitationStep));p.complete()
        XCTAssertEqual(p.status(index:index),.explored)
        p.click("e1");p.click("g1");XCTAssertEqual(p.attempt.phase,.achieved);XCTAssertEqual(p.status(index:index),.practised,"its puzzles are not solved yet")
    }
    @MainActor func testRestartIsANewPositionForAgentsAndEscapeClearsTheExerciseSelection()throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);defer{p.shutdown()}
        p.openLesson(index:try XCTUnwrap(p.library.lessons.firstIndex{$0.id=="castling"}),resume:false);p.seek(step:try XCTUnwrap(p.invitationStep))
        let before=s.positionId;p.attempt.restart();XCTAssertNotEqual(s.positionId,before,"annotations bound to the old attempt are dropped")
        p.click("e1");XCTAssertEqual(p.picked,["e1"]);p.clearSelection();XCTAssertNil(p.attempt.selected);XCTAssertEqual(p.picked,[])
        p.click("g1");XCTAssertEqual(p.attempt.record?.moves,[],"a cleared selection plays nothing")
    }
    @MainActor func testEveryAuthoredOpeningCanBeFollowedToItsEnd()async throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);defer{p.shutdown()}
        p.attempt.replyDelay={.zero}
        for index in p.library.lessons.indices {
            let lesson=p.library.lessons[index];guard let practice=lesson.practice,let teaching=practice.teaching,!teaching.isEmpty else{continue}
            p.openLesson(index:index,resume:false);p.seek(step:try XCTUnwrap(p.invitationStep));p.attempt.restart()
            var node=0
            while true {
                XCTAssertEqual(LessonAttemptJudge.fingerprint(p.attempt.rules.fen),teaching[node].fingerprint,"\(lesson.id) node \(node)")
                let move=try XCTUnwrap(teaching[node].accepted.first,lesson.id),from=String(move.prefix(2)),to=String(move.dropFirst(2).prefix(2))
                p.click(from);if move.count==5{p.attempt.play(from:from,to:to,promotion:String(move.suffix(1)))}else{p.click(to)}
                XCTAssertNotEqual(p.attempt.phase,.offTrack,"\(lesson.id): an accepted move was judged off track")
                guard let following=teaching[node].next?[move] else{break}
                for _ in 0..<400 where p.attempt.thinking{try await Task.sleep(for:.milliseconds(5))}
                XCTAssertEqual(p.attempt.record?.moves.last,teaching[node].replies?[move],"\(lesson.id): the authored reply was played");node=following
            }
            let graph=practice.checkpoints?.firstIndex{$0.kind == .graph}
            if let graph{XCTAssertEqual(p.attempt.judgement?.done[graph],true,"\(lesson.id): the opening checkpoint")}
            if practice.checkpoints?.count==1{XCTAssertEqual(p.attempt.phase,.achieved,lesson.id);XCTAssertTrue(s.state.course.practised?.contains(lesson.id) == true,lesson.id)}
            XCTAssertEqual(s.mode,.lesson,lesson.id)
        }
    }
}
