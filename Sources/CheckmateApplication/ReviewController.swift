import CheckmateAssets
import CheckmateDomain
import CheckmateRules
import Foundation
import Combine
public struct ReviewBranch:Codable,Equatable {public let id:UUID,root:Int;public var moves:[String];public init(root:Int){id=UUID();self.root=root;moves=[]}
    /// The same idea attached to its root's number in a re-read tree.
    func rooted(at root:Int)->ReviewBranch {ReviewBranch(id:id,root:root,moves:moves)}
    private init(id:UUID,root:Int,moves:[String]){self.id=id;self.root=root;self.moves=moves}}
@MainActor public final class ReviewController:ObservableObject {
    @Published public private(set) var document:GameDocument?
    @Published public private(set) var nodeID=0
    public var onEvent:(()->Void)?
    @Published public private(set) var revision=0 {didSet{analysisTask?.cancel();analysisTask=nil;evidence=nil;analysisStatus="idle";error=nil;clearAnnotations();onEvent?()}}
    @Published public private(set) var branch:ReviewBranch?
    @Published public private(set) var playing=false
    @Published public private(set) var branchPly=0
    @Published public private(set) var authoredBranches:[ReviewBranch]=[]
    @Published public private(set) var arrows:[[String]]=[]
    @Published public private(set) var highlights:[Highlight]=[]
    private var annotationTask:Task<Void,Never>?
    public func clearAnnotations(){annotationTask?.cancel();annotationTask=nil;arrows=[];highlights=[]}
    public func annotate(arrows:[[String]],highlights:[Highlight],ttl:Int){clearAnnotations();self.arrows=arrows;self.highlights=highlights;let identity=self.identity;annotationTask=Task{try? await Task.sleep(for:.milliseconds(ttl));guard !Task.isCancelled,self.identity==identity else{return};self.clearAnnotations()}}
    private func boundedBranches(_ branches:[ReviewBranch])->[ReviewBranch] {
        var saved:[ReviewBranch]=[]
        for candidate in branches where !candidate.moves.isEmpty {
            saved.removeAll{$0.id==candidate.id || ($0.root==candidate.root && $0.moves==candidate.moves)}
            saved.append(candidate)
        }
        return Array(saved.suffix(ReviewPolicy.maximumBranches))
    }
    /// The open line when it is an engine or agent preview the learner has not changed: shown, never kept as an idea.
    @Published public private(set) var previewBranchID:UUID?
    /// One undo per idea: the line and shown ply before the learner's move replaced its continuation.
    private var replacedContinuations:[UUID:(branch:ReviewBranch,ply:Int,preview:Bool)]=[:]
    public var canUndoIdeaChange:Bool {branch.map{replacedContinuations[$0.id] != nil} ?? false}
    public var branchesForSaving:[ReviewBranch] {boundedBranches(authoredBranches+(branch.flatMap{$0.id==previewBranchID ? nil:[$0]} ?? []))}
    public static let ideaLimitMessage=String(localized:"You have kept the maximum of \(ReviewPolicy.maximumBranches) imagined lines. Delete one to start another.",bundle:.checkmate)
    /// Called after the open line is remembered (or while it is still a preview), so every kept idea is counted.
    private var atIdeaLimit:Bool {authoredBranches.count>=ReviewPolicy.maximumBranches}
    private var rulesCache:(String,ChessRules)?
    private var explanationCache:(String,ReviewExplanation)?
    @Published public private(set) var selected:String?
    @Published public private(set) var evidence:ReviewEvidence?
    /// The network-game fairness check (LAN-play plan D8); the app sets the session's. While participating, reviews
    /// still open and browse, but engine evidence and the explanations built from it are withheld.
    public var fairness=FairnessPolicy()
    @Published public private(set) var analysisStatus="idle"
    @Published public private(set) var error:String?
    private var playback:Task<Void,Never>?,analysisTask:Task<Void,Never>?
    public init(){}
    public var active:Bool {document != nil}
    public var identity:String {"review:\(document?.id.uuidString ?? "none"):\(nodeID):\(revision):\(branch?.id.uuidString ?? "original"):\(branch?.moves.count ?? 0)"}
    public var displayRules:ChessRules? {let key=identity+":\(branchPly)";if let cache=rulesCache,cache.0==key{return cache.1};guard let d=document,let rules=try? d.snapshotRules(at:branch?.root ?? nodeID) else{return nil};for move in (branch?.moves ?? []).prefix(branchPly){guard (try? rules.move(uci:move)) != nil else{return nil}};rulesCache=(key,rules);return rules}
    public var displayFEN:String? {displayRules?.fen}
    public var board:Position {displayRules?.board ?? [:]}
    public var destinations:[String] {selected.flatMap{displayRules?.moves($0).map(\.to)} ?? []}
    /// The whole-game analysis the overview reads (R-24); the app sets its own.
    public weak var analyzer:ReviewAnalyzer?
    /// What each mainline move gave up, for the overview: only a finished analysis of this game, and never while
    /// engine help is withheld; a partial one counts only for the costly moves it has already found.
    private var overviewLosses:[Int:Double]? {
        guard nodeID==0,branch==nil,fairness.engineHelpAllowed,let d=document,let analyzer,analyzer.batchDocument==d.id else{return nil}
        return analyzer.batchStatus=="ready" || analyzer.losses.values.contains(where:{MoveGrade(expectationLoss:$0).map{$0 != .inaccuracy} ?? false}) ? analyzer.losses:nil
    }
    /// The shown position's White-relative score (R-17): an imagined line's own analysis, else the whole-game analysis
    /// of this game, else this move's own analysis. Nil while engine help is withheld for a network game (D8).
    public var shownScore:AnalysisScore? {
        guard fairness.engineHelpAllowed,let d=document else{return nil}
        if branch != nil{return evidence?.root.lines.first?.score}
        if let analyzer,analyzer.batchDocument==d.id,let score=analyzer.evaluations[nodeID]{return score}
        guard let e=evidence,e.nodeID==nodeID else{return nil};return nodeID==0 ? e.root.lines.first?.score:e.played?.lines.first?.score
    }
    /// How much of the evaluation bar is White's, 0...1; nil hides the bar.
    public var evaluationShare:Double? {guard let score=shownScore,let turn=displayRules?.turn else{return nil};return Self.whiteShare(score,turn:turn)}
    /// The engine's first choice in the shown position, as UCI, for the optional arrow; nil while engine help is withheld.
    public var bestMove:String? {
        guard fairness.engineHelpAllowed,let d=document else{return nil}
        if branch != nil{return evidence?.root.lines.first?.pv.first}
        guard let analyzer,analyzer.batchDocument==d.id else{return nil};return analyzer.bestMoves[nodeID]
    }
    /// White's winning chances for a White-relative score, 0...1, on the curve Lichess uses for its bar. A mate is all
    /// or nothing; a mate in 0 means the side to move is already mated.
    public static func whiteShare(_ score:AnalysisScore,turn:String)->Double {
        if score.kind=="mate"{return score.value>0 ? 1:score.value<0 ? 0:turn=="w" ? 0:1}
        return 1/(1+exp(-0.00368208*Double(score.value)))
    }
    public var explanation:ReviewExplanation? {guard let d=document else{return nil};let shown=fairness.engineHelpAllowed ? evidence:nil,losses=overviewLosses,key=identity+":\(branchPly):\(shown?.createdAt.timeIntervalSince1970 ?? 0):\(losses?.hashValue ?? 0)";if let cache=explanationCache,cache.0==key{return cache.1};let result:ReviewExplanation?;if branch != nil,let rules=displayRules{result=ReviewExplanation.imagined(rules:rules)}else{result=try? ReviewExplanation.make(document:d,node:nodeID,evidence:shown,losses:losses)};if let result=result{explanationCache=(key,result)};return result}
    /// Shows `document` and records the review in the session's activity, over the place it returns to.
    public func open(_ document:GameDocument,practice:GameSession,draft:Bool=false){load(document);practice.enterReview(document:document.id,draft:draft)}
    /// The review's own content only; the caller changes the session's activity.
    public func load(_ document:GameDocument){cancel();self.document=document;authoredBranches=[];replacedContinuations=[:];previewBranchID=nil;nodeID=0;branch=nil;selected=nil;evidence=nil;revision+=1}
    public func close(practice:GameSession,resumePractice:Bool=true){unload();practice.returnFromReview(resumeReply:resumePractice)}
    /// Clears the review's own content only; the caller changes the session's activity.
    public func unload(){cancel();document=nil;branch=nil;previewBranchID=nil;replacedContinuations=[:];selected=nil;revision+=1}
    public func cancel(){pause();analysisTask?.cancel();analysisTask=nil;analysisStatus="idle";revision+=1}
    /// The kept ideas once the open line is remembered; a preview is not one.
    private var rememberedBranches:[ReviewBranch] {if let branch=branch,!branch.moves.isEmpty,branch.id != previewBranchID{return boundedBranches(authoredBranches+[branch])};return authoredBranches}
    private func rememberBranch(){authoredBranches=rememberedBranches;previewBranchID=nil}
    /// Removes one imagined line; the imported record and the other lines are kept.
    public func deleteBranch(_ id:UUID)throws {
        guard authoredBranches.contains(where:{$0.id==id}) || branch?.id==id else{throw CheckmateError.invalid(String(localized:"Unknown imagined line.",bundle:.checkmate))}
        authoredBranches.removeAll{$0.id==id};replacedContinuations[id]=nil
        if branch?.id==id{pause();branch=nil;branchPly=0;selected=nil;evidence=nil}
        revision+=1
    }
    /// Restores the idea's continuation that the learner's last move replaced.
    public func undoIdeaChange()throws {
        guard let current=branch,let previous=replacedContinuations.removeValue(forKey:current.id) else{throw CheckmateError.invalid(String(localized:"There is no change to undo.",bundle:.checkmate))}
        pause();branch=previous.branch;branchPly=previous.ply;if previous.preview{previewBranchID=previous.branch.id;authoredBranches.removeAll{$0.id==previous.branch.id}};selected=nil;revision+=1
    }
    /// Reopening the idea already open keeps its latest moves (an edit or an undo), not the copy kept before them.
    public func openSavedBranch(_ id:UUID)throws {
        guard let saved=rememberedBranches.first(where:{$0.id==id}),let document=document else{throw CheckmateError.invalid(String(localized:"Unknown imagined line.",bundle:.checkmate))}
        let rules=try document.snapshotRules(at:saved.root);for move in saved.moves{try rules.move(uci:move)}
        rememberBranch();cancel();nodeID=saved.root;branch=saved;branchPly=0;selected=nil;evidence=nil;error=nil;revision+=1
    }
    public func select(_ node:Int)throws {guard document?.nodes.indices.contains(node)==true else{throw CheckmateError.invalid(String(localized:"Unknown review node.",bundle:.checkmate))};rememberBranch();cancel();nodeID=node;branch=nil;selected=nil;evidence=nil;error=nil;revision+=1}
    public func restoreSaved(cursor:Int,branches:[ReviewBranch])throws {guard document?.nodes.indices.contains(cursor)==true else{throw CheckmateError.invalid(String(localized:"Unknown review node.",bundle:.checkmate))};authoredBranches=boundedBranches(branches);try select(cursor)}
    /// A failed review entry restores the exact prior owner without resuming play; a suspended practice reply
    /// stays held by the session until an explicit Return to game. Returns whether a reply is waiting.
    @discardableResult public func abandonFailedEntry(practice:GameSession)->Bool {close(practice:practice,resumePractice:false);return practice.requireExplicitResume()}
    private var currentRoute:[Int] {
        guard let d=document else{return []};var ancestors:[Int]=[],cursor:Int?=nodeID
        while let id=cursor{ancestors.append(id);cursor=d.nodes[id].parent}
        var route=Array(ancestors.reversed()),next=d.nodes[nodeID].children.first
        while let id=next{route.append(id);next=d.nodes[id].children.first};return route
    }
    /// How far the shown position is along the transport's route (the recorded line through it, a variation
    /// included), or along the open idea.
    public var progress:Double {
        if let branch=branch{return branch.moves.isEmpty ? 0:Double(branchPly)/Double(branch.moves.count)}
        let route=currentRoute;guard route.count>1,let index=route.firstIndex(of:nodeID) else{return 0};return Double(index)/Double(route.count-1)
    }
    public func step(_ delta:Int){if branch != nil{seekBranch(branchPly+delta);return};guard document != nil else{return};let route=currentRoute,index=route.firstIndex(of:nodeID) ?? 0;try? select(route[max(0,min(route.count-1,index+delta))])}
    /// ← in the key model (R-8, after Lichess): one move back along the line shown, an imagined one included. Leaving
    /// an idea's first move lands on the recorded move it starts from, and the idea is kept.
    public func back()throws {
        guard let branch=branch,let document=document else{step(-1);return}
        if branchPly>1{seekBranch(branchPly-1)}else{try select(branchPly==1 ? branch.root:document.nodes[branch.root].parent ?? branch.root)}
    }
    /// → in the key model: one move on along the line shown, the recorded line's first continuation or the idea's.
    public func forward(){step(1)}
    /// A line from the shown move's position: a recorded move, or a kept idea shown at `ply`.
    public enum Line:Equatable {case node(Int),idea(UUID,ply:Int)}
    public struct Variation:Equatable {public let line:Line,move:String}
    /// The shown move and its alternatives from the same position, by move: recorded moves first in their order,
    /// then kept ideas that play something else there. ↑/↓ step through them; empty at the game's start.
    public var variations:[Variation] {
        guard let d=document else{return []}
        let root:Int,prefix:[String]
        if let branch,branchPly>0{root=branch.root;prefix=Array(branch.moves.prefix(branchPly-1))}
        else{guard let parent=d.nodes[branch?.root ?? nodeID].parent else{return []};root=parent;prefix=[]}
        var lines:[Variation]=[],seen=Set<String>()
        if prefix.isEmpty{for child in d.nodes[root].children{if let uci=d.nodes[child].uci,seen.insert(uci).inserted{lines.append(Variation(line:.node(child),move:uci))}}}
        for idea in rememberedBranches+(branch.map{[$0]} ?? []) where idea.root==root && idea.moves.count>prefix.count && Array(idea.moves.prefix(prefix.count))==prefix && seen.insert(idea.moves[prefix.count]).inserted {lines.append(Variation(line:.idea(idea.id,ply:prefix.count+1),move:idea.moves[prefix.count]))}
        return lines
    }
    /// The move that led to the shown position, nil at the game's start.
    private var shownMove:String? {if let branch,branchPly>0{return branch.moves[branchPly-1]};return document?.nodes[branch?.root ?? nodeID].uci}
    /// ↑ (-1) and ↓ (+1) in the key model: the previous or next alternative to the shown move, stopping at either end.
    public func variation(_ delta:Int)throws {
        let lines=variations;guard let move=shownMove,let index=lines.firstIndex(where:{$0.move==move}),lines.indices.contains(index+delta) else{return}
        switch lines[index+delta].line {
        case .node(let id):try select(id)
        case .idea(let id,let ply):try openSavedBranch(id);seekBranch(ply)
        }
    }
    public func first(){if branch != nil{seekBranch(0)}else{try? select(0)}}
    public func last(){if let branch=branch{seekBranch(branch.moves.count)}else{try? select(currentRoute.last ?? 0)}}
    public func pause(){playback?.cancel();playback=nil;playing=false}
    public func play(){guard document != nil else{return};pause();playing=true;playback=Task{while !Task.isCancelled,self.playing {try? await Task.sleep(nanoseconds:1_500_000_000);guard !Task.isCancelled,self.document != nil else{return};if let branch=self.branch{if self.branchPly>=branch.moves.count{self.pause();return};self.branchPly+=1;self.revision+=1;continue};let route=self.currentRoute,index=route.firstIndex(of:self.nodeID) ?? 0;guard index+1<route.count else{self.pause();return};self.nodeID=route[index+1];self.revision+=1;self.evidence=nil;self.selected=nil;if index+2==route.count{self.pause()}}}}
    /// Starts an imagined line at the shown position. At the idea limit a new line is refused, never made by
    /// silently dropping the oldest idea.
    public func beginBranch()throws {guard document != nil else{throw CheckmateError.invalid(String(localized:"No review is open.",bundle:.checkmate))};guard rememberedBranches.count<ReviewPolicy.maximumBranches else{throw CheckmateError.invalid(Self.ideaLimitMessage)};rememberBranch();cancel();branch=ReviewBranch(root:nodeID);branchPly=0;selected=nil;revision+=1}
    /// Stores the validated canonical UCI (for example e7e8 becomes e7e8q), never the caller's spelling. Replaying
    /// the line's own next move steps along it; a different move replaces the continuation, which can be undone.
    public func playBranch(_ uci:String)throws {
        // The move is tried on the shown position, which then leaves the cache: a refused move must not advance the board.
        guard var branch=branch,let rules=displayRules else{throw CheckmateError.invalid(String(localized:"Start an imagined line first.",bundle:.checkmate))};rulesCache=nil;let canonical=try rules.move(uci:uci).uci
        if branchPly<branch.moves.count,branch.moves[branchPly]==canonical{branchPly+=1;selected=nil;revision+=1;return}
        let wasPreview=branch.id==previewBranchID
        if wasPreview{guard !atIdeaLimit else{throw CheckmateError.invalid(Self.ideaLimitMessage)};previewBranchID=nil}
        if branchPly<branch.moves.count{replacedContinuations[branch.id]=(branch,branchPly,wasPreview)}
        branch.moves=Array(branch.moves.prefix(branchPly));branch.moves.append(canonical);branchPly=branch.moves.count;self.branch=branch;selected=nil;revision+=1
    }
    /// The displayed position (original node, or imagined line rooted at its own root and
    /// replayed to the shown ply) with full preceding history for a separate practice game.
    public func practiceForkRules()throws -> ChessRules {
        guard let document=document else{throw CheckmateError.invalid(String(localized:"No review is open.",bundle:.checkmate))}
        let rules=try document.rules(at:branch?.root ?? nodeID)
        for move in (branch?.moves ?? []).prefix(branchPly){try rules.move(uci:move)}
        return rules
    }
    /// The exact position a practice fork would start from. A confirmation raised for one target must not fork
    /// another after an open, a step or an edit changed the review underneath it.
    public var practiceForkTarget:String? {guard let d=document else{return nil};return "\(d.id.uuidString):\(branch?.root ?? nodeID):\(branch?.id.uuidString ?? "original"):"+(branch?.moves.prefix(branchPly).joined(separator:" ") ?? "")}
    private var forkAvailabilityCache:(String,Bool)?
    /// History-aware terminal check shared by the button, the confirmation and MCP. It equals
    /// `practiceForkRules().over` without replaying the whole game in a new chess.js context on every step.
    public var practiceForkAvailable:Bool {
        let key=identity+":\(branchPly)";if let cached=forkAvailabilityCache,cached.0==key{return cached.1}
        let available=(try? displayedPositionEndsGame()).map{!$0} ?? false;forkAvailabilityCache=(key,available);return available
    }
    /// Checkmate, stalemate, insufficient material, the 75-move rule, or a fifth occurrence of the shown position along
    /// the recorded path to it (or to the idea's root) and the idea's moves, read from stored FENs.
    private func displayedPositionEndsGame()throws -> Bool {
        guard let document=document,let shown=displayRules else{throw CheckmateError.invalid(String(localized:"No review is open.",bundle:.checkmate))}
        if shown.checkmate || shown.stalemate || shown.insufficientMaterial{return true}
        let fen=shown.fen;if (Int(fen.split(separator:" ").dropFirst(4).first ?? "0") ?? 0)>=150{return true}
        func key(_ fen:String)->String {fen.split(separator:" ").prefix(4).joined(separator:" ")}
        let current=key(fen);var repetitions=0,cursor:Int?=branch?.root ?? nodeID
        while let id=cursor{if key(document.nodes[id].afterFEN)==current{repetitions+=1};cursor=document.nodes[id].parent}
        if let branch=branch,branchPly>0{let rules=try document.snapshotRules(at:branch.root);for move in branch.moves.prefix(branchPly){try rules.move(uci:move);if key(rules.fen)==current{repetitions+=1}}}
        return repetitions>=5
    }
    /// Shows an engine or agent line as a preview. It is not the learner's idea: it is never saved or counted
    /// unless the learner plays a move in it.
    public func previewLine(_ moves:[String],fromNode:Int?=nil)throws {
        guard moves.count<=32 else{throw CheckmateError.invalid(String(localized:"Preview line is too long.",bundle:.checkmate))};guard let document=document else{throw CheckmateError.invalid(String(localized:"No review is open.",bundle:.checkmate))}
        let root=fromNode ?? nodeID;let rules=try document.snapshotRules(at:root);var canonical:[String]=[];for move in moves{canonical.append(try rules.move(uci:move).uci)}
        rememberBranch();cancel();var line=ReviewBranch(root:root);line.moves=canonical;branch=line;previewBranchID=line.id;branchPly=canonical.count;selected=nil;revision+=1
    }
    public func clearBranch(){pause();rememberBranch();branch=nil;branchPly=0;selected=nil;revision+=1}
    public func seekBranch(_ ply:Int){guard let branch=branch else{return};pause();branchPly=max(0,min(branch.moves.count,ply));selected=nil;revision+=1}
    /// The move the chosen piece would make to `square` in the shown position, nil when it cannot go there; retry mode
    /// (R-18) judges a move without playing it.
    public func destination(_ square:String,promotion:String="q")->String? {guard let from=selected,let rules=displayRules else{return nil};return rules.moves(from).first{$0.to==square && ($0.promotion==nil || $0.promotion==promotion)}?.uci}
    /// A legal move on the original game opens an imagined line with it; the imported record is never changed.
    public func selectSquare(_ square:String,promotion:String="q")throws {guard let rules=displayRules else{return};if let from=selected,rules.moves(from).contains(where:{$0.to==square}){guard let candidate=rules.moves(from).first(where:{$0.to==square && ($0.promotion==nil || $0.promotion==promotion)}) else{throw CheckmateError.invalid(String(localized:"Choose a valid promotion.",bundle:.checkmate))};if branch==nil{try beginBranch()};try playBranch(candidate.uci);return};selected=rules.piece(square)==nil ? nil:square}
    public func clearSelection(){selected=nil}
    public func analyze(using analyzer:ReviewAnalyzer,budget:Int?=nil){guard fairness.engineHelpAllowed,let d=document else{return};analysisTask?.cancel();let node=nodeID,epoch=revision,branch=self.branch,ply=branchPly;analysisStatus="pending";analysisTask=Task{do{let result:ReviewEvidence;if let branch=branch{result=try await analyzer.analyzeBranch(document:d,root:branch.root,moves:Array(branch.moves.prefix(ply)),revision:epoch,budget:budget ?? ReviewPolicy.quickBudget)}else{result=try await analyzer.analyze(document:d,node:node,revision:epoch,budget:budget)};guard !Task.isCancelled,self.document?.id==d.id,self.nodeID==node,self.revision==epoch else{return};self.evidence=result;self.analysisStatus="ready"}catch{guard !Task.isCancelled,self.revision==epoch else{return};self.analysisStatus="failed";self.error=String(localized:"Analysis is unavailable; the record remains navigable.",bundle:.checkmate)}}}
}
