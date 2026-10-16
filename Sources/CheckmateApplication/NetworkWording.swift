import CheckmateDomain
import Foundation
/// Everything a network game says in words (LAN-play plan D9–D11): VoiceOver's move and clock announcements, results,
/// refusals, and each way a connection can stop. Pure, so tests check the text, never the speech.
public enum NetworkWording {
    /// Who sits where, for wording: the learner is "You", a seat nobody has taken yet is its colour.
    public struct Players:Equatable {
        public var white:String?,black:String?
        /// The side the learner plays; nil for a spectator.
        public var learner:NetworkSide?
        public init(white:String?,black:String?,learner:NetworkSide?){self.white=white;self.black=black;self.learner=learner}
        public func name(_ side:NetworkSide)->String {(side == .white ? white:black) ?? (side == .white ? "White":"Black")}
        public func subject(_ side:NetworkSide)->String {side==learner ? "You":name(side)}
    }
    static let pieces=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
    /// A move that just landed (D10): "Ben played knight to f3", "You castled kingside", "Ana played pawn to e8,
    /// capturing a rook, promoting to a queen, check".
    public static func move(_ move:MoveRecord,players:Players)->String {
        let who=players.subject(move.color=="b" ? .black:.white)
        var text:String
        // chess.js flags: k and q castle, e captures en passant.
        if move.flags.contains("k") {text="\(who) castled kingside"}
        else if move.flags.contains("q") {text="\(who) castled queenside"}
        else {
            text="\(who) played \(pieces[move.piece] ?? "a piece") to \(move.to)"
            if let captured=move.captured {text+=", capturing a \(pieces[captured] ?? "piece")"+(move.flags.contains("e") ? " en passant":"")}
            if let promotion=move.promotion {text+=", promoting to a \(pieces[promotion] ?? "piece")"}
        }
        if move.san.hasSuffix("#") {text+=", checkmate"}else if move.san.hasSuffix("+") {text+=", check"}
        return text
    }
    /// Remaining time at which VoiceOver announces a running clock (D10), in milliseconds.
    public static let clockThresholds=[60_000,30_000,10_000]
    /// The next announcement a clock with `remaining` milliseconds will reach, if any: the highest threshold below it.
    public static func nextClockThreshold(below remaining:Int)->Int? {clockThresholds.filter{$0<remaining}.max()}
    /// "You have 30 seconds left", "Ben has 10 seconds left".
    public static func clock(_ side:NetworkSide,threshold:Int,players:Players)->String {
        let seconds=threshold/1000
        return side==players.learner ? "You have \(seconds) seconds left":"\(players.name(side)) has \(seconds) seconds left"
    }
    /// How the game ended, from the learner's side of the board: "Ben resigned. You win."
    public static func result(_ outcome:NetworkOutcome,players:Players)->String {
        guard outcome.result != .draw else{
            switch outcome.termination {
            case .agreement:return "Draw agreed."
            case .stalemate:return "Draw by stalemate."
            case .repetition:return "Draw by threefold repetition."
            case .fivefold:return "Draw by fivefold repetition."
            case .fiftyMoves:return "Draw by the fifty-move rule."
            case .seventyFiveMoves:return "Draw by the seventy-five-move rule."
            case .insufficientMaterial:return "Draw: neither side can checkmate."
            // D6: the flag fell against a side that has only its king, which can never checkmate.
            case .time:return "Time ran out against a lone king. Draw."
            case .checkmate,.resignation,.abandoned:return "Draw."
            }
        }
        let winner:NetworkSide=outcome.result == .whiteWins ? .white:.black,loser=winner.opponent
        let wins=players.subject(winner)+(winner==players.learner ? " win.":" wins.")
        switch outcome.termination {
        case .checkmate:return "Checkmate. "+wins
        case .resignation:return "\(players.subject(loser)) resigned. "+wins
        case .time:return "\(players.subject(loser)) ran out of time. "+wins
        // D4: the host claimed the win after the guest stayed away past the hold.
        case .abandoned:return "\(players.subject(loser)) left the game. "+wins
        default:return wins
        }
    }
    /// Why the game refused a command; nothing changed.
    public static func refusal(_ reason:NetworkRejectReason)->String {
        switch reason {
        case .stale:return "The game moved on. Try again."
        case .notYourTurn:return "It isn't your turn."
        case .illegal:return "That move isn't legal."
        case .notClaimable:return "There is no draw to claim now."
        case .noOffer:return "That draw offer is no longer open."
        case .offerPending:return "Your draw offer is still open."
        case .gameOver:return "The game is over."
        case .notRunning:return "The game waits until both players are here."
        case .wrongGame,.unknown:return "That didn't work. Try again."
        }
    }
    /// What a guest or spectator reads once its game stopped for good (D9, D11), about the game by its name. A
    /// connection that never worked is "Couldn't reach Ana's game", with no guessed cause; one that worked and was
    /// lost is the game having stopped: interrupted, no result. Nil when nothing needs saying: this Mac left, or the
    /// game ended with a result.
    /// Under Try Again (D8): engine help stays off while the seat can still be resumed.
    public static let seatHeld="Your seat is kept for you, so practice help stays off until you review this game or go back to games."
    public static func stop(_ stop:NetworkClientStop,game:String,wasLive:Bool)->String? {
        let lost=wasLive ? "\(game) has stopped.":"Couldn't reach \(game)."
        switch stop {
        case .left,.finished:return nil
        case .couldNotReach,.failed:return lost
        // TLS with the typed code failed: a fact about the attempt, not a guess at the network.
        case .handshakeFailed:return "Couldn't open \(game) with that code."
        case .insecure:return "Couldn't reach \(game) securely."
        case .closedByHost(let reason):
            switch reason {
            case .hostLeft:return "\(game) has stopped."
            case .seatTaken:return "Someone else is already playing in \(game)."
            case .gameOver:return "\(game) is already over."
            case .notAllowed:return "\(game) doesn't allow spectators."
            case .full:return "\(game) has as many spectators as it allows."
            case .protocolVersion:return "\(game) uses a different version of Checkmate."
            case .badCredential,.replaced:return "\(game) no longer holds your seat."
            case .badSnapshot,.slow,.malformed,.timeout,.rateLimited,.busy,.leaving,.unknown:return lost
            }
        }
    }
}
