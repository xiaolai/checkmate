import XCTest
@testable import CheckmateApplication
@testable import CheckmateDomain
import CheckmateRules

/// LAN-play plan D9–D11 in words: what VoiceOver announces for moves and clocks, how a result reads from each seat,
/// and the plain wording for every way a connection stops. Pure functions: the text, never the speech.
final class NetworkWordingTests:XCTestCase {
    private let ben=NetworkWording.Players(white:"Ben",black:"Ana",learner:.black)
    /// Plays `moves` from `fen` and returns the last one as the rules recorded it.
    private func record(_ moves:[String],from fen:String?=nil)throws -> MoveRecord {
        let rules=try ChessRules(fen:fen);var last:MoveRecord?
        for move in moves{last=try rules.move(uci:move)}
        return try XCTUnwrap(last)
    }
    func testMovesReadAsSentences()throws {
        XCTAssertEqual(NetworkWording.move(try record(["g1f3"]),players:ben),"Ben played knight to f3","D10's own example")
        XCTAssertEqual(NetworkWording.move(try record(["e2e4","e7e5"]),players:ben),"You played pawn to e5","the learner's own move")
        XCTAssertEqual(NetworkWording.move(try record(["e2e4","d7d5","e4d5"]),players:ben),"Ben played pawn to d5, capturing a pawn")
        XCTAssertEqual(NetworkWording.move(try record(["e2e4","a7a6","e4e5","d7d5","e5d6"]),players:ben),"Ben played pawn to d6, capturing a pawn en passant")
        XCTAssertEqual(NetworkWording.move(try record(["e1g1"],from:"4k3/8/8/8/8/8/8/R3K2R w KQ - 0 1"),players:ben),"Ben castled kingside")
        XCTAssertEqual(NetworkWording.move(try record(["e8c8"],from:"r3k3/8/8/8/8/8/8/4K3 b q - 0 1"),players:ben),"You castled queenside")
        XCTAssertEqual(NetworkWording.move(try record(["b7a8n"],from:"r3k3/1P6/8/8/8/8/8/4K3 w - - 0 1"),players:ben),"Ben played pawn to a8, capturing a rook, promoting to a knight")
        XCTAssertEqual(NetworkWording.move(try record(["f1b5"],from:"4k3/3p4/8/8/8/8/8/4KB2 w - - 0 1"),players:ben),"Ben played bishop to b5")
        XCTAssertEqual(NetworkWording.move(try record(["f2f3","e7e5","g2g4","d8h4"]),players:ben),"You played queen to h4, checkmate")
        XCTAssertEqual(NetworkWording.move(try record(["e2e4","f7f6","d1h5"]),players:ben),"Ben played queen to h5, check")
        // A seat nobody holds yet is its colour; a spectator hears both players by name.
        XCTAssertEqual(NetworkWording.move(try record(["d2d4"]),players:.init(white:nil,black:"Ana",learner:nil)),"White played pawn to d4")
    }
    func testClocksAreAnnouncedAtSixtyThirtyAndTen(){
        XCTAssertEqual(NetworkWording.clockThresholds,[60_000,30_000,10_000])
        XCTAssertEqual(NetworkWording.nextClockThreshold(below:180_000),60_000);XCTAssertEqual(NetworkWording.nextClockThreshold(below:60_000),30_000)
        XCTAssertEqual(NetworkWording.nextClockThreshold(below:30_001),30_000);XCTAssertEqual(NetworkWording.nextClockThreshold(below:10_000),nil)
        XCTAssertEqual(NetworkWording.clock(.black,threshold:30_000,players:ben),"You have 30 seconds left")
        XCTAssertEqual(NetworkWording.clock(.white,threshold:10_000,players:ben),"Ben has 10 seconds left")
        XCTAssertEqual(NetworkWording.clock(.white,threshold:60_000,players:.init(white:"Ben",black:"Ana",learner:nil)),"Ben has 60 seconds left")
    }
    func testResultsReadFromTheLearnersSeat(){
        func result(_ result:NetworkGameResult,_ termination:NetworkTermination,_ players:NetworkWording.Players?=nil)->String {NetworkWording.result(NetworkOutcome(result:result,termination:termination),players:players ?? ben)}
        XCTAssertEqual(result(.whiteWins,.resignation),"You resigned. Ben wins.")
        XCTAssertEqual(result(.blackWins,.resignation),"Ben resigned. You win.")
        XCTAssertEqual(result(.blackWins,.checkmate),"Checkmate. You win.")
        XCTAssertEqual(result(.whiteWins,.time),"You ran out of time. Ben wins.")
        XCTAssertEqual(result(.blackWins,.abandoned),"Ben left the game. You win.")
        XCTAssertEqual(result(.whiteWins,.checkmate,.init(white:"Ben",black:"Ana",learner:nil)),"Checkmate. Ben wins.","a spectator")
        for (termination,text) in [(NetworkTermination.agreement,"Draw agreed."),(.stalemate,"Draw by stalemate."),(.repetition,"Draw by threefold repetition."),(.fivefold,"Draw by fivefold repetition."),(.fiftyMoves,"Draw by the fifty-move rule."),(.seventyFiveMoves,"Draw by the seventy-five-move rule."),(.insufficientMaterial,"Draw: neither side can checkmate."),(.time,"Time ran out against a lone king. Draw.")] {
            XCTAssertEqual(result(.draw,termination),text)
        }
    }
    /// D11: one plain sentence per stop, about the game by name; "Couldn't reach" never guesses a cause, and a game that
    /// was live and is lost has stopped (interrupted, D9).
    func testEveryStopReadsPlainly(){
        func stop(_ stop:NetworkClientStop,live:Bool=false)->String? {NetworkWording.stop(stop,game:"Ana's game",wasLive:live)}
        XCTAssertNil(stop(.left));XCTAssertNil(stop(.finished))
        XCTAssertEqual(stop(.couldNotReach),"Couldn't reach Ana's game.")
        XCTAssertEqual(stop(.couldNotReach,live:true),"Ana's game has stopped.")
        XCTAssertEqual(stop(.failed("A malformed network message.")),"Couldn't reach Ana's game.")
        XCTAssertEqual(stop(.handshakeFailed),"Couldn't open Ana's game with that code.")
        XCTAssertEqual(stop(.insecure),"Couldn't reach Ana's game securely.")
        XCTAssertEqual(stop(.closedByHost(.hostLeft)),"Ana's game has stopped.")
        XCTAssertEqual(stop(.closedByHost(.seatTaken)),"Someone else is already playing in Ana's game.")
        XCTAssertEqual(stop(.closedByHost(.notAllowed)),"Ana's game doesn't allow spectators.")
        XCTAssertEqual(stop(.closedByHost(.full)),"Ana's game has as many spectators as it allows.")
        XCTAssertEqual(stop(.closedByHost(.gameOver)),"Ana's game is already over.")
        XCTAssertEqual(stop(.closedByHost(.protocolVersion)),"Ana's game uses a different version of Checkmate.")
        XCTAssertEqual(stop(.closedByHost(.badCredential)),"Ana's game no longer holds your seat.")
        for reason in NetworkByeReason.allCases {
            let text=stop(.closedByHost(reason))
            XCTAssertNotNil(text,"\(reason)")
            for guess in ["firewall","Wi-Fi","router","permission"] {XCTAssertFalse(text!.localizedCaseInsensitiveContains(guess),"\(reason) guesses at a cause")}
        }
        for reason in NetworkRejectReason.allCases {XCTAssertFalse(NetworkWording.refusal(reason).isEmpty)}
    }
}
