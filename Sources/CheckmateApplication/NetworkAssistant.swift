import CheckmateDomain
import CheckmateRules
import Foundation
/// Hints in a network game (assistance plan A5, A6, A8): the one engine entry a network game opens, and only for the
/// learner whose agreed level allows hints. It analyses only the network game's own `ChessRules`, never practice's, at
/// the profile both Macs share (skill 20, one line, a fixed node count), so each side's hints come from the same engine.
///
/// A hint is asked for on the learner's own move in a running game. It is thinking time: the clock keeps running. Its
/// result is shown only if, when it arrives, the level still allows hints, participation has not changed, the game is
/// at the same revision, and it is still the learner's move; otherwise it is dropped. A hint shown flags the learner's
/// move that turn as assisted (A7). Under `guided`, a hint starts by itself at the start of each of the learner's turns.
@MainActor public final class NetworkAssistant:ObservableObject {
    /// The move suggested: its squares, for the arrow, and its SAN, for the words.
    public struct Hint:Equatable {
        public let uci:String,san:String?,automatic:Bool
        public var from:String {String(uci.prefix(2))}
        public var to:String {String(uci.dropFirst(2).prefix(2))}
    }
    public static let unavailable="A hint is unavailable. Please try again."
    @Published public private(set) var hint:Hint?
    @Published public private(set) var thinking=false
    @Published public private(set) var error:String?
    public let game:NetworkGameController,fairness:FairnessPolicy
    public var engine:EngineService?
    private var work:Task<Void,Never>?
    /// The game revision the shown hint, or the search in progress, belongs to.
    private var turn:Int?
    /// The revision whose automatic hint has already been started, so a guided turn starts one only once.
    private var automaticTurn:Int?
    /// Advances with every search started or cancelled, so a late result can only ever settle its own search.
    private var request=0
    private static let startFEN="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    public init(game:NetworkGameController,fairness:FairnessPolicy,engine:EngineService?){
        self.game=game;self.fairness=fairness;self.engine=engine
        game.onSettle={[weak self] in self?.sync()};sync()
    }
    /// The learner's own level (A1); `off` while watching or outside a game.
    public var level:NetworkAssistanceLevel {fairness.networkAssistance}
    /// The Hint button: hints allowed, the learner's move, nothing searching and no hint shown yet this turn.
    public var canAsk:Bool {level >= .hints && game.yourTurn && engine != nil && !thinking && hint==nil}
    public func ask(){start(automatic:false)}
    /// The voice coach's hint (A10): this turn's hint, searched as the Hint button's is if none is shown or searching,
    /// and shown on the board the same way, so it flags the turn as assisted (A7). Refused off the learner's move or
    /// below `hints`; a search that ends without a hint for this turn is an error.
    public func coachHint()async throws -> Hint {
        try fairness.requireNetworkHint()
        guard game.yourTurn else{throw CheckmateError.invalid("NOT_YOUR_MOVE")}
        if hint==nil,!thinking{start(automatic:false)}
        let search=work;await search?.value
        try fairness.requireNetworkHint()
        guard let hint,game.yourTurn else{throw CheckmateError.unavailable(Self.unavailable)}
        return hint
    }
    /// Follows the game after every event (A6): a hint or search from another turn, or one the level no longer allows,
    /// goes; a guided turn starts its automatic hint.
    public func sync(){
        if turn != nil,!(level >= .hints && game.yourTurn && turn==game.gameRevision){cancel()}
        if level == .guided,game.yourTurn,let revision=game.gameRevision,automaticTurn != revision{automaticTurn=revision;start(automatic:true)}
    }
    /// Stops any search and clears what is shown.
    public func cancel(){
        request+=1;work?.cancel();work=nil;turn=nil
        if hint != nil{hint=nil};if thinking{thinking=false};if error != nil{error=nil}
    }
    private func start(automatic:Bool){
        guard !thinking,hint==nil,let engine,game.yourTurn,let revision=game.gameRevision,(try? fairness.requireNetworkHint()) != nil else{return}
        let epoch=fairness.participation.epoch,records=game.rules.records
        let startFEN=records.first?.before ?? Self.startFEN,moves=records.map(\.uci)
        request+=1;let id=request
        thinking=true;error=nil;turn=revision
        work=Task{[weak self] in
            do {
                let analysis=try await engine.analyzeHistory(startFEN:startFEN,moves:moves,profile:.skill(NetworkAssistance.hintSkill),limit:.nodes(NetworkAssistance.hintNodes),multiPv:1)
                guard let self,self.request==id else{return}
                // A6 and A8, again after the await: the result is shown only to the same turn under the same terms.
                try self.fairness.requireNetworkHint()
                guard !Task.isCancelled,self.fairness.participation.epoch==epoch,self.game.gameRevision==revision,self.game.yourTurn else{return self.dropped(id)}
                guard let uci=analysis.lines.first?.pv.first ?? analysis.bestMove,self.game.rules.moves().contains(where:{$0.uci==uci}) else{throw CheckmateError.unavailable("No hint returned")}
                self.work=nil;self.thinking=false;self.hint=Hint(uci:uci,san:analysis.lines.first?.san.first,automatic:automatic);self.game.hintShown()
            }catch{
                guard let self else{return}
                guard self.request==id else{return}
                guard !Task.isCancelled,self.fairness.participation.epoch==epoch,self.fairness.networkAssistance >= .hints,self.game.gameRevision==revision else{return self.dropped(id)}
                self.work=nil;self.thinking=false;self.error=Self.unavailable
            }
        }
    }
    /// A result that arrived for another turn or under other terms: nothing of it is shown.
    private func dropped(_ id:Int){guard request==id else{return};work=nil;turn=nil;if thinking{thinking=false}}
}
