import CheckmateAssets
import CheckmateDomain
import CheckmateSupport
import Foundation
import Combine
public struct ReviewEvidence:Codable {
    public let schemaVersion:Int,documentID:UUID,documentHash:String,nodeID:Int,historyHash:String,revision:Int,engineVersion:String,options:[String:String],budgetMs:Int,createdAt:Date,root:EngineAnalysis,played:EngineAnalysis?,quality:String,provisional:Bool
}
public struct ReviewMoment:Codable,Identifiable {public let id:Int,expectationLoss:Double?,reason:String,provisional:Bool}
@MainActor public final class ReviewAnalyzer:ObservableObject {
    public let engine:any EngineService
    private let disk:ReviewAnalysisCache?
    @Published public private(set) var completed=0
    @Published public private(set) var total=0
    /// Quick-pass positions whose engine search failed (not cancelled); every-position failure ends as "failed", not "ready".
    @Published public private(set) var failed=0
    @Published public private(set) var moments:[ReviewMoment]=[]
    @Published public private(set) var batchStatus="idle"
    @Published public private(set) var batchDocument:UUID?
    /// White-POV scores of `batchDocument`'s mainline, by node: node N holds the position after N's move (the parent's
    /// search of the played move), node 0 the start (the first move's parent best line). A deep pass replaces a quick one.
    @Published public private(set) var evaluations:[Int:AnalysisScore]=[:]
    /// What each graded mainline move of `batchDocument` gave up, by node, from the same passes as `evaluations` (R-1).
    @Published public private(set) var losses:[Int:Double]=[:]
    /// The move's grade from its latest analysis; nil when it is near the best or not analyzed.
    public func grade(_ node:Int)->MoveGrade? {MoveGrade(expectationLoss:losses[node])}
    /// The threads and hash each review search asks for (R-5).
    public var resources=EngineResources.review()
    /// How many leading moments the whole-game analysis checks more deeply, when tests and measurements fix it;
    /// otherwise the game's plan decides.
    var momentsToDeepen:Int?
    /// The game's whole-game plan (R-5): its quick budget and deeper moments, from its length so the batch fits its
    /// budget. The batch and a restore read it, so they share the same stored evidence; a position the learner chooses
    /// keeps the full quick budget.
    private func plan(_ document:GameDocument)->ReviewBatchPlan {let plan=ReviewPolicy.batchPlan(plies:document.mainline.count);return ReviewBatchPlan(quickBudget:plan.quickBudget,moments:momentsToDeepen ?? plan.moments)}
    private var batchTask:Task<Void,Never>?,batchSearch:Task<ReviewEvidence,Error>?,generation=0,selectedCount=0
    private var cache:[String:ReviewEvidence]=[:]
    /// Cache writes still running, by record; forgetting a record waits for them so a late write cannot restore its files.
    private var pendingWrites:[UUID:(document:UUID,task:Task<Void,Never>)]=[:]
    /// The disk write itself; tests slow it to hold a write in flight.
    var writeCache:@Sendable (ReviewAnalysisCache,ReviewEvidence,String)throws->Void={try $0.save($1,key:$2)}
    /// The network-game fairness check (LAN-play plan D8): no search, batch or cached evidence while participating.
    public let fairness:FairnessPolicy
    public init(engine:any EngineService,cacheDirectory:URL?=nil,fairness:FairnessPolicy?=nil){let fairness=fairness ?? FairnessPolicy();self.engine=engine;self.fairness=fairness;disk=cacheDirectory.map{ReviewAnalysisCache(directory:$0)}
        // Joining withdraws the analysis shown as well as the work running: a cancelled run's kept part is engine output too.
        fairness.participation.observe{[weak self] role in if role != nil{self?.reset();self?.cancelSelected()}}}
    /// Single-position and branch searches running now. Joining a network game cancels them, so the engine stops
    /// rather than finishing work whose result would only be withheld (D8).
    private var selectedSearches:[UUID:Task<ReviewEvidence,Error>]=[:]
    private func cancelSelected(){for task in selectedSearches.values {task.cancel()};for task in selectedAnalyses.values {task.cancel()};selectedSearches=[:];selectedAnalyses=[:]}
    private var selectedAnalyses:[UUID:Task<EngineAnalysis,Error>]=[:]
    /// The work runs in its own task, a scheduling hop after the caller's fairness check: work that reaches the engine
    /// checks again itself, so a game joined in between stops it (D8).
    /// Runs first in each search's own task, before its work: tests hold searches there to begin a network game in
    /// the hop between the call's check and the task's.
    var searchTaskStarted:(()async->Void)?
    private func trackedAnalysis(_ work:@escaping ()async throws -> EngineAnalysis)async throws -> EngineAnalysis {
        let started=searchTaskStarted,id=UUID(),task=Task{await started?();return try await work()};selectedAnalyses[id]=task;defer{selectedAnalyses[id]=nil}
        // Cancelled by joining: the caller hears the readable reason, not a bare cancellation.
        do{return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})}
        catch{try fairness.requireEngineHelp();throw error}
    }
    private func tracked(_ work:@escaping ()async throws -> ReviewEvidence)async throws -> ReviewEvidence {
        let started=searchTaskStarted,id=UUID(),task=Task{await started?();return try await work()};selectedSearches[id]=task;defer{selectedSearches[id]=nil}
        // Cancelled by joining: the caller hears the readable reason, not a bare cancellation.
        do{return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})}
        catch{try fairness.requireEngineHelp();throw error}
    }
    /// Stops the running analysis. What it finished stays shown: the run is "partial", and starting it again (Resume)
    /// searches only the positions not yet stored. A finished, failed or idle analysis keeps its status.
    public func cancelBatch(){generation+=1;batchTask?.cancel();batchSearch?.cancel();batchTask=nil;batchSearch=nil;if ["pending","deepening"].contains(batchStatus){batchStatus="partial"}}
    public func reset(){cancelBatch();batchDocument=nil;completed=0;failed=0;total=0;moments=[];evaluations=[:];losses=[:];batchStatus="idle"}
    /// Whether a whole-game analysis of this record is still running.
    public func batchRunning(_ id:UUID)->Bool {batchDocument==id && ["pending","deepening"].contains(batchStatus)}
    /// Removes a purged review's stored analysis (one that left the Trash) from memory and disk; analysis other
    /// records computed is kept.
    public func forgetAnalysis(documentID:UUID)async throws {
        while let write=pendingWrites.first(where:{$0.value.document==documentID}){pendingWrites[write.key]=nil;await write.value.task.value}
        cache=cache.filter{$0.value.documentID != documentID};let disk=disk;_ = try await Task.detached{try disk?.delete(documentID:documentID)}.value}
    /// Starting again while the same record's analysis runs keeps its progress, and a record without moves has no game
    /// to analyze, so neither restarts the batch nor reports an empty "ready".
    /// The same record's finished scores stay on the graph while it runs again; another record's go.
    public func startBatch(_ document:GameDocument){guard fairness.engineHelpAllowed,!batchRunning(document.id),!document.mainline.isEmpty else{return};cancelBatch();if batchDocument != document.id{evaluations=[:];losses=[:]};batchDocument=document.id;completed=0;failed=0;total=document.mainline.count;moments=[];batchStatus="pending";let epoch=generation
        batchTask=Task{for node in document.mainline {guard !Task.isCancelled,self.generation==epoch else{return};while self.selectedCount>0{try? await Task.sleep(nanoseconds:10_000_000);guard !Task.isCancelled,self.generation==epoch else{return}};var done=false
            while !done {guard !Task.isCancelled,self.generation==epoch else{return};while self.selectedCount>0{try? await Task.sleep(nanoseconds:10_000_000);guard !Task.isCancelled else{return}};let search=Task{try await self.compute(document:document,node:node,revision:0,budget:self.plan(document).quickBudget)};self.batchSearch=search
                do{let evidence=try await search.value;guard self.generation==epoch else{return};self.recordMoment(evidence,document:document);self.recordEvaluation(evidence,document:document);done=true}catch{if !search.isCancelled{guard self.generation==epoch else{return};self.failed+=1;done=true}}}
            self.completed+=1
        }
        guard self.generation==epoch else{return};self.batchStatus="deepening"
        let targets=Array(self.moments.prefix(self.plan(document).moments)).map(\.id)
        for node in targets {
            var finished=false
            while !finished {
                guard !Task.isCancelled,self.generation==epoch else{return}
                while self.selectedCount>0{try? await Task.sleep(for:.milliseconds(10));guard !Task.isCancelled,self.generation==epoch else{return}}
                let search=Task{try await self.comparison(document:document,node:node,revision:0,budget:ReviewPolicy.deepBudget,baseline:self.plan(document).quickBudget)};self.batchSearch=search
                do{let evidence=try await search.value;guard self.generation==epoch else{return};self.recordMoment(evidence,document:document);self.recordEvaluation(evidence,document:document);finished=true}
                catch{if !search.isCancelled{finished=true}}
            }
        }
        guard self.generation==epoch else{return};self.batchStatus=self.total>0 && self.failed==self.total ? "failed":"ready";self.batchSearch=nil}
    }
    /// Shows `document`'s stored whole-game analysis without a search. Every way into or out of a review clears the
    /// analysis so the engine is free (PL-1); this brings back what was finished, from memory or disk. Every position
    /// stored, with the deeper check of its leading moments, is "ready"; some is "partial", and Resume searches only the
    /// rest; none leaves the analyzer idle. With `analyze` ("Analyze When Opened", R-4) a run that is not ready goes on
    /// to analyze what is missing: `startBatch` checks fairness again and searches only positions not stored.
    public func restore(_ document:GameDocument,analyze:Bool=false){guard fairness.engineHelpAllowed,!batchRunning(document.id),!document.mainline.isEmpty else{return};reset();let epoch=generation,engine=engine
        batchTask=Task{
            var found:[Int:ReviewEvidence]=[:],moments:[ReviewMoment]=[],evaluations:[Int:AnalysisScore]=[:],losses:[Int:Double]=[:],deepened=false
            // An engine whose files cannot be identified, or a history that cannot be hashed, has no stored evidence:
            // nothing is shown, and Analyze reports the failure when it searches.
            do{let identity=try await engine.identity()
                for node in document.mainline {guard !Task.isCancelled,self.generation==epoch else{return};if let evidence=try await self.stored(document:document,node:node,budget:self.plan(document).quickBudget,identity:identity){found[node]=evidence}}
                for node in document.mainline {if let evidence=found[node]{moments=Self.recording(evidence,document:document,in:moments);Self.evaluate(evidence,document:document,into:&evaluations,losses:&losses)}}
                // The batch deepens its leading moments only once every position is in, so a stored run is ready only then.
                deepened=found.count==document.mainline.count
                if deepened{for node in moments.prefix(self.plan(document).moments).map(\.id){
                    guard !Task.isCancelled,self.generation==epoch else{return}
                    guard let baseline=found[node],let deep=try await self.stored(document:document,node:node,budget:ReviewPolicy.deepBudget,identity:identity) else{deepened=false;break}
                    let evidence=self.judged(deep,baseline:baseline,document:document,node:node,revision:0);moments=Self.recording(evidence,document:document,in:moments);Self.evaluate(evidence,document:document,into:&evaluations,losses:&losses)
                }}
            }catch{return}
            // Stored evidence is engine output too: withheld while participating (D8).
            guard !Task.isCancelled,self.generation==epoch,self.fairness.engineHelpAllowed else{return}
            if !found.isEmpty{self.batchDocument=document.id;self.total=document.mainline.count;self.completed=found.count;self.failed=0;self.moments=moments;self.evaluations=evaluations;self.losses=losses;self.batchStatus=deepened ? "ready":"partial"}
            self.batchTask=nil;if analyze && !deepened{self.startBatch(document)}
        }
    }
    private func recordMoment(_ evidence:ReviewEvidence,document:GameDocument){moments=Self.recording(evidence,document:document,in:moments)}
    /// `moments` with `evidence`'s position reassessed, most costly first.
    private static func recording(_ evidence:ReviewEvidence,document:GameDocument,in moments:[ReviewMoment])->[ReviewMoment] {let node=document.nodes[evidence.nodeID],root=evidence.root.lines.first,played=evidence.played?.lines.first,loss=expectationLoss(root:root,played:played,mover:node.side);let forcing=node.san?.contains("x")==true || node.san?.contains("+")==true || node.san?.contains("#")==true || node.san?.contains("=")==true,costly=(loss ?? 0)>ReviewQualityPolicy.interestingExpectationLoss
        // Reassessed on every result: a quiet move a quick pass admitted leaves when a deeper pass finds it costs little.
        var result=moments;result.removeAll{$0.id==evidence.nodeID}
        // What a move cost comes first: a capture, check or promotion that threw the game away is reported for its cost.
        let reason=costly ? (forcing ? String(localized:"Engine alternatives are worth comparing (also a capture, check or promotion)",bundle:.checkmate):String(localized:"Engine alternatives are worth comparing",bundle:.checkmate)):forcing ? String(localized:"Capture, check or promotion",bundle:.checkmate):String(localized:"Engine alternatives are worth comparing",bundle:.checkmate)
        if forcing || costly || evidence.nodeID==document.mainline.last {result.append(ReviewMoment(id:evidence.nodeID,expectationLoss:loss,reason:reason,provisional:evidence.provisional));result.sort{($0.expectationLoss ?? 0)>($1.expectationLoss ?? 0)}}
        return result
    }
    private func recordEvaluation(_ evidence:ReviewEvidence,document:GameDocument){Self.evaluate(evidence,document:document,into:&evaluations,losses:&losses)}
    private static func evaluate(_ evidence:ReviewEvidence,document:GameDocument,into evaluations:inout [Int:AnalysisScore],losses:inout [Int:Double]){
        // A newer result without a score leaves a gap rather than keeping an older pass's score or grade.
        evaluations[evidence.nodeID]=evidence.played?.lines.first?.score
        losses[evidence.nodeID]=expectationLoss(root:evidence.root.lines.first,played:evidence.played?.lines.first,mover:document.nodes[evidence.nodeID].side)
        if evidence.nodeID==document.mainline.first{evaluations[0]=evidence.root.lines.first?.score}
    }
    public static func expectationLoss(root:AnalysisLine?,played:AnalysisLine?,mover:String)->Double? {guard let root=root,let played=played,root.score.bound==nil,played.score.bound==nil,let best=root.wdl,let actual=played.wdl,best.count==3,actual.count==3 else{return nil};func expected(_ wdl:[Int])->Double {Double(wdl[mover=="w" ? 0:2])+Double(wdl[1])/2};return max(0,(expected(best)-expected(actual))/1000)}
    /// `node`'s evidence at `budget`, or at the full quick budget: a position the learner chooses is never searched at the
    /// shorter budget a long game's whole-game analysis uses, and a deeper look at it is judged against the full one.
    public func analyze(document:GameDocument,node:Int,revision:Int,budget:Int?=nil)async throws -> ReviewEvidence {
        try fairness.requireEngineHelp();selectedCount+=1;batchSearch?.cancel();defer{selectedCount-=1}
        let budget=budget ?? ReviewPolicy.quickBudget,evidence=try await tracked{try await self.comparison(document:document,node:node,revision:revision,budget:budget,baseline:ReviewPolicy.quickBudget)};try fairness.requireEngineHelp();return evidence
    }
    private func comparison(document:GameDocument,node:Int,revision:Int,budget:Int,baseline:Int)async throws -> ReviewEvidence {
        let quick=try await compute(document:document,node:node,revision:revision,budget:budget)
        // Deeper work is selected explicitly, never hidden in the quick budget.
        if budget<ReviewPolicy.deepBudget{return quick}
        let baseline=try await compute(document:document,node:node,revision:revision,budget:baseline)
        return judged(quick,baseline:baseline,document:document,node:node,revision:revision)
    }
    /// Whether a deep line keeps the quick baseline's score: deep enough, exact, and the same kind and value within tolerance.
    private static func supported(_ deep:AnalysisLine?,_ initial:AnalysisLine?)->Bool {
        guard let deep=deep,let initial=initial,deep.depth>=ReviewQualityPolicy.minimumDepth,deep.score.bound==nil,initial.score.bound==nil,deep.score.kind==initial.score.kind else{return false}
        if deep.score.kind=="mate"{return deep.score.value==initial.score.value}
        return deep.score.kind=="cp" && abs(deep.score.value-initial.score.value)<=ReviewQualityPolicy.stableCpTolerance
    }
    /// A deeper result is labelled only where the quick baseline supports it; otherwise it stays provisional.
    private func judged(_ quick:ReviewEvidence,baseline:ReviewEvidence,document:GameDocument,node:Int,revision:Int)->ReviewEvidence {
        let a=quick.root.lines.first,b=baseline.root.lines.first,c=quick.played?.lines.first,d=baseline.played?.lines.first
        let stable=a?.pv.first==b?.pv.first && Self.supported(a,b) && (quick.played==nil || Self.supported(c,d))
        let quality:String
        if stable,let a=a,let c=c {quality=MoveQuality.compare(best:a.score,played:c.score,mover:document.nodes[node].side,stable:true)}else{quality=stable ? "unrated":"provisional"}
        return copy(quick,document:document,node:node,revision:revision,quality:quality,provisional:!stable)
    }
    /// An imagined line's position at `budget`. A deeper search (Look Deeper, R-23) also runs the quick baseline, and is
    /// provisional unless the baseline supports it, as a recorded position's is.
    public func analyzeBranch(document:GameDocument,root:Int,moves:[String],revision:Int,budget:Int=ReviewPolicy.quickBudget)async throws -> ReviewEvidence {
        try fairness.requireEngineHelp();selectedCount+=1;batchSearch?.cancel();defer{selectedCount-=1}
        let history=try document.history(to:root)+moves,rules=try document.rules(at:root)
        for move in moves{try rules.move(uci:move)}
        let engine=engine,start=document.startingFEN,resources=resources,deep=budget>=ReviewPolicy.deepBudget,searched=deep ? ReviewPolicy.deepBudget:ReviewPolicy.quickBudget
        let analysis=rules.over ? EngineAnalysis():try await trackedAnalysis{[fairness] in try fairness.requireEngineHelp();return try await engine.analyzeHistory(startFEN:start,moves:history,profile:.skill(20),budget:searched,multiPv:3,searchMoves:[],resources:resources)}
        try Task.checkCancellation();try fairness.requireEngineHelp()
        let evidence=ReviewEvidence(schemaVersion:1,documentID:document.id,documentHash:document.contentHash,nodeID:root,historyHash:reviewHash(Data((document.startingFEN+"|"+history.joined(separator:" ")).utf8)),revision:revision,engineVersion:engine.capabilities.name+" "+engine.binaryIdentity,options:Self.options(resources),budgetMs:searched,createdAt:Date(),root:analysis,played:nil,quality:"provisional",provisional:true)
        guard deep,!rules.over else{return evidence}
        let quick=try await trackedAnalysis{[fairness] in try fairness.requireEngineHelp();return try await engine.analyzeHistory(startFEN:start,moves:history,profile:.skill(20),budget:ReviewPolicy.quickBudget,multiPv:3,searchMoves:[],resources:resources)}
        try Task.checkCancellation();try fairness.requireEngineHelp()
        let stable=Self.supported(analysis.lines.first,quick.lines.first) && analysis.lines.first?.pv.first==quick.lines.first?.pv.first
        return copy(evidence,document:document,node:root,revision:revision,quality:stable ? "unrated":"provisional",provisional:!stable)
    }
    /// The options a review search runs with: the analysis policy's, with the review's threads and hash.
    static func options(_ resources:EngineResources)->[String:String] {AnalysisPolicy.options.merging(resources.options){_,review in review}}
    private func copy(_ result:ReviewEvidence,document:GameDocument,node:Int,revision:Int,quality:String?=nil,provisional:Bool?=nil)->ReviewEvidence {ReviewEvidence(schemaVersion:1,documentID:document.id,documentHash:document.contentHash,nodeID:node,historyHash:result.historyHash,revision:revision,engineVersion:result.engineVersion,options:result.options,budgetMs:result.budgetMs,createdAt:result.createdAt,root:result.root,played:result.played,quality:quality ?? result.quality,provisional:provisional ?? result.provisional)}
    private func compute(document:GameDocument,node:Int,revision:Int,budget:Int)async throws -> ReviewEvidence {
        try Task.checkCancellation();try fairness.requireEngineHelp();try await engine.prepare();try fairness.requireEngineHelp();let hash=try document.historyHash(to:node),selected=document.nodes[node],rootNode=selected.parent ?? node,rootHistory=try document.history(to:rootNode)
        let key=Self.key(document:document,historyHash:hash,budget:budget,identity:engine.binaryIdentity)
        let found=try await stored(document:document,node:node,budget:budget,identity:engine.binaryIdentity)
        // Cached evidence is engine output too: withheld while participating, like a fresh search (D8).
        try Task.checkCancellation();try fairness.requireEngineHelp()
        if let found{return copy(found,document:document,node:node,revision:revision)}
        let terminal=try autoreleasepool{try document.status(at:rootNode).terminal}
        let resources=resources,root=terminal ? EngineAnalysis(bestMove:nil,budgetMs:budget):try await engine.analyzeHistory(startFEN:document.startingFEN,moves:rootHistory,profile:.skill(20),budget:budget,multiPv:3,searchMoves:[],resources:resources)
        try Task.checkCancellation();try fairness.requireEngineHelp()
        let played:EngineAnalysis?
        if let uci=selected.uci,let line=root.lines.first(where:{$0.pv.first==uci}){played=EngineAnalysis(bestMove:uci,budgetMs:budget,lines:[line])}else if let uci=selected.uci,!terminal{played=try await engine.analyzeHistory(startFEN:document.startingFEN,moves:rootHistory,profile:.skill(20),budget:budget,multiPv:1,searchMoves:[uci],resources:resources)}else{played=nil}
        try Task.checkCancellation();try fairness.requireEngineHelp()
        let result=ReviewEvidence(schemaVersion:1,documentID:document.id,documentHash:document.contentHash,nodeID:node,historyHash:hash,revision:revision,engineVersion:engine.capabilities.name+" "+engine.binaryIdentity,options:Self.options(resources),budgetMs:budget,createdAt:Date(),root:root,played:played,quality:"provisional",provisional:true)
        if cache.count>=128,let oldest=cache.min(by:{$0.value.createdAt<$1.value.createdAt})?.key{cache.removeValue(forKey:oldest)};cache[key]=result
        if let disk{let write=writeCache,token=UUID(),task=Task.detached{_ = try? write(disk,result,key)};pendingWrites[token]=(document.id,task);await task.value;pendingWrites[token]=nil};return result
    }
    private static func key(document:GameDocument,historyHash:String,budget:Int,identity:String)->String {"v1:\(identity):\(document.contentHash):\(historyHash):\(budget):\(AnalysisPolicy.version):multipv3:played1"}
    /// `node`'s evidence at `budget` from memory or disk, if this record and engine produced it; never a search.
    private func stored(document:GameDocument,node:Int,budget:Int,identity:String)async throws -> ReviewEvidence? {
        guard !identity.isEmpty else{return nil};let hash=try document.historyHash(to:node),key=Self.key(document:document,historyHash:hash,budget:budget,identity:identity),disk=disk
        var stored=cache[key]
        if stored==nil{stored=await Task.detached{disk?.load(key)}.value}
        guard let result=stored,result.documentHash==document.contentHash,result.historyHash==hash,result.engineVersion.contains(identity) else{return nil}
        return copy(result,document:document,node:node,revision:0)
    }
}
