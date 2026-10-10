import Foundation
import Combine
public struct ReviewBranch:Codable,Equatable {public let id:UUID,root:Int;public var moves:[String];public init(root:Int){id=UUID();self.root=root;moves=[]}}
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
    public var branchesForSaving:[ReviewBranch] {boundedBranches(authoredBranches+(branch.map{[$0]} ?? []))}
    private var rulesCache:(String,ChessRules)?
    private var explanationCache:(String,ReviewExplanation)?
    @Published public private(set) var selected:String?
    @Published public private(set) var evidence:ReviewEvidence?
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
    public var explanation:ReviewExplanation? {guard let d=document else{return nil};let key=identity+":\(branchPly):\(evidence?.createdAt.timeIntervalSince1970 ?? 0)";if let cache=explanationCache,cache.0==key{return cache.1};let result:ReviewExplanation?;if branch != nil,let rules=displayRules{result=ReviewExplanation.imagined(rules:rules)}else{result=try? ReviewExplanation.make(document:d,node:nodeID,evidence:evidence)};if let result=result{explanationCache=(key,result)};return result}
    public func open(_ document:GameDocument,practice:GameSession){cancel();self.document=document;authoredBranches=[];nodeID=0;branch=nil;selected=nil;evidence=nil;revision+=1;practice.suspendForReview()}
    public func close(practice:GameSession,resumePractice:Bool=true){cancel();document=nil;branch=nil;selected=nil;revision+=1;practice.returnFromReview(resumeReply:resumePractice)}
    public func cancel(){pause();analysisTask?.cancel();analysisTask=nil;analysisStatus="idle";revision+=1}
    private func rememberBranch(){if let branch=branch,!branch.moves.isEmpty{authoredBranches=boundedBranches(authoredBranches+[branch])}}
    public func openSavedBranch(_ id:UUID)throws {
        guard let saved=authoredBranches.first(where:{$0.id==id}),let document=document else{throw CheckmateError.invalid("Unknown imagined line.")}
        let rules=try document.snapshotRules(at:saved.root);for move in saved.moves{try rules.move(uci:move)}
        rememberBranch();cancel();nodeID=saved.root;branch=saved;branchPly=0;selected=nil;evidence=nil;error=nil;revision+=1
    }
    public func select(_ node:Int)throws {guard document?.nodes.indices.contains(node)==true else{throw CheckmateError.invalid("Unknown review node.")};rememberBranch();cancel();nodeID=node;branch=nil;selected=nil;evidence=nil;error=nil;revision+=1}
    public func restoreSaved(cursor:Int,branches:[ReviewBranch])throws {guard document?.nodes.indices.contains(cursor)==true else{throw CheckmateError.invalid("Unknown review node.")};authoredBranches=boundedBranches(branches);try select(cursor)}
    /// A failed review entry restores the exact prior owner without resuming play; a suspended practice reply
    /// stays held by the session until an explicit Return to game. Returns whether a reply is waiting.
    @discardableResult public func abandonFailedEntry(practice:GameSession)->Bool {close(practice:practice,resumePractice:false);return practice.requireExplicitResume()}
    private var currentRoute:[Int] {
        guard let d=document else{return []};var ancestors:[Int]=[],cursor:Int?=nodeID
        while let id=cursor{ancestors.append(id);cursor=d.nodes[id].parent}
        var route=Array(ancestors.reversed()),next=d.nodes[nodeID].children.first
        while let id=next{route.append(id);next=d.nodes[id].children.first};return route
    }
    public func step(_ delta:Int){if branch != nil{seekBranch(branchPly+delta);return};guard let d=document else{return};let route=currentRoute,index=route.firstIndex(of:nodeID) ?? 0;try? select(route[max(0,min(route.count-1,index+delta))])}
    public func first(){if branch != nil{seekBranch(0)}else{try? select(0)}}
    public func last(){if let branch=branch{seekBranch(branch.moves.count)}else{try? select(currentRoute.last ?? 0)}}
    public func pause(){playback?.cancel();playback=nil;playing=false}
    public func play(){guard document != nil else{return};pause();playing=true;playback=Task{while !Task.isCancelled,self.playing {try? await Task.sleep(nanoseconds:1_500_000_000);guard !Task.isCancelled,let d=self.document else{return};if let branch=self.branch{if self.branchPly>=branch.moves.count{self.pause();return};self.branchPly+=1;self.revision+=1;continue};let route=self.currentRoute,index=route.firstIndex(of:self.nodeID) ?? 0;guard index+1<route.count else{self.pause();return};self.nodeID=route[index+1];self.revision+=1;self.evidence=nil;self.selected=nil;if index+2==route.count{self.pause()}}}}
    public func beginBranch()throws {guard document != nil else{throw CheckmateError.invalid("No review is open.")};rememberBranch();cancel();branch=ReviewBranch(root:nodeID);branchPly=0;selected=nil;revision+=1}
    /// Stores the validated canonical UCI (for example e7e8 becomes e7e8q), never the caller's spelling.
    public func playBranch(_ uci:String)throws {guard var branch=branch,let rules=displayRules else{throw CheckmateError.invalid("Open Test my idea first.")};let canonical=try rules.move(uci:uci).uci;branch.moves=Array(branch.moves.prefix(branchPly));branch.moves.append(canonical);branchPly=branch.moves.count;self.branch=branch;selected=nil;revision+=1}
    /// The displayed position (original node, or imagined line rooted at its own root and
    /// replayed to the shown ply) with full preceding history for a separate practice game.
    public func practiceForkRules()throws -> ChessRules {
        guard let document=document else{throw CheckmateError.invalid("No review is open.")}
        let rules=try document.rules(at:branch?.root ?? nodeID)
        for move in (branch?.moves ?? []).prefix(branchPly){try rules.move(uci:move)}
        return rules
    }
    private var forkAvailabilityCache:(String,Bool)?
    /// History-aware terminal check shared by the button, the confirmation and MCP.
    public var practiceForkAvailable:Bool {
        let key=identity+":\(branchPly)";if let cached=forkAvailabilityCache,cached.0==key{return cached.1}
        let available=(try? practiceForkRules()).map{!$0.over} ?? false;forkAvailabilityCache=(key,available);return available
    }
    public func previewLine(_ moves:[String],fromNode:Int?=nil)throws {guard moves.count<=32 else{throw CheckmateError.invalid("Preview line is too long.")};guard let document=document else{throw CheckmateError.invalid("No review is open.")};let root=fromNode ?? nodeID;let rules=try document.snapshotRules(at:root);for move in moves{try rules.move(uci:move)};try beginBranch();branch=ReviewBranch(root:root);for move in moves{try playBranch(move)}}
    public func clearBranch(){pause();rememberBranch();branch=nil;branchPly=0;selected=nil;revision+=1}
    public func seekBranch(_ ply:Int){guard let branch=branch else{return};pause();branchPly=max(0,min(branch.moves.count,ply));selected=nil;revision+=1}
    public func selectSquare(_ square:String,promotion:String="q")throws {guard let rules=displayRules else{return};if let from=selected,branch != nil,rules.moves(from).contains(where:{$0.to==square}){guard let candidate=rules.moves(from).first(where:{$0.to==square && ($0.promotion==nil || $0.promotion==promotion)}) else{throw CheckmateError.invalid("Choose a valid promotion.")};try playBranch(candidate.uci);return};selected=rules.piece(square)==nil ? nil:square}
    public func analyze(using analyzer:ReviewAnalyzer,budget:Int=ReviewPolicy.quickBudget){guard let d=document else{return};analysisTask?.cancel();let node=nodeID,epoch=revision,branch=self.branch,ply=branchPly;analysisStatus="pending";analysisTask=Task{do{let result:ReviewEvidence;if let branch=branch{result=try await analyzer.analyzeBranch(document:d,root:branch.root,moves:Array(branch.moves.prefix(ply)),revision:epoch)}else{result=try await analyzer.analyze(document:d,node:node,revision:epoch,budget:budget)};guard !Task.isCancelled,self.document?.id==d.id,self.nodeID==node,self.revision==epoch else{return};self.evidence=result;self.analysisStatus="ready"}catch{guard !Task.isCancelled,self.revision==epoch else{return};self.analysisStatus="failed";self.error="Analysis is unavailable; the record remains navigable."}}}
}
