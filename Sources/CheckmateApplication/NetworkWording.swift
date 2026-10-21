import CheckmateAssets
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
        public func name(_ side:NetworkSide)->String {(side == .white ? white:black) ?? (side == .white ? String(localized:"White",bundle:.checkmate):String(localized:"Black",bundle:.checkmate))}
        public func subject(_ side:NetworkSide)->String {side==learner ? String(localized:"You",bundle:.checkmate):name(side)}
    }
    /// The host sheet's note on a declared start (mini-games plan D7): the game is chess from there, never a training goal.
    public static let startNote=String(localized:"The game is ordinary chess from this position: checkmate wins, and stalemate is a draw. Training goals stay in Training.",bundle:.checkmate)
    /// Under the names, in a game from a declared start.
    public static let declaredStart=String(localized:"This game starts from a set-up position.",bundle:.checkmate)
    /// The host sheet's note on a mini-game (protocol 1.3): its own rules, and no assistance.
    public static let miniGameNote=String(localized:"The game is played by the mini-game's own rules, with no assistance. Review afterwards shows what a proof search found.",bundle:.checkmate)
    /// Under the names in a mini-game, and the lobby's label: "Pawn Duel: Reach the far rank, …".
    public static func miniGame(_ kind:MiniGameKind)->String {"\(kind.title): \(kind.rules)"}
    /// A move that just landed (D10): "Ben played knight to f3", "You castled kingside", "Ana played pawn to e8,
    /// capturing a rook, promoting to a queen, check".
    public static func move(_ move:MoveRecord,players:Players)->String {
        let who=players.subject(move.color=="b" ? .black:.white)
        var text:String
        // chess.js flags: k and q castle, e captures en passant.
        if move.flags.contains("k") {text=String(localized:"\(who) castled kingside",bundle:.checkmate,comment:"A move announcement: who castled")}
        else if move.flags.contains("q") {text=String(localized:"\(who) castled queenside",bundle:.checkmate,comment:"A move announcement: who castled")}
        else {
            text=String(localized:"\(who) played \(PieceName.of(move.piece)) to \(move.to)",bundle:.checkmate,comment:"A move announcement: who, the piece, its square")
            if let captured=move.captured {text=move.flags.contains("e") ? String(localized:"\(text), capturing a \(PieceName.of(captured)) en passant",bundle:.checkmate,comment:"A move announcement, then the piece it captured en passant"):String(localized:"\(text), capturing a \(PieceName.of(captured))",bundle:.checkmate,comment:"A move announcement, then the piece it captured")}
            if let promotion=move.promotion {text=String(localized:"\(text), promoting to a \(PieceName.of(promotion))",bundle:.checkmate,comment:"A move announcement, then the piece the pawn became")}
        }
        if move.san.hasSuffix("#") {text=String(localized:"\(text), checkmate",bundle:.checkmate,comment:"A move announcement that gives checkmate")}else if move.san.hasSuffix("+") {text=String(localized:"\(text), check",bundle:.checkmate,comment:"A move announcement that gives check")}
        return text
    }
    // MARK: Assistance (assistance plan A3, A7, A12)
    /// A level as a sentence uses it: "hints on request", "no help".
    public static func phrase(_ level:NetworkAssistanceLevel)->String {switch level{case .off:return String(localized:"no help",bundle:.checkmate,comment:"Assistance level inside a sentence");case .insight:return String(localized:"board insight",bundle:.checkmate,comment:"Assistance level inside a sentence");case .hints:return String(localized:"hints on request",bundle:.checkmate,comment:"Assistance level inside a sentence");case .guided:return String(localized:"guided hints",bundle:.checkmate,comment:"Assistance level inside a sentence")}}
    /// The lobby row's badge (A12), from the TXT record and so for display only; nil for a game without assistance.
    public static func badge(_ terms:NetworkAssistance)->String? {
        if terms.handicap{return String(localized:"Handicap",bundle:.checkmate)}
        switch terms.white {case .off:return nil;case .insight:return String(localized:"Board insight",bundle:.checkmate);case .hints:return String(localized:"Hints",bundle:.checkmate);case .guided:return String(localized:"Guided",bundle:.checkmate)}
    }
    /// What the Accept sheet asks the joiner to agree to (A3), before their side is known: "Ana's game allows hints on
    /// request for both players." A handicap names the colours, which the game checks, and never a guess at "you".
    public static func offer(_ terms:NetworkAssistance,game:String)->String {
        if terms.symmetric{return String(localized:"\(game) allows \(phrase(terms.white)) for both players.",bundle:.checkmate)}
        return String(localized:"Handicap: White gets \(phrase(terms.white)), Black gets \(phrase(terms.black)). You see which side you play once you join.",bundle:.checkmate)
    }
    /// The in-game line under the names (A12): "Assistance: hints on request for both players.", "Handicap: you get
    /// hints on request; Ben gets no help." Nil for a game without assistance.
    public static func terms(_ terms:NetworkAssistance,players:Players)->String? {
        guard terms != .off else{return nil}
        if terms.symmetric{return String(localized:"Assistance: \(phrase(terms.white)) for both players.",bundle:.checkmate)}
        let white=phrase(terms.white),black=phrase(terms.black)
        switch players.learner {
        case .white?:return String(localized:"Handicap: you get \(white); \(players.name(.black)) gets \(black).",bundle:.checkmate,comment:"The learner plays White")
        case .black?:return String(localized:"Handicap: \(players.name(.white)) gets \(white); you get \(black).",bundle:.checkmate,comment:"The learner plays Black")
        case nil:return String(localized:"Handicap: \(players.name(.white)) gets \(white); \(players.name(.black)) gets \(black).",bundle:.checkmate,comment:"A spectator: White's name and help, then Black's")
        }
    }
    /// Each side's assisted moves (A7), White first: "Hints used: Ana 3 · Ben 0". Self-reported, so never "verified".
    public static func hintsUsed(_ game:NetworkPublicGame,players:Players)->String {
        String(localized:"Hints used: \(players.name(.white)) \(game.assistedMoves(by:.white)) · \(players.name(.black)) \(game.assistedMoves(by:.black))",bundle:.checkmate)
    }
    /// VoiceOver, after a move the mover made with a hint shown (A12): "Ben used a hint".
    public static func usedHint(_ side:NetworkSide,players:Players)->String {side==players.learner ? String(localized:"You used a hint",bundle:.checkmate):String(localized:"\(players.name(side)) used a hint",bundle:.checkmate)}
    /// The suggested move under the board's arrow: "Hint: Nf3", or "Guided hint: Nf3" for one a guided turn showed by
    /// itself.
    public static func hint(san:String?,uci:String,automatic:Bool)->String {let move=san ?? uci;return automatic ? String(localized:"Guided hint: \(move)",bundle:.checkmate):String(localized:"Hint: \(move)",bundle:.checkmate)}
    public static let findingHint=String(localized:"Finding a hint…",bundle:.checkmate)
    /// A verified record this Mac's rules could not show, after one more try (input stays off meanwhile).
    public static let recordUnreadable=String(localized:"This Mac couldn't show the game's latest position. Leave the game and join again.",bundle:.checkmate)
    /// The Accept sheet's title and its note under the terms (A3).
    public static func joinQuestion(_ game:String)->String {String(localized:"Join \(game)?",bundle:.checkmate)}
    public static let termsFixed=String(localized:"The assistance stays the same for the whole game, and each Mac counts the hints its player uses.",bundle:.checkmate)
    /// Remaining time at which VoiceOver announces a running clock (D10), in milliseconds.
    public static let clockThresholds=[60_000,30_000,10_000]
    /// The next announcement a clock with `remaining` milliseconds will reach, if any: the highest threshold below it.
    public static func nextClockThreshold(below remaining:Int)->Int? {clockThresholds.filter{$0<remaining}.max()}
    /// "You have 30 seconds left", "Ben has 10 seconds left".
    public static func clock(_ side:NetworkSide,threshold:Int,players:Players)->String {
        let seconds=threshold/1000
        return side==players.learner ? String(localized:"You have \(seconds) seconds left",bundle:.checkmate):String(localized:"\(players.name(side)) has \(seconds) seconds left",bundle:.checkmate)
    }
    /// How the game ended, from the learner's side of the board: "Ben resigned. You win."
    public static func result(_ outcome:NetworkOutcome,players:Players)->String {
        guard outcome.result != .draw else{
            switch outcome.termination {
            case .agreement:return String(localized:"Draw agreed.",bundle:.checkmate)
            case .stalemate:return String(localized:"Draw by stalemate.",bundle:.checkmate)
            case .repetition:return String(localized:"Draw by threefold repetition.",bundle:.checkmate)
            case .fivefold:return String(localized:"Draw by fivefold repetition.",bundle:.checkmate)
            case .fiftyMoves:return String(localized:"Draw by the fifty-move rule.",bundle:.checkmate)
            case .seventyFiveMoves:return String(localized:"Draw by the seventy-five-move rule.",bundle:.checkmate)
            case .insufficientMaterial:return String(localized:"Draw: neither side can checkmate.",bundle:.checkmate)
            // D6: the flag fell against a side that has only its king, which can never checkmate.
            case .time:return String(localized:"Time ran out against a lone king. Draw.",bundle:.checkmate)
            // A mini-game's own draws (protocol 1.3), in its rules' words.
            case .miniRepetition:return String(localized:"Draw: the same position appeared three times.",bundle:.checkmate)
            case .miniNoProgress:return String(localized:"Draw: 40 turns without a capture or pawn move.",bundle:.checkmate)
            case .unreachableTargets:return String(localized:"Draw: no remaining target can be reached.",bundle:.checkmate)
            case .checkmate,.resignation,.abandoned,.farRank,.allCaptured,.noMoves:return String(localized:"Draw.",bundle:.checkmate)
            }
        }
        let winner:NetworkSide=outcome.result == .whiteWins ? .white:.black,loser=winner.opponent
        let wins=winner==players.learner ? String(localized:"You win.",bundle:.checkmate):String(localized:"\(players.name(winner)) wins.",bundle:.checkmate)
        switch outcome.termination {
        case .checkmate:return Sentences.join(String(localized:"Checkmate.",bundle:.checkmate),wins)
        // A mini-game's own wins (protocol 1.3).
        case .farRank:return Sentences.join(String(localized:"\(players.subject(winner)) reached the far rank.",bundle:.checkmate),wins)
        case .allCaptured:return Sentences.join(String(localized:"Every piece there was to capture is taken.",bundle:.checkmate),wins)
        case .noMoves:return Sentences.join(loser==players.learner ? String(localized:"You have no move.",bundle:.checkmate):String(localized:"\(players.name(loser)) has no move.",bundle:.checkmate),wins)
        case .resignation:return Sentences.join(loser==players.learner ? String(localized:"You resigned.",bundle:.checkmate):String(localized:"\(players.name(loser)) resigned.",bundle:.checkmate),wins)
        case .time:return Sentences.join(String(localized:"\(players.subject(loser)) ran out of time.",bundle:.checkmate),wins)
        // D4: the host claimed the win after the guest stayed away past the hold.
        case .abandoned:return Sentences.join(String(localized:"\(players.subject(loser)) left the game.",bundle:.checkmate),wins)
        default:return wins
        }
    }
    /// Why the game refused a command; nothing changed.
    public static func refusal(_ reason:NetworkRejectReason)->String {
        switch reason {
        case .stale:return String(localized:"The game moved on. Try again.",bundle:.checkmate)
        case .notYourTurn:return String(localized:"It isn't your turn.",bundle:.checkmate)
        case .illegal:return String(localized:"That move isn't legal.",bundle:.checkmate)
        case .notClaimable:return String(localized:"There is no draw to claim now.",bundle:.checkmate)
        case .noOffer:return String(localized:"That draw offer is no longer open.",bundle:.checkmate)
        case .offerPending:return String(localized:"Your draw offer is still open.",bundle:.checkmate)
        case .gameOver:return String(localized:"The game is over.",bundle:.checkmate)
        case .notRunning:return String(localized:"The game waits until both players are here.",bundle:.checkmate)
        case .wrongGame,.unknown:return String(localized:"That didn't work. Try again.",bundle:.checkmate)
        }
    }
    /// Under Try Again (D8): engine help stays off while the seat can still be resumed.
    public static let seatHeld=String(localized:"Your seat is kept for you, so practice help stays off until you review this game or go back to games.",bundle:.checkmate)
    /// Assistance plan A3: the terms the guest accepted are not the game's, whichever Mac found it.
    static func assistanceChanged(_ game:String)->String {String(localized:"\(game) has different assistance than the one you accepted.",bundle:.checkmate)}
    /// What a guest or spectator reads once its game stopped for good (D9, D11), about the game by its name. A
    /// connection that never worked is "Couldn't reach Ana's game", with no guessed cause; one that worked and was
    /// lost is the game having stopped: interrupted, no result. Nil when nothing needs saying: this Mac left, or the
    /// game ended with a result.
    public static func stop(_ stop:NetworkClientStop,game:String,wasLive:Bool)->String? {
        let lost=wasLive ? String(localized:"\(game) has stopped.",bundle:.checkmate):String(localized:"Couldn't reach \(game).",bundle:.checkmate)
        switch stop {
        case .left,.finished:return nil
        case .couldNotReach,.failed:return lost
        // TLS with the typed code failed: a fact about the attempt, not a guess at the network.
        case .handshakeFailed:return String(localized:"Couldn't open \(game) with that code.",bundle:.checkmate)
        case .insecure:return String(localized:"Couldn't reach \(game) securely.",bundle:.checkmate)
        case .assistanceChanged:return Self.assistanceChanged(game)
        case .closedByHost(let reason):
            switch reason {
            case .hostLeft:return String(localized:"\(game) has stopped.",bundle:.checkmate)
            case .seatTaken:return String(localized:"Someone else is already playing in \(game).",bundle:.checkmate)
            case .gameOver:return String(localized:"\(game) is already over.",bundle:.checkmate)
            case .notAllowed:return String(localized:"\(game) doesn't allow spectators.",bundle:.checkmate)
            case .full:return String(localized:"\(game) has as many spectators as it allows.",bundle:.checkmate)
            case .protocolVersion:return String(localized:"\(game) uses a different version of Checkmate.",bundle:.checkmate)
            // Assistance plan A3: the terms the guest accepted are not the game's.
            case .assistanceChanged:return Self.assistanceChanged(game)
            case .badCredential,.replaced:return String(localized:"\(game) no longer holds your seat.",bundle:.checkmate)
            case .badSnapshot,.slow,.malformed,.timeout,.rateLimited,.busy,.leaving,.unknown:return lost
            }
        }
    }
}
