import Foundation
import Combine
/// Review records created from live practice. An automatic terminal board (checkmate,
/// stalemate, insufficient material, fivefold, 75-move) records its result; anything else,
/// including a claimable draw, stays unfinished.
public enum ReviewRecordSource {
    public static func data(_ rules:ChessRules)throws -> Data {Data(try rules.recordPGN().utf8)}
    public static func data(previousGame pgn:String)throws -> Data {guard !pgn.isEmpty else{return Data("*".utf8)};let rules=try ChessRules();try rules.restore(pgn);return try data(rules)}
}
@MainActor public final class ReviewTools {
    /// Explicit routing keeps practice `preview_move` / `show_preview` out of review dispatch.
    public static let methods:Set<String>=["list_review_games","open_review","get_review","select_review_position","analyze_review","get_review_analysis","cancel_review_analysis","preview_review_line","clear_review_preview","start_practice_from_review"]
    let review:ReviewController,session:GameSession,store:ReviewStore,analyzer:ReviewAnalyzer
    public var onOpen:((GameDocument)->Void)?,onPractice:(()->Void)?
    /// The app's user-activity generation. An agent open is rejected if the user chose another activity meanwhile.
    public var activityGeneration:()->Int={0}
    private struct Job {let document:UUID,node:Int,revision:Int;var status:String,evidence:ReviewEvidence?,task:Task<Void,Never>?}
    private var jobs:[String:Job]=[:]
    private var runningJobs:Set<String>=[]
    private var documentObservation:AnyCancellable?
    var jobStatuses:[String] {jobs.values.map(\.status)}
    var runningJobTasks:Int {runningJobs.count}
    public init(review:ReviewController,session:GameSession,store:ReviewStore,analyzer:ReviewAnalyzer){self.review=review;self.session=session;self.store=store;self.analyzer=analyzer
        // Jobs belong to one open review: closing, returning to the game, leaving for another activity or switching document cancels them.
        documentObservation=review.$document.dropFirst().sink{[weak self] _ in self?.reset()}
    }
    public func reset(){for (id,var job) in jobs where job.task != nil || job.status=="pending"{job.task?.cancel();job.status="cancelled";job.task=nil;jobs[id]=job}}
    private func identity(_ args:[String:Any])throws {guard let d=review.document,args["documentId"] as? String==d.id.uuidString,args["reviewRevision"] as? Int==review.revision,args["nodeId"] as? Int==review.nodeID else{throw ProtocolFailure("STALE_REVIEW")}}
    private func page(_ args:[String:Any],count:Int)throws -> (Int,Int) {
        let offset=args["offset"] as? Int ?? 0,limit=args["limit"] as? Int ?? ReviewPolicy.pageSize
        guard offset>=0,offset<=count,limit>=1,limit<=ReviewPolicy.maximumPageSize else{throw ProtocolFailure("INVALID_ARGUMENT")};return (offset,limit)
    }
    public func call(_ name:String,args:[String:Any])async throws -> Any {
        if name=="list_review_games" {let store=store;let records=try await Task.detached{try store.list()}.value;let (offset,limit)=try page(args,count:records.count);return ["schemaVersion":1,"games":records.dropFirst(offset).prefix(limit).map{jsonObject($0)},"nextOffset":offset+limit<records.count ? offset+limit as Any:NSNull()]}
        if name=="open_review" {guard ReviewRolloutPolicy.reviewEnabled else{throw ProtocolFailure("FEATURE_DISABLED")};
            let expected=review.revision,activity=activityGeneration();guard !review.active || args["expectedReviewRevision"] as? Int==expected else{throw ProtocolFailure("STALE_REVIEW")}
            func current()->Bool {review.revision==expected && activityGeneration()==activity}
            let document:GameDocument;var saved:SavedReview?
            switch args["source"] as? String {case "saved":guard let id=UUID(uuidString:args["gameId"] as? String ?? "") else{throw ProtocolFailure("INVALID_ARGUMENT")};let store=store;let record=try await Task.detached{try store.load(id)}.value;saved=record;document=record.document
            case "current":document=try PGNImporter.parse(ReviewRecordSource.data(session.rules),provenance:"Current game")[0]
            case "paste":guard let text=args["text"] as? String else{throw ProtocolFailure("INVALID_ARGUMENT")};let token=ReviewImportCancellation();let data=Data(text.utf8);let documents=try await withTaskCancellationHandler(operation:{try await Task.detached{try PGNImporter.parse(data,cancelled:{token.cancelled})}.value},onCancel:{token.cancel()});let index=args["record"] as? Int ?? 0;guard documents.indices.contains(index) else{throw ProtocolFailure("INVALID_ARGUMENT")};document=documents[index]
            default:throw ProtocolFailure("INVALID_ARGUMENT")}
            // Re-check after every await, before and after staging the new record; a rejected
            // open removes the record it staged so no orphan appears in the library.
            guard current() else{throw ProtocolFailure("STALE_REVIEW")}
            let store=store
            if saved==nil{try await Task.detached{try store.save(document,cursor:0,branches:[])}.value
                guard current() else{let id=document.id;_ = await Task.detached{try? store.delete(id)}.value;throw ProtocolFailure("STALE_REVIEW")}}
            reset();if let onOpen=onOpen{onOpen(document)}else{review.open(document,practice:session)};if let saved=saved{try review.restoreSaved(cursor:saved.cursor,branches:saved.branches)};return review.projection()
        }
        try identity(args)
        guard let document=review.document else{throw ProtocolFailure("UNSUPPORTED_MODE")}
        switch name {
        case "get_review":let (offset,limit)=try page(args,count:document.nodes.count);guard offset==0 || args["pageIdentity"] as? String==document.contentHash else{throw ProtocolFailure("STALE_REVIEW")};var projection=review.projection();projection["moves"]=document.nodes.dropFirst(offset).prefix(limit).map{jsonObject($0)};projection["nextOffset"]=offset+limit<document.nodes.count ? offset+limit as Any:NSNull();projection["pageIdentity"]=document.contentHash;return projection
        case "select_review_position":guard let target=args["targetNode"] as? Int else{throw ProtocolFailure("INVALID_ARGUMENT")};try review.select(target);return review.projection()
        case "preview_review_line":guard let moves=args["moves"] as? [String] else{throw ProtocolFailure("INVALID_ARGUMENT")};try review.previewLine(moves);review.seekBranch(0);return review.projection()
        case "clear_review_preview":review.clearBranch();return review.projection()
        case "start_practice_from_review":guard review.practiceForkAvailable else{throw ProtocolFailure("GAME_OVER")};onPractice?();return ["confirmationRequired":true,"message":"Use the app's side/profile and backup confirmation to create a separate practice game."]
        case "analyze_review":if let existing=jobs.first(where:{$0.value.document==document.id && $0.value.node==review.nodeID && $0.value.revision==review.revision && $0.value.status=="pending"}){return ["jobId":existing.key,"status":"pending","evidenceVersion":1]};guard jobs.values.filter({$0.status=="pending"}).count<2 else{throw ProtocolFailure("BUSY")};let id=UUID().uuidString,node=review.nodeID,revision=review.revision;let branch=review.branch,branchPly=review.branchPly;runningJobs.insert(id);let task=Task{defer{runningJobs.remove(id)};do{guard review.document?.id==document.id,review.revision==revision else{throw CheckmateError.cancelled};let evidence:ReviewEvidence;if let branch=branch{evidence=try await analyzer.analyzeBranch(document:document,root:branch.root,moves:Array(branch.moves.prefix(branchPly)),revision:revision)}else{evidence=try await analyzer.analyze(document:document,node:node,revision:revision)};guard !Task.isCancelled,review.document?.id==document.id,review.revision==revision else{jobs[id]?.status="cancelled";return};jobs[id]?.evidence=evidence;jobs[id]?.status="ready"}catch{if jobs[id]?.status != "cancelled"{jobs[id]?.status=Task.isCancelled ? "cancelled":"failed"}};jobs[id]?.task=nil};jobs[id]=Job(document:document.id,node:node,revision:revision,status:"pending",evidence:nil,task:task);if jobs.count>128,let stale=jobs.first(where:{$0.value.status != "pending"})?.key{jobs.removeValue(forKey:stale)};return ["jobId":id,"status":"pending","evidenceVersion":1]
        case "get_review_analysis":guard let id=args["jobId"] as? String,let job=jobs[id],job.document==document.id,job.node==review.nodeID,job.revision==review.revision else{throw ProtocolFailure("STALE_REVIEW")};return ["jobId":id,"status":job.status,"evidenceVersion":1,"evidence":job.evidence.map{jsonObject($0)} ?? NSNull()]
        case "cancel_review_analysis":guard let id=args["jobId"] as? String,jobs[id]?.document==document.id else{throw ProtocolFailure("INVALID_ARGUMENT")};jobs[id]?.task?.cancel();jobs[id]?.status="cancelled";return ["jobId":id,"status":"cancelled"]
        default:throw ProtocolFailure("INVALID_ARGUMENT")}
    }
}
public extension ReviewController {
    func projection()->[String:Any] {guard let d=document else{return ["schemaVersion":1,"active":false]};return ["schemaVersion":1,"active":true,"documentId":d.id.uuidString,"documentHash":d.contentHash,"reviewRevision":revision,"nodeId":nodeID,"displayIdentity":identity,"fen":displayFEN as Any? ?? NSNull(),"original":branch==nil,"result":d.result,"termination":d.termination as Any? ?? NSNull(),"historyAvailable":d.historyAvailable,"totalNodes":d.nodes.count,"explanation":explanation.map{jsonObject($0)} ?? NSNull(),"analysisStatus":analysisStatus]}
}
