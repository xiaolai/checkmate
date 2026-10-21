import CheckmateAssets
import CheckmateDomain
import CheckmateRules
import CheckmateSupport
import Combine
import Foundation
/// Retry mode (R-18): the review steps through one side's costly moves in game order. In each position before one the
/// learner tries a better move, the engine judges every try, and after two tries the board shows the engine's choice.
/// It is engine help, so it never runs during a network game: joining one ends it.
@MainActor public final class ReviewRetry:ObservableObject {
    /// A try that was not good enough: the game's own move (wrong at once, with no search) or a move the engine judged.
    public enum Verdict:Equatable,Sendable {case played(String),worse(String)}
    /// `trying` counts the tries made in this position; `solved` and `revealed` carry the move shown, by its SAN.
    public enum Phase:Equatable,Sendable {case trying(tries:Int,last:Verdict?),judging(tries:Int),solved(String),revealed(String?),finished}
    public static let triesBeforeAnswer=2
    /// The costly moves, by node, in game order.
    @Published public private(set) var targets:[Int]=[]
    @Published public private(set) var index=0
    /// Nil while retry mode is off.
    @Published public private(set) var phase:Phase?
    @Published public private(set) var solved=0
    /// The side retried, nil for both.
    public private(set) var side:String?
    private let review:ReviewController,analyzer:ReviewAnalyzer
    /// Moves on with every position shown, so a judgement that returns after the learner moved on is dropped.
    private var epoch=0,documentID:UUID?,watch:AnyCancellable?
    public init(review:ReviewController,analyzer:ReviewAnalyzer){
        self.review=review;self.analyzer=analyzer
        analyzer.fairness.participation.observe{[weak self] role in if role != nil{self?.end()}}
        // Another record, or none, ends it: its targets belong to the record retried.
        watch=review.$document.sink{[weak self] document in guard let self,self.active,document?.id != self.documentID else{return};self.end()}
    }
    /// The side the learner played in their own game; nil for any other record, whose both sides are retried.
    nonisolated public static func learnerSide(_ provenance:ReviewProvenance,current:String,previous:String)->String? {switch provenance{case .currentGame:return current;case .previousGame:return previous;default:return nil}}
    public var active:Bool {phase != nil}
    public var target:Int? {targets.indices.contains(index) ? targets[index]:nil}
    /// While the learner is still looking, the engine's choice stays off the board.
    public var hidesAnswer:Bool {switch phase{case .trying,.judging:return true;default:return false}}
    /// The mistakes and blunders on the record's main line, in game order: `side`'s, or both sides' when nil.
    nonisolated public static func targets(_ d:GameDocument,losses:[Int:Double],side:String?)->[Int] {
        d.mainline.filter{id in (side==nil || d.nodes[id].side==side) && (MoveGrade(expectationLoss:losses[id]).map{$0 != .inaccuracy} ?? false)}
    }
    /// Whether retry mode can start: engine help allowed, this record analyzed, and a costly move to retry.
    public func available(side:String?)->Bool {
        guard analyzer.fairness.engineHelpAllowed,let d=review.document,analyzer.batchDocument==d.id else{return false};return !Self.targets(d,losses:analyzer.losses,side:side).isEmpty
    }
    public func start(side:String?)throws {
        try analyzer.fairness.requireEngineHelp()
        guard let d=review.document,analyzer.batchDocument==d.id else{throw CheckmateError.invalid(String(localized:"Analyze the game first.",bundle:.checkmate))}
        let found=Self.targets(d,losses:analyzer.losses,side:side);guard !found.isEmpty else{throw CheckmateError.invalid(String(localized:"This game has no mistakes to retry.",bundle:.checkmate))}
        self.side=side;documentID=d.id;targets=found;index=0;solved=0;try show()
    }
    /// The next costly move's position, or the summary after the last.
    public func next()throws {guard active else{return};index+=1;try show()}
    public func end(){epoch+=1;phase=nil;targets=[];index=0;documentID=nil}
    private func show()throws {
        epoch+=1;guard let target,let d=review.document else{phase = .finished;return}
        try review.select(d.nodes[target].parent ?? 0);phase = .trying(tries:0,last:nil)
    }
    /// A square chosen on the board while trying: the piece to move, then the square that makes it a try. Away from the
    /// retried position the board works as in any review; while a try is judged the board waits.
    public func choose(_ square:String,promotion:String="q")async throws {
        if case .judging=phase{return}
        guard case .trying=phase,let target,let d=review.document,review.branch==nil,review.nodeID==(d.nodes[target].parent ?? 0) else{try review.selectSquare(square,promotion:promotion);return}
        if let uci=review.destination(square,promotion:promotion){review.clearSelection();try await attempt(uci)}else{try review.selectSquare(square,promotion:promotion)}
    }
    /// Judges a try in the retried position. The game's own move is wrong at once; any other is searched.
    public func attempt(_ uci:String)async throws {
        try analyzer.fairness.requireEngineHelp()
        guard case .trying(let tries,_)=phase,let target,let d=review.document else{return}
        let node=d.nodes[target],parent=node.parent ?? 0,move=try d.snapshotRules(at:parent).move(uci:uci)
        if move.uci==node.uci{return try wrong(.played(move.san),tries:tries,best:nil)}
        let epoch=self.epoch;phase = .judging(tries:tries)
        let judged:ReviewAnalyzer.Judgement
        do{judged=try await analyzer.judgeAttempt(document:d,node:target,uci:move.uci)}catch{if self.epoch==epoch,active{phase = .trying(tries:tries,last:nil)};throw error}
        guard self.epoch==epoch,active else{return}
        guard let loss=judged.loss else{phase = .trying(tries:tries,last:nil);throw CheckmateError.invalid(String(localized:"This move could not be judged. Try another.",bundle:.checkmate))}
        if MoveGrade(expectationLoss:loss)==nil{solved+=1;phase = .solved(move.san);try review.previewLine([move.uci],fromNode:parent)}else{try wrong(.worse(move.san),tries:tries,best:judged.best)}
    }
    private func wrong(_ verdict:Verdict,tries:Int,best:String?)throws {
        guard tries+1>=Self.triesBeforeAnswer,let target,let d=review.document else{phase = .trying(tries:tries+1,last:verdict);return}
        let parent=d.nodes[target].parent ?? 0,answer=analyzer.bestMoves[parent] ?? best
        guard let answer else{phase = .revealed(nil);return}
        let san=try d.snapshotRules(at:parent).move(uci:answer).san;try review.previewLine([answer],fromNode:parent);phase = .revealed(san)
    }
    /// What the retry panel says now.
    public var message:String {
        guard let phase else{return ""}
        if phase == .finished{return Self.summary(solved:solved,total:targets.count)}
        guard let target,let d=review.document else{return ""};let n=d.nodes[target]
        return Self.message(phase,played:"\(n.fullmove)\(n.side=="w" ? ".":"...") \(n.san ?? "")",mover:n.side,own:side != nil)
    }
    /// `mover` is the side ("w" or "b") that played the retried move; `own` says it was the learner.
    nonisolated public static func message(_ phase:Phase,played:String,mover:String,own:Bool)->String {
        switch phase {
        case .trying(_,nil):return own ? String(localized:"You played \(played) here. Find a better move.",bundle:.checkmate):mover=="w" ? String(localized:"White played \(played) here. Find a better move.",bundle:.checkmate):String(localized:"Black played \(played) here. Find a better move.",bundle:.checkmate)
        case .trying(_,.played(let san)?):return String(localized:"\(san) is the move played in the game. Try another.",bundle:.checkmate)
        case .trying(_,.worse(let san)?):return String(localized:"\(san) is not better. Try once more.",bundle:.checkmate)
        case .judging:return String(localized:"Checking your move…",bundle:.checkmate)
        case .solved(let san):return String(localized:"\(san) is a good move here.",bundle:.checkmate)
        case .revealed(let san):return san.map{String(localized:"The engine's choice here is \($0).",bundle:.checkmate)} ?? String(localized:"The engine has no move to show here.",bundle:.checkmate)
        case .finished:return ""
        }
    }
    nonisolated public static func summary(solved:Int,total:Int)->String {String(localized:"You found a better move in \(solved) of \(total) positions.",bundle:.checkmate,comment:"Retry mode's summary: positions solved, of the positions retried")}
}
