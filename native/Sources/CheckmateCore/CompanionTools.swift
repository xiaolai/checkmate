import Foundation
import CoreFoundation
public struct ProtocolFailure:Error {public let code:String,message:String;public init(_ code:String,_ message:String?=nil){self.code=code;self.message=message ?? code};public var result:[String:Any]{["error":["code":code,"message":message]]}}
public struct ToolSchemas {
    private let schemas:[String:[String:Any]]
    public init() throws {schemas=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("tool-schemas.json"))) as! [String:[String:Any]]}
    public var names:[String] {Array(schemas.keys).sorted()}
    public func parse(_ name:String,args:[String:Any]) throws -> [String:Any] {guard let schema=schemas[name] else{throw ProtocolFailure("INVALID_ARGUMENT")};return try Self.validateValue(args,schema:schema) as! [String:Any]}
    public static func validateValue(_ value:Any,schema:[String:Any]) throws -> Any {
        func fail() throws -> Never {throw ProtocolFailure("INVALID_ARGUMENT","Arguments do not match the tool schema.")}
        if let values=schema["enum"] as? [String],let text=value as? String,!values.contains(text){try fail()}
        switch schema["type"] as? String {
        case "object":guard var object=value as? [String:Any] else{try fail()};let properties=schema["properties"] as? [String:[String:Any]] ?? [:]
            if schema["additionalProperties"] as? Bool==false,!Set(object.keys).isSubset(of:Set(properties.keys)){try fail()}
            for key in schema["required"] as? [String] ?? [] where object[key]==nil {try fail()}
            for (key,s) in properties {if let v=object[key]{object[key]=try Self.validateValue(v,schema:s)}else if let v=s["default"]{object[key]=v}}
            return object
        case "string":guard let text=value as? String else{try fail()};let count=text.utf16.count;if count<(schema["minLength"] as? Int ?? 0) || count>(schema["maxLength"] as? Int ?? Int.max){try fail()};if let pattern=schema["pattern"] as? String,text.range(of:pattern,options:.regularExpression)==nil{try fail()};return text
        case "integer","number":guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite else{try fail()};let n=number.doubleValue;if schema["type"] as? String=="integer",floor(n) != n{try fail()};if n<(schema["minimum"] as? Double ?? -Double.greatestFiniteMagnitude)||n>(schema["maximum"] as? Double ?? Double.greatestFiniteMagnitude){try fail()};return value
        case "boolean":guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{try fail()};return value
        case "array":guard let array=value as? [Any],array.count>=(schema["minItems"] as? Int ?? 0),array.count<=(schema["maxItems"] as? Int ?? Int.max) else{try fail()};let tuple=(schema["prefixItems"] as? [[String:Any]]) ?? (schema["items"] as? [[String:Any]]);return try array.enumerated().map {i,v in if let tuple=tuple,tuple.indices.contains(i){return try Self.validateValue(v,schema:tuple[i])};if let s=schema["items"] as? [String:Any]{return try Self.validateValue(v,schema:s)};if schema["items"] as? Bool==false{try fail()};return v}
        default:return value
        }
    }
}
@MainActor public final class CompanionTools {
    public let session:GameSession,schemas:ToolSchemas
    public var reviewTools:ReviewTools?
    private var waiting=false
    private var receipts:[String:(payload:String,time:Date,task:Task<Any,Error>)]=[:]
    public init(session:GameSession) throws {self.session=session;schemas=try ToolSchemas()}
    private func access(_ lease:String) throws {if session.voiceLease==lease{return};guard session.companionEnabled else{throw ProtocolFailure("DISABLED")};guard !session.suspended else{throw ProtocolFailure("APP_SUSPENDED")};guard session.companionLease==lease else{throw ProtocolFailure("NOT_CONNECTED")}}
    private func observed(_ a:[String:Any]) throws {guard a["sessionId"] as? String==session.sessionId,a["revision"] as? Int==session.revision else{throw ProtocolFailure("STALE_STATE")}}
    public func reset(){reviewTools?.reset();for r in receipts.values{r.task.cancel()};receipts.removeAll()}
    public func call(_ name:String,args:[String:Any],lease:String) async throws -> Any {
        try access(lease);let a=try schemas.parse(name,args:args);try Task.checkCancellation()
        if name=="get_session"{return session.publicState()}
        if name=="list_review_games"{guard let tools=reviewTools else{throw ProtocolFailure("UNSUPPORTED_MODE")};return try await tools.call(name,args:a)}
        if name=="get_turn_brief"{guard session.mode == .practice else{throw ProtocolFailure("UNSUPPORTED_MODE")};return ["state":session.publicState(),"facts":turnFacts()]}
        if name=="wait_for_change"{return try await wait(a,lease:lease)}
        if let id=a["requestId"] as? String {
            receipts=receipts.filter{Date().timeIntervalSince($0.value.time)<600};let key=lease+":"+id,payload=String(decoding:try JSONSerialization.data(withJSONObject:["name":name,"args":a],options:.sortedKeys),as:UTF8.self)
            if let r=receipts[key]{guard r.payload==payload else{throw ProtocolFailure("INVALID_ARGUMENT","Request ID was used for different arguments.")};return try await r.task.value}
            let task=Task{try await self.perform(name,args:a,lease:lease)};receipts[key]=(payload,Date(),task)
            if receipts.count>256,let oldest=receipts.min(by:{$0.value.time<$1.value.time})?.key{receipts[oldest]=nil}
            return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
        }
        return try await perform(name,args:a,lease:lease)
    }
    private func perform(_ name:String,args a:[String:Any],lease:String) async throws -> Any {
        try observed(a);try Task.checkCancellation()
        if ReviewTools.methods.contains(name) {guard let tools=reviewTools else{throw ProtocolFailure("UNSUPPORTED_MODE")};return try await tools.call(name,args:a)}
        if session.reviewSuspended,let review=session.reviewController,review.active,["show_annotation","clear_annotations"].contains(name) {
            guard a["positionId"] as? String==session.positionId,a["displayIdentity"] as? String==review.identity else{throw ProtocolFailure("STALE_STATE","The displayed review identity is required.")}
            if name=="show_annotation"{let highlights=try JSONDecoder().decode([Highlight].self,from:JSONSerialization.data(withJSONObject:a["highlights"] ?? []));review.annotate(arrows:a["arrows"] as? [[String]] ?? [],highlights:highlights,ttl:a["ttlMs"] as? Int ?? 15000)}else{review.clearAnnotations()}
            return ["positionId":session.positionId,"displayIdentity":review.identity,"hypothetical":review.branch != nil]
        }
        guard !session.reviewSuspended else{throw ProtocolFailure("REVIEW_ACTIVE","Use scoped review tools for the displayed review board.")}
        if name=="show_annotation" || name=="clear_annotations" {
            guard a["positionId"] as? String==session.positionId else{throw ProtocolFailure("STALE_STATE")}
            guard session.mode == .practice || session.lesson?.pieces != nil else{throw ProtocolFailure("UNSUPPORTED_MODE")}
            if session.lesson?.moving==true{throw ProtocolFailure("BOARD_IN_MOTION")}
            if name=="show_annotation" {
                if let id=a["demonstrationId"] as? String,id != session.demonstration?.id{throw ProtocolFailure("STALE_STATE")}
                if let identity=a["displayIdentity"] as? String,identity != session.displayIdentity{throw ProtocolFailure("STALE_STATE")}
                if !session.presentationHidden,session.preview != nil,a["displayIdentity"] as? String != session.displayIdentity{throw ProtocolFailure("STALE_STATE")}
                if !session.presentationHidden,let d=session.demonstration,a["displayIdentity"]==nil {guard a["demonstrationId"] as? String==d.id,a["line"] as? Int==d.line,a["ply"] as? Int==d.ply else{throw ProtocolFailure("STALE_STATE")}}
                let h=try JSONDecoder().decode([Highlight].self,from:JSONSerialization.data(withJSONObject:a["highlights"] ?? []));session.annotate(arrows:a["arrows"] as? [[String]] ?? [],highlights:h,ttl:a["ttlMs"] as? Int ?? 15000)
            }else{session.clearAnnotations();session.emit(semantic:false)}
            return ["positionId":session.positionId,"overlayRevision":session.overlayRevision]
        }
        guard session.mode == .practice else{throw ProtocolFailure("UNSUPPORTED_MODE")}
        switch name {
        case "get_legal_moves":return ["revision":session.revision,"moves":session.rules.moves(a["from"] as? String).map {m -> [String:Any] in var d:[String:Any]=["from":m.from,"to":m.to,"san":m.san,"uci":m.uci];if let p=m.promotion{d["promotion"]=p};return d},"gameOver":session.rules.over]
        case "inspect_piece":let r=(a["target"] as? String)=="display" ? try ChessRules(fen:session.displayFen):session.rules;return ["positionId":session.positionId,"display":session.publicState()["display"]!,"inspection":(try? r.inspect(a["square"] as! String)).map{jsonObject($0)} ?? NSNull()]
        case "analyze_position":if session.rules.over{return ["revision":session.revision,"gameOver":true,"lines":[]]};let analysis=try await session.analyze(budget:a["movetimeMs"] as? Int ?? 350,multiPv:a["multiPv"] as? Int ?? 1);try access(lease);try observed(a);return ["revision":session.revision,"analysis":jsonObject(analysis)]
        case "preview_move":let evaluation=try await session.evaluateCandidate(from:a["from"] as! String,to:a["to"] as! String,promotion:a["promotion"] as? String ?? "q");try access(lease);try observed(a);var result=jsonObject(evaluation) as! [String:Any];result["positionId"]=session.positionId;return result
        case "show_preview":guard session.preview?.evaluation != nil else{throw ProtocolFailure("PREVIEW_NOT_READY")};guard a["positionId"] as? String==session.positionId,a["previewId"] as? String==session.preview?.id else{throw ProtocolFailure("STALE_STATE")};try session.previewAt(ply:a["ply"] as! Int,line:a["line"] as! String);return ["hypothetical":true,"positionId":session.positionId,"line":session.preview!.line,"ply":session.preview!.ply,"fen":session.preview!.displayFen]
        case "demonstrate_line":guard a["positionId"] as? String==session.positionId else{throw ProtocolFailure("STALE_STATE")};guard !session.busy || session.busyReason=="analysis" else{throw ProtocolFailure("BUSY")};let lines=try JSONDecoder().decode([DemoLineInput].self,from:JSONSerialization.data(withJSONObject:a["lines"]!));try session.demonstrate(title:a["title"] as! String,introduction:a["introduction"] as? String ?? "",lines:lines,autoplay:a["autoplay"] as? Bool ?? false);return ["hypothetical":true,"positionId":session.positionId,"demonstration":jsonObject(session.demonstration!)]
        case "control_demonstration":guard a["positionId"] as? String==session.positionId,a["demonstrationId"] as? String==session.demonstration?.id else{throw ProtocolFailure("STALE_STATE")};let action=a["action"] as! String;if action=="seek"{guard let ply=a["ply"] as? Int else{throw ProtocolFailure("INVALID_ARGUMENT")};try session.seekDemo(line:a["line"] as? Int ?? session.demonstration!.line,ply:ply)}else{guard a["line"]==nil,a["ply"]==nil else{throw ProtocolFailure("INVALID_ARGUMENT")};switch action{case "play":session.playDemo();case "pause":session.pauseDemo();default:session.closePresentation()}};return ["hypothetical":true,"positionId":session.positionId,"demonstration":session.demonstration.map{jsonObject($0)} ?? NSNull()]
        case "play_move":guard session.companionEnabled,session.companionRole=="opponent",session.rules.turn=="b" else{throw ProtocolFailure("ROLE_FORBIDDEN","Only the opponent can request a Black move.")};guard session.demonstration==nil else{throw ProtocolFailure("PRESENTATION_ACTIVE")};guard !session.rules.over else{throw ProtocolFailure("GAME_OVER")};guard let engine=session.engine else{throw ProtocolFailure("ENGINE_UNAVAILABLE")};let result=try await engine.analyze(fen:session.rules.fen,skill:session.state.settings.skill,budget:500,multiPv:1);try Task.checkCancellation();try access(lease);try observed(a);guard let best=result.bestMove else{throw ProtocolFailure("ENGINE_UNAVAILABLE")};let move=try session.commitBlack(best);return ["uci":move.uci,"san":move.san,"state":session.publicState()]
        default:throw ProtocolFailure("INVALID_ARGUMENT")
        }
    }
    private func wait(_ a:[String:Any],lease:String) async throws -> Any {
        func matches()->Bool {switch a["event"] as? String ?? "any" {case "learner_turn":return session.mode == .practice && session.rules.records.last?.color=="b";case "coaching":return session.mode == .practice && (["ready","error"].contains(session.preview?.status ?? "") || session.preview==nil && ["ready","error"].contains(session.coaching.status));default:return true}}
        let cursor=a["cursor"] as! Int,oldSession=a["sessionId"] as! String
        if oldSession != session.sessionId || cursor<session.cursor && matches(){return ["changed":true,"resyncRequired":oldSession != session.sessionId || session.cursor-cursor>128,"state":session.publicState()]}
        guard cursor<=session.cursor else{throw ProtocolFailure("INVALID_ARGUMENT")};guard !waiting else{throw ProtocolFailure("BUSY")};waiting=true;defer{waiting=false}
        let end=Date().addingTimeInterval(Double(a["timeoutMs"] as? Int ?? 20000)/1000)
        while Date()<end {try Task.checkCancellation();try access(lease);if session.cursor>cursor && matches(){return ["changed":true,"state":session.publicState()]};await session.waitForEvent(until:end)}
        return ["changed":false,"state":session.publicState()]
    }
    public func turnFacts()->[String:Any] {
        var facts=jsonObject(session.boardFacts(session.rules)) as! [String:Any];facts["summary"]=session.turnSummary();facts["lastMoves"]=session.rules.records.suffix(2).map{m in ["san":m.san,"from":m.from,"to":m.to,"piece":m.piece,"color":m.color,"captured":m.captured as Any? ?? NSNull()]}
        if let last=session.rules.records.last {let attacked=ChessRules.squares.filter{session.rules.attackers($0,last.color).contains(last.to)};facts["lastMoveEffects"]=["from":last.from,"to":last.to,"piece":last.piece,"color":last.color,"attacksFromDestination":attacked,"opponentLegalMovesToAttackedSquares":session.rules.moves().filter{attacked.contains($0.to)}.map{["from":$0.from,"to":$0.to,"piece":$0.piece,"san":$0.san]},"semantics":"Attacked squares can still be legal destinations. These effects do not establish why the move was chosen. Listed replies are immediate legal moves, not future routes."]}else{facts["lastMoveEffects"]=NSNull()};return facts
    }
}
