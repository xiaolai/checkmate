import Foundation
import Combine
public struct ReviewEvidence:Codable {
    public let schemaVersion:Int,documentID:UUID,documentHash:String,nodeID:Int,historyHash:String,revision:Int,engineVersion:String,options:[String:String],budgetMs:Int,createdAt:Date,root:EngineAnalysis,played:EngineAnalysis?,quality:String,provisional:Bool
}
public struct ReviewMoment:Codable,Identifiable {public let id:Int,expectationLoss:Double?,reason:String,provisional:Bool}
@MainActor public final class ReviewAnalyzer:ObservableObject {
    public let engine:NativeEngine
    private let disk:ReviewAnalysisCache?
    @Published public private(set) var completed=0
    @Published public private(set) var total=0
    /// Quick-pass positions whose engine search failed (not cancelled); every-position failure ends as "failed", not "ready".
    @Published public private(set) var failed=0
    @Published public private(set) var moments:[ReviewMoment]=[]
    @Published public private(set) var batchStatus="idle"
    @Published public private(set) var batchDocument:UUID?
    private var batchTask:Task<Void,Never>?,batchSearch:Task<ReviewEvidence,Error>?,generation=0,selectedCount=0
    private var cache:[String:ReviewEvidence]=[:]
    public init(engine:NativeEngine,cacheDirectory:URL?=nil){self.engine=engine;disk=cacheDirectory.map{ReviewAnalysisCache(directory:$0)}}
    public func cancelBatch(){generation+=1;batchTask?.cancel();batchSearch?.cancel();batchTask=nil;batchSearch=nil;batchStatus="cancelled"}
    public func reset(){cancelBatch();batchDocument=nil;completed=0;failed=0;total=0;moments=[];batchStatus="idle"}
    public func startBatch(_ document:GameDocument){cancelBatch();batchDocument=document.id;completed=0;failed=0;total=document.mainline.count;moments=[];batchStatus="pending";let epoch=generation
        batchTask=Task{for node in document.mainline {guard !Task.isCancelled,self.generation==epoch else{return};while self.selectedCount>0{try? await Task.sleep(nanoseconds:10_000_000);guard !Task.isCancelled,self.generation==epoch else{return}};var done=false
            while !done {guard !Task.isCancelled,self.generation==epoch else{return};while self.selectedCount>0{try? await Task.sleep(nanoseconds:10_000_000);guard !Task.isCancelled else{return}};let search=Task{try await self.compute(document:document,node:node,revision:0,budget:ReviewPolicy.quickBudget)};self.batchSearch=search
                do{let evidence=try await search.value;guard self.generation==epoch else{return};self.recordMoment(evidence,document:document);done=true}catch{if !search.isCancelled{guard self.generation==epoch else{return};self.failed+=1;done=true}}}
            self.completed+=1
        }
        guard self.generation==epoch else{return};self.batchStatus="deepening"
        let targets=Array(self.moments.prefix(ReviewPolicy.criticalMomentsToDeepen)).map(\.id)
        for node in targets {
            var finished=false
            while !finished {
                guard !Task.isCancelled,self.generation==epoch else{return}
                while self.selectedCount>0{try? await Task.sleep(for:.milliseconds(10));guard !Task.isCancelled,self.generation==epoch else{return}}
                let search=Task{try await self.comparison(document:document,node:node,revision:0,budget:ReviewPolicy.deepBudget)};self.batchSearch=search
                do{let evidence=try await search.value;guard self.generation==epoch else{return};self.recordMoment(evidence,document:document);finished=true}
                catch{if !search.isCancelled{finished=true}}
            }
        }
        guard self.generation==epoch else{return};self.batchStatus=self.total>0 && self.failed==self.total ? "failed":"ready";self.batchSearch=nil}
    }
    private func recordMoment(_ evidence:ReviewEvidence,document:GameDocument){let node=document.nodes[evidence.nodeID],root=evidence.root.lines.first,played=evidence.played?.lines.first,loss=Self.expectationLoss(root:root,played:played,mover:node.side);let forcing=node.san?.contains("x")==true || node.san?.contains("+")==true || node.san?.contains("#")==true || node.san?.contains("=")==true
        if forcing || (loss ?? 0)>ReviewQualityPolicy.interestingExpectationLoss || evidence.nodeID==document.mainline.last {moments.removeAll{$0.id==evidence.nodeID};moments.append(ReviewMoment(id:evidence.nodeID,expectationLoss:loss,reason:forcing ? "Capture, check or promotion":"Engine alternatives are worth comparing",provisional:evidence.provisional));moments.sort{($0.expectationLoss ?? 0)>($1.expectationLoss ?? 0)}}
    }
    public static func expectationLoss(root:AnalysisLine?,played:AnalysisLine?,mover:String)->Double? {guard let root=root,let played=played,root.score.bound==nil,played.score.bound==nil,let best=root.wdl,let actual=played.wdl,best.count==3,actual.count==3 else{return nil};func expected(_ wdl:[Int])->Double {Double(wdl[mover=="w" ? 0:2])+Double(wdl[1])/2};return max(0,(expected(best)-expected(actual))/1000)}
    public func analyze(document:GameDocument,node:Int,revision:Int,budget:Int=ReviewPolicy.quickBudget)async throws -> ReviewEvidence {
        selectedCount+=1;batchSearch?.cancel();defer{selectedCount-=1}
        return try await comparison(document:document,node:node,revision:revision,budget:budget)
    }
    private func comparison(document:GameDocument,node:Int,revision:Int,budget:Int)async throws -> ReviewEvidence {
        let quick=try await compute(document:document,node:node,revision:revision,budget:budget)
        // Deeper work is selected explicitly, never hidden in the quick budget.
        if budget<ReviewPolicy.deepBudget{return quick}
        let baseline=try await compute(document:document,node:node,revision:revision,budget:ReviewPolicy.quickBudget)
        let a=quick.root.lines.first,b=baseline.root.lines.first,c=quick.played?.lines.first,d=baseline.played?.lines.first
        func supported(_ deep:AnalysisLine?,_ initial:AnalysisLine?)->Bool {
            guard let deep=deep,let initial=initial,deep.depth>=ReviewQualityPolicy.minimumDepth,deep.score.bound==nil,initial.score.bound==nil,deep.score.kind==initial.score.kind else{return false}
            if deep.score.kind=="mate"{return deep.score.value==initial.score.value}
            return deep.score.kind=="cp" && abs(deep.score.value-initial.score.value)<=ReviewQualityPolicy.stableCpTolerance
        }
        let stable=a?.pv.first==b?.pv.first && supported(a,b) && (quick.played==nil || supported(c,d))
        let quality:String
        if stable,ReviewRolloutPolicy.reviewQualityLabels,let a=a,let c=c {quality=MoveQuality.compare(best:a.score,played:c.score,mover:document.nodes[node].side,stable:true)}else{quality=stable ? "unrated":"provisional"}
        return copy(quick,document:document,node:node,revision:revision,quality:quality,provisional:!stable)
    }
    public func analyzeBranch(document:GameDocument,root:Int,moves:[String],revision:Int)async throws -> ReviewEvidence {
        selectedCount+=1;batchSearch?.cancel();defer{selectedCount-=1}
        let history=try document.history(to:root)+moves,rules=try document.rules(at:root)
        for move in moves{try rules.move(uci:move)}
        let analysis=rules.over ? EngineAnalysis():try await engine.analyzeHistory(startFEN:document.startingFEN,moves:history,profile:.skill(20),budget:ReviewPolicy.quickBudget,multiPv:3)
        try Task.checkCancellation()
        return ReviewEvidence(schemaVersion:1,documentID:document.id,documentHash:document.contentHash,nodeID:root,historyHash:reviewHash(Data((document.startingFEN+"|"+history.joined(separator:" ")).utf8)),revision:revision,engineVersion:engine.capabilities.name+" "+engine.binaryIdentity,options:AnalysisPolicy.options,budgetMs:ReviewPolicy.quickBudget,createdAt:Date(),root:analysis,played:nil,quality:"provisional",provisional:true)
    }
    private func copy(_ result:ReviewEvidence,document:GameDocument,node:Int,revision:Int,quality:String?=nil,provisional:Bool?=nil)->ReviewEvidence {ReviewEvidence(schemaVersion:1,documentID:document.id,documentHash:document.contentHash,nodeID:node,historyHash:result.historyHash,revision:revision,engineVersion:result.engineVersion,options:result.options,budgetMs:result.budgetMs,createdAt:result.createdAt,root:result.root,played:result.played,quality:quality ?? result.quality,provisional:provisional ?? result.provisional)}
    private func compute(document:GameDocument,node:Int,revision:Int,budget:Int)async throws -> ReviewEvidence {
        try Task.checkCancellation();try await engine.prepare();let hash=try document.historyHash(to:node),selected=document.nodes[node],rootNode=selected.parent ?? node,rootHistory=try document.history(to:rootNode)
        let key="v1:\(engine.binaryIdentity):\(document.contentHash):\(hash):\(budget):\(AnalysisPolicy.version):multipv3:played1"
        let disk=disk
        var stored=cache[key]
        if stored==nil{stored=await Task.detached{disk?.load(key)}.value}
        try Task.checkCancellation()
        if let result=stored,result.documentHash==document.contentHash,result.historyHash==hash,result.engineVersion.contains(engine.binaryIdentity){return copy(result,document:document,node:node,revision:revision)}
        let terminal=try autoreleasepool{try document.status(at:rootNode).terminal}
        let root=terminal ? EngineAnalysis(bestMove:nil,budgetMs:budget):try await engine.analyzeHistory(startFEN:document.startingFEN,moves:rootHistory,profile:.skill(20),budget:budget,multiPv:3)
        try Task.checkCancellation()
        let played:EngineAnalysis?
        if let uci=selected.uci,let line=root.lines.first(where:{$0.pv.first==uci}){played=EngineAnalysis(bestMove:uci,budgetMs:budget,lines:[line])}else if let uci=selected.uci,!terminal{played=try await engine.analyzeHistory(startFEN:document.startingFEN,moves:rootHistory,profile:.skill(20),budget:budget,multiPv:1,searchMoves:[uci])}else{played=nil}
        try Task.checkCancellation()
        let result=ReviewEvidence(schemaVersion:1,documentID:document.id,documentHash:document.contentHash,nodeID:node,historyHash:hash,revision:revision,engineVersion:engine.capabilities.name+" "+engine.binaryIdentity,options:AnalysisPolicy.options,budgetMs:budget,createdAt:Date(),root:root,played:played,quality:"provisional",provisional:true)
        if cache.count>=128,let oldest=cache.min(by:{$0.value.createdAt<$1.value.createdAt})?.key{cache.removeValue(forKey:oldest)};cache[key]=result;try? await Task.detached{try disk?.save(result,key:key)}.value;return result
    }
}
