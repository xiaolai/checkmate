import CheckmateDomain
import CheckmateRules
import CheckmateSupport
import Foundation
import Combine
/// The voice coach's own door into a standard-rule training game (mini-game plan D5, WI-021), behind
/// `CHECKMATE_TRAINING_VOICE`. It is not `CompanionTools`: practice's tools keep refusing every training mode, and
/// `TrainingTools` keeps refusing the voice lease. It offers the board, a short analysis, a move tried on a copy, a
/// piece's attacks and highlights; nothing plays, submits or demonstrates a move.
///
/// A connection is bound to one place and attempt (`bind`); another attempt, place or task ends it. Each response
/// carries a ticket, the attempt and its revision. Before the first disclosure of an attempt (a tool result, a
/// highlight or a spoken segment) `disclose` records the attempt's help; that save advances the revision, and the
/// adapter refreshes the responses' ticket in the same main-actor step. Any other revision change (the learner's
/// move, the defender's reply, an undo) leaves the ticket stale: what was prepared for it is dropped and asked again.
@MainActor public final class TrainingVoiceAdapter:ObservableObject {
    public typealias Exercise=TrainingController.Exercise
    /// The tools a training session offers besides speech.
    public nonisolated static let toolNames:Set<String>=["get_board","analyze_position","test_move","inspect_piece","highlight_squares"]
    /// A coaching search: Stockfish at full strength for a short think, as practice's analysis.
    static let profile=OpponentProfile.skill(20),budget=350
    /// What a connection is bound to.
    public struct Scope:Equatable {public let entry:String,attempt:String}
    /// What a response is bound to: the attempt and its revision.
    public struct Ticket:Equatable {
        public let attempt:String,revision:Int
        /// The position identity the coach's tools name.
        public var key:String {"training:\(attempt):\(revision)"}
    }
    /// The only things the coach may say in a training game without a help record: fixed, and about no position.
    public enum NeutralLine:String,CaseIterable {
        case moment="One moment.",cannotHelp="I can't help with this one.",stopped="The coach has stopped."
        public var text:String {rawValue}
    }
    /// Why a disclosure may not go ahead. `regenerate`: the board changed, so what was prepared is dropped and asked
    /// again. `wait`: the defender is choosing its reply, the one wait allowed. `refused`: the help could not be
    /// recorded, so nothing is disclosed and nothing is retried. `outOfScope`: the bound game is no longer shown.
    public enum Stop:Error,Equatable {case regenerate,wait,refused(TrainingController.AgentHelpOutcome),outOfScope}
    /// The coach's highlights on the training board, for the board they were drawn on.
    public struct Marks:Equatable {public var key:String,squares:[String],arrows:[[String]];public init(key:String="",squares:[String]=[],arrows:[[String]]=[]){self.key=key;self.squares=squares;self.arrows=arrows}}
    public let session:GameSession,controller:TrainingController
    public private(set) var scope:Scope?
    @Published public private(set) var marks=Marks()
    /// Ticket keys the adapter's own help record replaced, each with the key that replaced it: the same board.
    private var aliases:[String:String]=[:]
    /// A diagnostic sink for acceptance probes: each disclosure and tool call, with the ticket keys but never the board
    /// or the learner's text.
    public var trace:((String)->Void)?
    /// The defender-thinking wait was used by the disclosure in progress; the next refusal while it thinks ends it.
    private var waited=false
    private var search:Task<EngineAnalysis,Error>?,marksTask:Task<Void,Never>?
    /// The coaching search in progress was cancelled because the defender started.
    private var yielded=false
    private var observation:AnyCancellable?
    public init(session:GameSession,controller:TrainingController){
        self.session=session;self.controller=controller
        // The defender searches first on the shared engine: a coaching search still running when it starts is
        // cancelled, so the reply never waits behind it (`requestReply` announces the change after it starts thinking).
        observation=controller.objectWillChange.sink{[weak self] _ in guard let self,self.controller.games.thinking,let search=self.search else{return};self.yielded=true;search.cancel()}
    }
    // MARK: Scope
    /// Whether the coach may connect now: the flag, and a standard-rule training game still being played on screen.
    public var connectable:Bool {
        guard TrainingRolloutPolicy.trainingVoiceEnabled,controller.showing,!session.reviewSuspended,let exercise=controller.exercise,exercise.task == .game,!exercise.finished else{return false}
        return true
    }
    /// Binds a connection to the game shown: its place and attempt. Nothing is recorded here.
    @discardableResult public func bind()throws -> Scope {
        guard connectable,let exercise=controller.exercise else{throw ProtocolFailure("UNSUPPORTED_MODE","The voice coach connects only to a training game being played.")}
        release();let scope=Scope(entry:exercise.definition.id,attempt:exercise.snapshot.id);self.scope=scope;return scope
    }
    public func release(){scope=nil;aliases=[:];waited=false;search?.cancel();search=nil;clearMarks()}
    /// The bound attempt as shown, with its live ticket; nil once another attempt, place or task is shown.
    private var shown:(exercise:Exercise,ticket:Ticket)? {
        guard TrainingRolloutPolicy.trainingVoiceEnabled,let scope,case .training(let entry)=session.activity.place,entry==scope.entry,let exercise=controller.exercise,exercise.snapshot.id==scope.attempt,exercise.task == .game else{return nil}
        return (exercise,Ticket(attempt:exercise.snapshot.id,revision:exercise.snapshot.revision))
    }
    public var inScope:Bool {shown != nil}
    public var liveTicket:Ticket? {shown?.ticket}
    public var attemptFinished:Bool {shown?.exercise.finished ?? false}
    public var defenderThinking:Bool {controller.games.thinking}
    /// Whether `key` names the live board: the live ticket's own, or one the adapter's own help record replaced.
    public func accepts(_ key:String)->Bool {
        guard let live=liveTicket else{return false}
        var key=key,steps=0
        while let next=aliases[key],steps<=aliases.count{key=next;steps+=1}
        return key==live.key
    }
    // MARK: Disclosure
    /// A new exchange (the learner's question, not a continuation or a regenerated answer) may wait once again.
    public func beginExchange(){waited=false}
    /// Checks a disclosure of a response bound to `keys` and records the attempt's help before it. Returns the live
    /// ticket, refreshed when this call's own save advanced the revision; throws `Stop` when nothing may be disclosed,
    /// having recorded nothing.
    @discardableResult public func disclose(_ keys:[String])throws -> Ticket {
        guard let shown else{trace?("disclose outOfScope");throw Stop.outOfScope}
        guard !shown.exercise.finished else{trace?("disclose finished");waited=false;throw Stop.refused(.finished)}
        guard keys.allSatisfy(accepts) else{trace?("disclose regenerate keys=\(keys) live=\(liveTicket?.key ?? "-")");throw Stop.regenerate}
        let outcome=controller.recordAgentHelp()
        switch outcome {
        case .recorded:
            guard let next=liveTicket else{trace?("disclose outOfScope after record");throw Stop.outOfScope}
            aliases[shown.ticket.key]=next.key;waited=false
            trace?("disclose recorded \(shown.ticket.key)->\(next.key)")
            return next
        case .alreadyRecorded:
            waited=false;trace?("disclose alreadyRecorded \(shown.ticket.key)");return shown.ticket
        case .defenderThinking:
            if waited{trace?("disclose refused defenderThinking");waited=false;throw Stop.refused(.defenderThinking)}
            waited=true;trace?("disclose wait defenderThinking");throw Stop.wait
        default:
            waited=false;trace?("disclose refused \(outcome.rawValue)");throw Stop.refused(outcome)
        }
    }
    // MARK: Tools
    /// Runs one of the adapter's tools for a response whose disclosure was granted at `key`. Every answer is about the
    /// training board the learner sees; nothing reads or changes the practice game or the real attempt.
    public func call(_ name:String,args a:[String:Any],key:String)async throws -> Any {
        trace?("call \(name) key=\(key)")
        guard Self.toolNames.contains(name) else{trace?("call \(name) forbidden");throw ProtocolFailure("ROLE_FORBIDDEN","A training game's coach offers only get_board, analyze_position, test_move, inspect_piece and highlight_squares.")}
        guard let shown else{trace?("call \(name) outOfScope");throw Stop.outOfScope}
        guard accepts(key) else{trace?("call \(name) regenerate live=\(liveTicket?.key ?? "-")");throw Stop.regenerate}
        // Nothing is told before the attempt records the help (`disclose`).
        guard shown.exercise.snapshot.recordedHelp else{trace?("call \(name) noHelpRecord");throw ProtocolFailure("UNAVAILABLE","Coaching starts only once the attempt records the help.")}
        let exercise=shown.exercise,live=shown.ticket.key,result:Any
        do {
            switch name {
            case "get_board":result=try board()
            case "analyze_position":result=try await analyze(exercise,key:live)
            case "test_move":result=try await test(exercise,key:live,from:a["from"] as? String ?? "",to:a["to"] as? String ?? "",promotion:a["promotion"] as? String)
            case "inspect_piece":result=try inspect(exercise,key:live,square:a["square"] as? String ?? "")
            default:result=highlight(key:live,squares:a["squares"] as? [String] ?? [],arrows:a["arrows"] as? [[String]] ?? [])
            }
        } catch {
            trace?("call \(name) threw \(error)")
            throw error
        }
        guard inScope else{trace?("call \(name) outOfScope after");throw Stop.outOfScope}
        guard accepts(key) else{trace?("call \(name) regenerate after live=\(liveTicket?.key ?? "-")");throw Stop.regenerate}
        trace?("call \(name) ok")
        return result
    }
    /// The training board as the learner sees it: the position, whose move it is, the learner's legal moves and the
    /// exercise's own prompt and rules. Never its hints, explanation or the defender's choices.
    public func board()throws -> [String:Any] {
        guard let shown,let position=shown.exercise.current else{throw ProtocolFailure("STALE_STATE","The training game changed. Call get_board again.")}
        let exercise=shown.exercise,scenario=exercise.scenario,turn=try position.turn(),key=shown.ticket.key
        let learnersMove=turn==scenario.learner && !controller.games.thinking && exercise.paused==nil
        let legal:[[String:Any]]=learnersMove ? try position.outcomes().map{["from":$0.from,"to":$0.to,"san":$0.san,"uci":$0.uci]}:[]
        let last:Any=exercise.lastMove.map{["from":$0.from,"to":$0.to]} ?? NSNull()
        return ["state":["mode":"training","positionId":key,"display":["identity":key],"learnerSide":scenario.learner,"turn":turn,"learnersMove":learnersMove,"defenderThinking":controller.games.thinking,"paused":exercise.paused != nil],
                "training":["title":exercise.definition.title,"prompt":exercise.prompt,"rules":exercise.definition.rules,"startFEN":scenario.fen ?? "","moves":(scenario.prelude ?? [])+exercise.line,"fen":position.fen,"inCheck":try position.status() == .check,"lastMove":last,"claimableDraw":exercise.claimable as Any? ?? NSNull(),"opponent":TrainingEndgameController.note(for:scenario.check,opponent:exercise.snapshot.opponent)],
                "legalMoves":legal,"coordinatePerspective":"White"]
    }
    private func analyze(_ exercise:Exercise,key:String)async throws -> [String:Any] {
        let analysis=try await search(exercise,then:[],multiPv:2),position=exercise.current
        let best:Any=analysis.bestMove.flatMap{uci in (try? position?.outcomes())?.first{$0.uci==uci}?.san} ?? NSNull()
        return ["positionId":key,"bestMove":best,"lines":analysis.lines.prefix(2).map(Self.line),"note":"A short Stockfish search of the training game. Scores are not win probabilities."]
    }
    /// A move tried on a copy of the game: whether it is legal, what it does or ends, and the defender's best reply.
    private func test(_ exercise:Exercise,key:String,from:String,to:String,promotion:String?)async throws -> [String:Any] {
        guard let current=exercise.current,try current.turn()==exercise.scenario.learner else{throw ProtocolFailure("NOT_YOUR_MOVE","A move is tried only on the learner's turn.")}
        // A hypothetical copy, rebuilt from the start: the attempt's own rules and line are never touched.
        let copy=try controller.gamePosition(exercise)
        switch try copy.grade(from:from,to:to,promotion:promotion) {
        case .selection(let reason),.ruleError(let reason):return ["hypothetical":true,"positionId":key,"legal":false,"reason":reason]
        case .needsPromotion:throw ProtocolFailure("INVALID_ARGUMENT","Name the promotion piece: q, r, b or n.")
        case .legal(let move):
            let moves=(exercise.scenario.prelude ?? [])+exercise.line+[move.uci]
            let after=try TrainingLegality(fen:exercise.scenario.fen ?? "",prelude:moves,runtimeFactory:controller.runtimeFactory),draw=try after.automaticDraw()
            let ends:String?=move.checkmate ? "checkmate":move.stalemate ? "stalemate":draw
            var result:[String:Any]=["hypothetical":true,"positionId":key,"legal":true,"move":["san":move.san,"uci":move.uci,"from":move.from,"to":move.to,"captured":move.captured as Any? ?? NSNull(),"check":move.check],"ends":ends as Any? ?? NSNull()]
            guard !move.checkmate,!move.stalemate,draw==nil else{return result}
            let reply=try await search(exercise,then:[move.uci],multiPv:1)
            let san:Any=reply.bestMove.flatMap{uci in (try? after.outcomes())?.first{$0.uci==uci}?.san} ?? NSNull()
            result["defenderBest"]=["san":san,"score":reply.lines.first.map{Self.line($0)["score"] as Any} ?? NSNull()]
            return result
        }
    }
    private func inspect(_ exercise:Exercise,key:String,square:String)throws -> [String:Any] {
        guard let current=exercise.current else{throw ProtocolFailure("STALE_STATE")}
        guard try current.board()[square] != nil else{throw ProtocolFailure("INVALID_ARGUMENT","There is no piece on \(square).")}
        let rules=try controller.runtimeFactory.map{try ChessRules(fen:current.fen,runtimeFactory:$0)} ?? ChessRules(fen:current.fen)
        return ["positionId":key,"inspection":jsonObject(try rules.inspect(square))]
    }
    /// Draws the coach's marks on the training board for 15 seconds, or until the board changes.
    private func highlight(key:String,squares:[String],arrows:[[String]])->[String:Any] {
        marksTask?.cancel();let drawn=Marks(key:key,squares:squares.filter(ChessNotation.validSquare),arrows:arrows.filter{$0.count==2 && $0.allSatisfy(ChessNotation.validSquare)});marks=drawn
        marksTask=Task{[weak self] in try? await Task.sleep(nanoseconds:15_000_000_000);guard !Task.isCancelled,let self,self.marks==drawn else{return};self.marks=Marks()}
        return ["positionId":key,"highlighted":drawn.squares,"arrows":drawn.arrows]
    }
    public func clearMarks(){marksTask?.cancel();marksTask=nil;if marks != Marks(){marks=Marks()}}
    /// The marks to draw now: only while they belong to the board shown.
    public var shownMarks:Marks? {marks.key.isEmpty || !accepts(marks.key) ? nil:marks}
    static func line(_ line:AnalysisLine)->[String:Any] {["san":Array(line.san.prefix(6)),"score":["kind":line.score.kind,"value":line.score.value,"perspective":line.score.perspective]]}
    /// One coaching search of the training game's own history, never practice's. It yields to the defender: refused
    /// while the defender thinks, and cancelled when the defender starts (`init`), which asks the coach to wait.
    private func search(_ exercise:Exercise,then extra:[String],multiPv:Int)async throws -> EngineAnalysis {
        guard let engine=controller.games.engine else{throw ProtocolFailure("ENGINE_UNAVAILABLE")}
        guard !controller.games.thinking else{throw Stop.wait}
        guard search==nil else{throw ProtocolFailure("BUSY","Another coaching search is still running. Wait for it, then ask again.")}
        let fairness=controller.games.fairness,start=exercise.scenario.fen ?? "",moves=(exercise.scenario.prelude ?? [])+exercise.line+extra
        let task=Task{@MainActor in
            try fairness.requireEngineHelp()
            return try await engine.analyzeHistory(startFEN:start,moves:moves,profile:Self.profile,budget:Self.budget,multiPv:multiPv)
        }
        search=task;yielded=false;defer{if search==task{search=nil}}
        // A search the defender interrupted is dropped, even one that finished first: the coach waits while the defender
        // still thinks, and asks again once it has replied.
        let result:EngineAnalysis
        do{result=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})}
        catch{if task.isCancelled,yielded{throw controller.games.thinking ? Stop.wait:Stop.regenerate};throw error}
        if task.isCancelled{throw yielded ? (controller.games.thinking ? Stop.wait:Stop.regenerate):CancellationError()}
        try fairness.requireEngineHelp()
        return result
    }
}
