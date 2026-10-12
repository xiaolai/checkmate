import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// A real chess.js runtime that can be made to fail, to prove a fault never grades as an answer.
final class FailingChessRuntime:ChessScriptRuntime {
    private let inner:JavaScriptCoreChessRuntime
    var failing=false
    init()throws {inner=try JavaScriptCoreChessRuntime()}
    func evaluate(_ script:String)throws -> String {if failing{throw CheckmateError.unavailable("Injected runtime failure.")};return try inner.evaluate(script)}
}
/// WI-002: exact standard-chess evaluators. Every expected answer was worked out by hand on a board.
@MainActor final class TrainingLegalityTests:XCTestCase {
    func testMateInOneAcceptsEveryMateAndOnlyMates()throws {
        XCTAssertEqual(try TrainingLegality(fen:"6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1").matingMoves(),["a1a8"],"back rank")
        XCTAssertEqual(try TrainingLegality(fen:"7k/6pp/8/8/8/8/8/RR4K1 w - - 0 1").matingMoves(),["a1a8","b1b8"],"two different mates are both correct")
        XCTAssertEqual(try TrainingLegality(fen:"r5k1/8/8/8/8/8/5PPP/6K1 b - - 0 1").matingMoves(),["a8a1"],"Black mates too")
        // f8=N is the only mate: a queen on f8 gives no check, and every capture on g8 can be taken back by the king.
        let under=try TrainingLegality(fen:"6br/5Ppk/6pp/8/8/8/8/K7 w - - 0 1")
        XCTAssertEqual(try under.matingMoves(),["f7f8n"],"underpromotion")
        XCTAssertEqual(try under.grade(from:"f7",to:"f8",promotion:nil),.needsPromotion,"the learner chooses the piece; nothing is auto-queened")
        guard case .legal(let queen)=try under.grade(from:"f7",to:"f8",promotion:"q") else{return XCTFail("a legal queen promotion is still a legal move")}
        XCTAssertFalse(queen.checkmate,"but it is not mate")
        XCTAssertGreaterThan(try under.outcomes().count,1)
    }
    func testEscapeCheckGradesRawAttemptsBeforeLegalFiltering()throws {
        // Ke1 is checked along the first rank; only the knight can block, on b1 or d1.
        let block=try TrainingLegality(fen:"4k3/8/8/8/8/2N5/3PPP2/r3K3 w - - 0 1")
        XCTAssertEqual(try block.status(),.check);XCTAssertEqual(Set(try block.outcomes().map(\.uci)),["c3b1","c3d1"])
        for (move,expected) in [("c3d1",true),("c3b1",true),("e2e4",false),("e1f1",false),("c3a2",false)] {
            let grade=try block.grade(from:String(move.prefix(2)),to:String(move.suffix(2)),promotion:nil)
            if expected {guard case .legal=grade else{XCTFail(move);continue}}else{guard case .ruleError=grade else{XCTFail("\(move): \(grade)");continue}}
        }
        if case .ruleError(let reason)=try block.grade(from:"e1",to:"f1",promotion:nil){XCTAssertEqual(reason,"Your king would be attacked on f1.")}
        if case .ruleError(let reason)=try block.grade(from:"c3",to:"c5",promotion:nil){XCTAssertEqual(reason,"A knight cannot move from c3 to c5.")}
        XCTAssertEqual(try block.grade(from:"a1",to:"a2",promotion:nil),.selection("Select one of your own pieces."),"the opponent's piece is not an attempt")
        XCTAssertEqual(try block.grade(from:"e1",to:"e2",promotion:nil),.selection("That square holds your own piece."))
        // The knight on e2 is pinned by the rook on e7: blocking on g1 is a rule error; only the king can move.
        let pinned=try TrainingLegality(fen:"4k3/4r3/8/8/8/8/4N3/4K2r w - - 0 1")
        XCTAssertEqual(Set(try pinned.outcomes().map(\.uci)),["e1d2","e1f2"])
        guard case .ruleError(let reason)=try pinned.grade(from:"e2",to:"g1",promotion:nil) else{return XCTFail("a pinned block must be a wrong answer")}
        XCTAssertEqual(reason,"That move does not get your king out of check.")
        // Double check: capturing one checker with the rook is not enough.
        let double=try TrainingLegality(fen:"4k3/8/8/8/1b5R/8/8/r3K3 w - - 0 1")
        XCTAssertEqual(Set(try double.outcomes().map(\.uci)),["e1e2","e1f2"]);guard case .ruleError=try double.grade(from:"h4",to:"b4",promotion:nil) else{return XCTFail("double check")}
        // En passant removes the checking pawn.
        let passant=try TrainingLegality(fen:"8/8/8/3k4/4Pp2/8/8/4K3 b - e3 0 1")
        XCTAssertTrue(try passant.outcomes().contains{$0.uci=="f4e3" && $0.flags.contains("e")});guard case .legal=try passant.grade(from:"f4",to:"e3",promotion:nil) else{return XCTFail("en passant evasion")}
        // Castling out of check is refused with its own reason.
        let castle=try TrainingLegality(fen:"4r1k1/8/8/8/8/8/8/4K2R w K - 0 1")
        XCTAssertEqual(try castle.grade(from:"e1",to:"g1",promotion:nil),.ruleError("You cannot castle while your king is in check."))
    }
    func testKingDestinationsIncludeCapturesAndRespectAdjacency()throws {
        XCTAssertEqual(try TrainingLegality(fen:"k7/8/8/8/8/8/r7/4K3 w - - 0 1").kingDestinations(),["d1","f1"])
        XCTAssertEqual(try TrainingLegality(fen:"k7/8/8/8/8/8/3n4/4K3 w - - 0 1").kingDestinations(),["d1","d2","e2","f2"],"the unprotected knight can be captured; f1 is attacked")
        XCTAssertEqual(try TrainingLegality(fen:"4k3/8/8/8/8/8/8/K4R2 b - - 0 1").kingDestinations(),["d7","d8","e7"],"Black's king")
        XCTAssertEqual(try TrainingLegality(fen:"8/8/8/8/8/2k5/8/2K5 w - - 0 1").kingDestinations(),["b1","d1"],"kings never stand side by side")
    }
    func testFourWayClassificationPrecedence()throws {
        XCTAssertEqual(try TrainingLegality(fen:"R5k1/5ppp/8/8/8/8/8/6K1 b - - 1 1").status(),.checkmate)
        XCTAssertEqual(try TrainingLegality(fen:"7k/5Q2/6K1/8/8/8/8/8 b - - 0 1").status(),.stalemate)
        XCTAssertEqual(try TrainingLegality(fen:"4k3/8/8/8/8/8/8/4R1K1 b - - 0 1").status(),.check)
        XCTAssertEqual(try TrainingLegality(fen:"4k3/8/8/8/8/8/8/4K3 w - - 0 1").status(),.neither,"insufficient material is still Neither: it is none of the three")
        XCTAssertEqual(TrainingStatus.choices,["Checkmate","Stalemate","Check","Neither"])
    }
    func testInvalidPositionsAndContextAreRejected(){
        for fen in ["8/8/8/8/8/8/3kK3/8 w - - 0 1","4k3/8/8/8/8/8/8/3KK3 w - - 0 1","4k3/8/8/8/8/8/8/4K3 w - - 0","4k3/8/8/8/8/8/8/4K3 w K - 0 1","4k3/4R3/8/8/8/8/8/4K3 w - - 0 1"] {
            XCTAssertThrowsError(try TrainingLegality(fen:fen),fen)
        }
        XCTAssertThrowsError(try TrainingLegality(fen:"4k3/8/8/8/8/8/4P3/4K3 w - - 0 1",prelude:["e2e5"]),"an illegal context move fails")
        XCTAssertNoThrow(try TrainingLegality(fen:"4k3/3p4/8/4P3/8/8/8/4K3 b - - 0 1",prelude:["d7d5"]))
        XCTAssertEqual(try TrainingLegality(fen:"4k3/3p4/8/4P3/8/8/8/4K3 b - - 0 1",prelude:["d7d5"]).fen.split(separator:" ")[3],"d6","context moves create the en-passant timing")
    }
    func testRuntimeFailureNeverGrades()throws {
        let runtime=try FailingChessRuntime(),legality=try TrainingLegality(fen:"6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1",runtimeFactory:{runtime})
        runtime.failing=true
        XCTAssertThrowsError(try legality.matingMoves());XCTAssertThrowsError(try legality.status());XCTAssertThrowsError(try legality.kingDestinations())
        XCTAssertThrowsError(try legality.grade(from:"a1",to:"a8",promotion:nil),"a fault is an error, not a wrong or empty answer")
        // The convenience properties hide the same fault as "no mate": the reason training uses throwing queries.
        let other=try FailingChessRuntime(),rules=try ChessRules(fen:"R5k1/5ppp/8/8/8/8/8/6K1 b - - 1 1",runtimeFactory:{other})
        XCTAssertTrue(rules.checkmate);XCTAssertTrue(try rules.isCheckmate())
        other.failing=true;XCTAssertFalse(rules.checkmate,"the convenience property reports a fault as no mate");XCTAssertThrowsError(try rules.isCheckmate())
    }
    func testExerciseRuntimeIsIsolatedFromTheRealGame()throws {
        let session=try GameSession(engine:nil);try session.playWhite(from:"e2",to:"e4")
        let before=session.rules.fen,legality=try TrainingLegality(fen:"6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1")
        _ = try legality.matingMoves();_ = try legality.grade(from:"a1",to:"a8",promotion:nil)
        XCTAssertEqual(session.rules.fen,before,"evaluating an exercise never touches the learner's game")
        XCTAssertEqual(legality.fen,"6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1","nor the exercise's own position")
    }
    // MARK: WI-005 curated content
    /// Every published alternative is accepted and every authored wrong attempt is a rule error, re-derived here.
    func testEveryCuratedAlternativeIsAcceptedOnItsBoard()throws {
        let provider=try TrainingScenarioProvider.bundled()
        for scenario in provider.scenarios(for:"escape-check") {
            let legality=try TrainingLegality(fen:try XCTUnwrap(scenario.fen))
            for move in scenario.expected?.moves ?? [] {
                guard case .legal(let outcome)=try legality.grade(from:String(move.prefix(2)),to:String(move.dropFirst(2).prefix(2)),promotion:move.count==5 ? String(move.suffix(1)):nil) else{XCTFail("\(scenario.id): \(move) is not accepted");continue}
                let after=try TrainingLegality(fen:outcome.after).board(),king=try XCTUnwrap(after.first{$0.value==scenario.learner+"k"}?.key)
                XCTAssertTrue(TrainingGeometry.attackers(of:king,color:scenario.learner=="w" ? "b":"w",board:after).isEmpty,"\(scenario.id): \(move) leaves the king attacked")
            }
            for move in scenario.expected?.wrong ?? [] {
                guard case .ruleError=try legality.grade(from:String(move.prefix(2)),to:String(move.dropFirst(2).prefix(2)),promotion:nil) else{XCTFail("\(scenario.id): \(move) is not a rule error");continue}
            }
        }
        for scenario in provider.scenarios(for:"king-safe-squares") {
            let legality=try TrainingLegality(fen:try XCTUnwrap(scenario.fen))
            XCTAssertEqual(try legality.kingDestinations(),Set(scenario.expected?.squares ?? []),scenario.id)
            let board=try legality.board(),king=try XCTUnwrap(board.first{$0.value==scenario.learner+"k"}?.key)
            for square in TrainingGeometry.attacks(from:king,board:board) where board[square]?.first.map(String.init) != scenario.learner {
                let accepted=(scenario.expected?.squares ?? []).contains(square)
                if case .legal=try legality.grade(from:king,to:square,promotion:nil){XCTAssertTrue(accepted,"\(scenario.id): \(square) is legal but not in the answer")}else{XCTAssertFalse(accepted,"\(scenario.id): \(square) is in the answer but illegal")}
            }
        }
        for scenario in provider.scenarios(for:"mate-in-one") {
            let legality=try TrainingLegality(fen:try XCTUnwrap(scenario.fen))
            for move in scenario.expected?.moves ?? [] {
                guard case .legal(let outcome)=try legality.grade(from:String(move.prefix(2)),to:String(move.dropFirst(2).prefix(2)),promotion:move.count==5 ? String(move.suffix(1)):nil) else{XCTFail("\(scenario.id): \(move)");continue}
                XCTAssertTrue(outcome.checkmate,"\(scenario.id): \(move) is not mate")
            }
        }
    }
    /// The same position up to the approved symmetry (a file mirror, or a colour flip with ranks reversed) always shares
    /// its cluster, and a reserved cluster never appears in the practice pool.
    func testPositionClustersDoNotOverlap()throws {
        let provider=try TrainingScenarioProvider.bundled()
        func expand(_ row:Substring)->String {row.map{$0.isNumber ? String(repeating:"1",count:Int(String($0))!):String($0)}.joined()}
        func forms(_ fen:String)->Set<String> {
            let parts=fen.split(separator:" "),rows=parts[0].split(separator:"/").map(expand),turn=String(parts[1])
            guard parts[2]=="-",parts[3]=="-" else{return [rows.joined(separator:"/")+" "+turn]}
            let flipped=rows.reversed().map{String($0.map{$0.isUppercase ? Character($0.lowercased()):Character($0.uppercased())})}
            var out=Set<String>()
            for (candidate,side) in [(rows,turn),(flipped,turn=="w" ? "b":"w")] {for oriented in [candidate,candidate.map{String($0.reversed())}]{out.insert(oriented.joined(separator:"/")+" "+side)}}
            return out
        }
        for entry in ["mate-in-one","king-safe-squares","escape-check","check-mate-stalemate"] {
            let scenarios=provider.scenarios(for:entry)
            var owner:[String:String]=[:]
            for scenario in scenarios {
                let key=try XCTUnwrap(forms(try XCTUnwrap(scenario.fen)).min())
                if let cluster=owner[key]{XCTAssertEqual(cluster,scenario.cluster,"\(scenario.id) repeats a position of cluster \(cluster)")}else{owner[key]=scenario.cluster}
            }
            XCTAssertEqual(Set(scenarios.map{$0.fen ?? ""}).count,scenarios.count,"\(entry): no exact duplicates")
            XCTAssertTrue(Set(scenarios.filter{$0.reserve != true}.map(\.cluster)).isDisjoint(with:Set(scenarios.filter{$0.reserve==true}.map(\.cluster))),entry)
        }
        XCTAssertEqual(forms("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"),forms("k7/2Q5/1K6/8/8/8/8/8 b - - 0 1"),"fixture: a mirrored stalemate is the same position")
    }
}
