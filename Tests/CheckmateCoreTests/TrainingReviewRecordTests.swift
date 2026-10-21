import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-025 (mini-games plan D6): a finished training game opens in Review from its own start, prelude and committed
/// moves, never from the practice game, and the review leads back to the training entry.
@MainActor final class TrainingReviewRecordTests:XCTestCase {
    // Increment B is gated behind its preview flags; these tests exercise it as development does.
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    /// Black to move at move 37: Qb7 leaves the king only g8, and Qb8 is then mate.
    static let blackAt37="7K/8/6k1/8/8/8/8/1q6 b - - 0 37"
    private func play(_ controller:TrainingController,_ uci:String)async {controller.attempt(from:String(uci.prefix(2)),to:String(uci.dropFirst(2).prefix(2)),promotion:nil);await TrainingEndgameTests.settle(controller)}
    private func practiceBytes(_ session:GameSession)throws -> Data {let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(session.state.practice)}
    func testABlackToMoveGameAtMove37OpensInReviewWithItsExactStartMovesAndResult()async throws {
        let (session,player,controller)=try TrainingEndgameTests.fixture([TrainingEndgameTests.ending(Self.blackAt37,id:"ending-black-37")],defender:ScriptedDefender());defer{player.shutdown()}
        try session.playWhite(from:"e2",to:"e4")
        let practice=try practiceBytes(session),practicePGN=session.rules.pgn
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        XCTAssertThrowsError(try controller.reviewRecord(),"a game still in play is not offered for review")
        // A move taken back with its reply is not part of the game.
        await play(controller,"b1b2");controller.undo();XCTAssertEqual(controller.exercise?.line,[])
        await play(controller,"b1b7");await play(controller,"b7b8")
        let exercise=try XCTUnwrap(controller.exercise)
        XCTAssertEqual(exercise.status,.correct);XCTAssertTrue(controller.canReview(exercise));XCTAssertEqual(exercise.line,["b1b7","h8g8","b7b8"])
        let document=try XCTUnwrap(PGNImporter.parse(try controller.reviewRecord(),provenance:.trainingGame).first)
        XCTAssertEqual(document.startingFEN,Self.blackAt37);XCTAssertEqual(document.header("SetUp"),"1");XCTAssertEqual(document.header("FEN"),Self.blackAt37)
        XCTAssertEqual(document.mainline.map{document.nodes[$0].uci},["b1b7","h8g8","b7b8"])
        XCTAssertEqual(document.mainline.map{"\(document.nodes[$0].fullmove)\(document.nodes[$0].side)"},["37b","38w","38b"])
        XCTAssertEqual(document.result,"0-1");XCTAssertEqual(document.header("Event"),"Finish the Game");XCTAssertEqual(document.header("Black"),"You")
        XCTAssertEqual(document.title,"\(try XCTUnwrap(document.header("White"))) – You","a saved review is named by its players")
        XCTAssertEqual(try ReviewExplanation.make(document:document,node:document.mainline[0]).title,"37… Qb7","the review numbers moves from the start's own FEN")
        XCTAssertEqual(try practiceBytes(session),practice,"the practice game is untouched");XCTAssertEqual(session.rules.pgn,practicePGN)
    }
    func testThePreludeAndAnEndedGameAreRecordedAsPlayed()async throws {
        // White's context move is part of the record; the learner then plays Black. An ended game has no result.
        let start="6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 7"
        let scenario=TrainingScenario(id:"guided-prelude",entry:"guided-games",variant:"short-start",tier:1,cluster:"guided-prelude",learner:"b",prompt:"Play.",explanation:"Habits.",hints:["Develop."],fen:start,prelude:["h2h3"],review:TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion),check:.guidedGame,workflow:"guided-game")
        let (_,player,controller)=try TrainingEndgameTests.fixture([scenario],defender:ScriptedDefender(choose:{_ in "g1h2"}));defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"guided-games"))
        await play(controller,"h7h6");controller.endGuidedGame()
        XCTAssertEqual(controller.exercise?.status,.ended)
        let document=try XCTUnwrap(PGNImporter.parse(try controller.reviewRecord()).first)
        XCTAssertEqual(document.startingFEN,start);XCTAssertEqual(document.mainline.map{document.nodes[$0].san},["h3","h6","Kh2"]);XCTAssertEqual(document.result,"*")
        XCTAssertEqual(document.header("White"),"Gentle opponent","with position games off no opponent is recorded, and the old name stands");XCTAssertEqual(document.header("Black"),"You")
        XCTAssertNil(controller.exercise?.snapshot.boundOpponent)
    }
    /// WI-025 with position games on: a finished position game is reviewed from its scenario's start, and the review
    /// names the opponent by the level the attempt froze, as the panel does.
    func testAFinishedPositionGameIsReviewedFromItsStartNamingItsFrozenLevel()async throws {
        setenv("CHECKMATE_POSITION_GAMES","1",1);defer{unsetenv("CHECKMATE_POSITION_GAMES")}
        let start="8/4P3/8/8/8/8/k7/4K2R w - - 0 1"
        let (_,player,controller)=try PositionGameTests.fixture([PositionGameTests.game(start,goal:.promoteAndHold)],defender:ScriptedDefender());defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:PositionGameTests.entry.id))
        XCTAssertThrowsError(try controller.reviewRecord(),"a game still in play is not offered for review")
        await PositionGameTests.play(controller,"e7e8q")
        let exercise=try XCTUnwrap(controller.exercise),opponent=try XCTUnwrap(exercise.snapshot.boundOpponent,"a position game freezes its opponent")
        XCTAssertEqual(exercise.status,.correct);XCTAssertTrue(controller.canReview(exercise));XCTAssertEqual(exercise.line.count,2)
        let document=try XCTUnwrap(PGNImporter.parse(try controller.reviewRecord(),provenance:.trainingGame).first)
        XCTAssertEqual(document.startingFEN,start);XCTAssertEqual(document.header("SetUp"),"1");XCTAssertEqual(document.header("FEN"),start)
        XCTAssertEqual(document.mainline.map{document.nodes[$0].uci},exercise.line)
        XCTAssertEqual(document.header("White"),"You");XCTAssertEqual(document.header("Black"),"Opponent (\(opponent.label))")
        XCTAssertNotEqual(opponent.label,"Level not recorded");XCTAssertNotEqual(document.header("Black"),"Practice defender")
        // A frozen opponent names a guided game's and an ending's opponent too; none keeps the old names.
        var snapshot=exercise.snapshot
        snapshot.scenario=TrainingEndgameTests.ending(Self.blackAt37,id:"ending-black-37");snapshot.actions=[]
        XCTAssertEqual(try XCTUnwrap(PGNImporter.parse(Data(try TrainingReviewRecord.pgn(snapshot,title:"x").utf8)).first).header("White"),"Opponent (\(opponent.label))")
        snapshot.opponent=nil
        XCTAssertEqual(try XCTUnwrap(PGNImporter.parse(Data(try TrainingReviewRecord.pgn(snapshot,title:"x").utf8)).first).header("White"),"Practice defender")
    }
    func testAClaimedDrawIsADrawAndOtherActionsAreRefused()throws {
        XCTAssertEqual(TrainingReviewRecord.movetext(["e4","e5","Nf3"],from:"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",result:"*"),"1. e4 e5 2. Nf3 *")
        XCTAssertEqual(TrainingReviewRecord.movetext(["Qb7","Kg8"],from:Self.blackAt37,result:"*"),"37... Qb7 38. Kg8 *")
        let claimed=TrainingSessionSnapshot(id:"claimed",entry:"finish-the-game",scenario:TrainingEndgameTests.ending("7k/8/8/8/8/8/R7/4K3 w - - 0 1",variant:"krk"),freshness:"new",startedAt:Date(timeIntervalSince1970:0),actions:[.move(from:"a2",to:"b2",promotion:nil),.reply("h8g8"),.move(from:"b2",to:"a2",promotion:nil),.reply("g8h8"),.move(from:"a2",to:"b2",promotion:nil),.reply("h8g8"),.move(from:"b2",to:"a2",promotion:nil),.reply("g8h8"),.claim("threefold repetition")])
        let document=try XCTUnwrap(PGNImporter.parse(Data(try TrainingReviewRecord.pgn(claimed,title:"Finish the Game").utf8)).first)
        XCTAssertEqual(document.result,"1/2-1/2");XCTAssertEqual(document.mainline.count,8)
        XCTAssertThrowsError(try TrainingReviewRecord.committed([.reveal],learnerMovesFirst:true),"a non-game action is not a game")
        XCTAssertThrowsError(try TrainingReviewRecord.committed([.undo],learnerMovesFirst:true),"nothing to take back")
        XCTAssertEqual(try TrainingReviewRecord.committed([.reply("e2e4"),.move(from:"e7",to:"e5",promotion:nil),.reply("g1f3"),.undo],learnerMovesFirst:false),["e2e4"],"Take back keeps the opponent's first move")
        var drill=claimed;drill.scenario=TrainingScenario(id:"m1",entry:"mate-in-one",variant:"x",tier:1,cluster:"m1",learner:"w",prompt:"",explanation:"",hints:[],fen:"7k/8/6K1/8/8/8/8/1Q6 w - - 0 1")
        XCTAssertThrowsError(try TrainingReviewRecord.pgn(drill,title:"x"),"only a game is reviewed")
    }
    func testReviewCoversTheTrainingEntryAndReturnsToIt()async throws {
        let (session,player,controller)=try TrainingEndgameTests.fixture([TrainingEndgameTests.ending(Self.blackAt37,id:"ending-black-37")],defender:ScriptedDefender());defer{player.shutdown()}
        try session.playWhite(from:"e2",to:"e4")
        let practice=try practiceBytes(session),practicePGN=session.rules.pgn
        let review=ReviewController(),coordinator=WorkspaceTransitionCoordinator(session:session,learning:player,review:review);coordinator.training=controller
        func go(_ next:WorkspaceNavigation)throws {try coordinator.enter(prepared:try coordinator.prepare(next),from:session.activity.place,wasReviewing:session.activity.review != nil)}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        await play(controller,"b1b7");await play(controller,"b7b8")
        let finished=try XCTUnwrap(controller.exercise?.snapshot),saved=session.state.training
        let document=try XCTUnwrap(PGNImporter.parse(try controller.reviewRecord(),provenance:.trainingGame).first)
        try go(.review(document,saved:nil,draft:true))
        XCTAssertEqual(session.activity.review?.returnTo,.training(entry:"finish-the-game"));XCTAssertEqual(session.activity.review?.draft,true)
        XCTAssertEqual(review.document?.startingFEN,Self.blackAt37);XCTAssertEqual(try practiceBytes(session),practice,"the review does not touch the practice game")
        try go(.returnToGame)
        XCTAssertEqual(session.activity,.at(.training(entry:"finish-the-game")));XCTAssertEqual(controller.exercise?.snapshot,finished,"the finished game is shown again")
        XCTAssertEqual(session.state.training,saved,"reviewing records nothing");XCTAssertEqual(try practiceBytes(session),practice);XCTAssertEqual(session.rules.pgn,practicePGN)
    }
}
