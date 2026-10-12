import CheckmateAssets
import CheckmateDomain
import CheckmateRules
import Foundation
/// The exact bounded search for Increment B objectives (plan: exact bounded search), run in its own chess.js runtime
/// with `training-search.js`. It certifies published teaching graphs offline; at runtime the app plays the immutable
/// validated graph and never searches. Exhaustion is an error: nothing partial is ever certified.
@MainActor public final class TrainingContinuationValidator {
    /// Every search for one scenario together (all teaching nodes, replies and quiescence) stays within this many
    /// positions, each produced by one make-move.
    public static let nodeCap=32000
    struct Classification:Decodable {let exhausted:Bool,nodes:Int,accepted:[String]?,rejected:[String]?,replies:[String:String]?}
    struct Holds:Decodable {let exhausted:Bool,holds:Bool?,nodes:Int}
    struct Exchange:Decodable {let exhausted:Bool,sign:Int?,nodes:Int?}
    struct Threat {let accepted:[String],rejected:[String],replies:[String:String],opponentThreat:Bool}
    struct Danger:Decodable {let exhausted:Bool,danger:Bool?,nodes:Int?}
    private let runtime:any ChessScriptRuntime
    /// Positions searched so far for the scenario being certified.
    public private(set) var nodes=0
    public let cap:Int
    public init(cap:Int=TrainingContinuationValidator.nodeCap,runtimeFactory:(() throws -> any ChessScriptRuntime)?=nil)throws {
        self.cap=cap
        runtime=try (runtimeFactory ?? {try JavaScriptCoreChessRuntime()})()
        _ = try runtime.evaluate(try String(contentsOf:NativeResources.url("training-search.js"),encoding:.utf8)+";0")
        guard try runtime.evaluate("typeof TrainingSearch")=="object" else{throw CheckmateError.unavailable("The training search could not load.")}
    }
    private func call<T:Decodable>(_ function:String,_ spec:[String:Any],as type:T.Type)throws -> T {
        let literal=String(decoding:try JSONSerialization.data(withJSONObject:spec,options:[.sortedKeys]),as:UTF8.self)
        let text=try runtime.evaluate("(()=>{try{return JSON.stringify({ok:true,value:TrainingSearch.\(function)(\(literal))})}catch(e){return JSON.stringify({ok:false,error:String(e)})}})()")
        guard let data=text.data(using:.utf8),let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw CheckmateError.invalid("The training search returned nothing.")}
        guard object["ok"] as? Bool==true,let value=object["value"] else{throw CheckmateError.invalid("Training search failed: \(object["error"] as? String ?? "unknown error")")}
        return try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value))
    }
    private func spend(_ used:Int,exhausted:Bool)throws {
        nodes+=used
        guard !exhausted,nodes<=cap else{throw CheckmateError.invalid("the search exceeded \(cap) positions, so nothing is certified")}
    }
    private func spec(_ scenario:TrainingScenario,line:[String],plies:Int)->[String:Any] {
        var goal:[String:Any]=["kind":scenario.goal?.kind.rawValue ?? "gain","threshold":scenario.goal?.threshold ?? 1,"drawOK":scenario.goal?.drawOK ?? false]
        if let target=scenario.goal?.target{goal["target"]=target}
        return ["fen":scenario.fen ?? "","prelude":scenario.prelude ?? [],"learner":scenario.learner,"goal":goal,"line":line,"plies":plies,"cap":max(1,cap-nodes)]
    }
    /// The complete classification of the learner's moves at one node, `plies` before quiescence.
    func classify(_ scenario:TrainingScenario,line:[String]=[],plies:Int)throws -> (accepted:Set<String>,rejected:Set<String>,replies:[String:String]) {
        let result=try call("evaluate",spec(scenario,line:line,plies:plies),as:Classification.self)
        try spend(result.nodes,exhausted:result.exhausted)
        return (Set(result.accepted ?? []),Set(result.rejected ?? []),result.replies ?? [:])
    }
    /// The same recurrence without cut-offs, for parity checks on tiny reference boards. A reference, never a
    /// certification: it searches within the full `cap` on its own and is not counted in `nodes`.
    func bruteAccepted(_ scenario:TrainingScenario,line:[String]=[],plies:Int)throws -> Set<String> {
        struct Brute:Decodable {let accepted:[String],nodes:Int}
        var request=spec(scenario,line:line,plies:plies);request["cap"]=cap
        return Set(try call("brute",request,as:Brute.self).accepted)
    }
    /// Whether the goal still holds after `line` with `plies` left.
    func holds(_ scenario:TrainingScenario,line:[String],plies:Int)throws -> Bool {
        let result=try call("holds",spec(scenario,line:line,plies:plies),as:Holds.self)
        try spend(result.nodes,exhausted:result.exhausted)
        guard let holds=result.holds else{throw CheckmateError.invalid("The training search returned no result.")}
        return holds
    }
    /// The sign of the stated line's resolved material change for the learner: 1, 0 or -1.
    public func exchangeSign(_ scenario:TrainingScenario)throws -> Int {
        var request=spec(scenario,line:[],plies:0);request["stated"]=scenario.stated ?? []
        let result=try call("exchange",request,as:Exchange.self)
        try spend(result.nodes ?? 0,exhausted:result.exhausted)
        guard let sign=result.sign else{throw CheckmateError.invalid("The exchange could not be resolved.")}
        return sign
    }
    func threat(_ scenario:TrainingScenario,create:Bool)throws -> Threat {
        struct Found:Decodable {let exhausted:Bool,nodes:Int,accepted:[String]?,rejected:[String]?,replies:[String:String]?,opponentThreat:Bool?}
        var request=spec(scenario,line:[],plies:0);request["kind"]=create ? "create":"prevent"
        let result=try call("threat",request,as:Found.self)
        try spend(result.nodes,exhausted:result.exhausted)
        guard let accepted=result.accepted,let rejected=result.rejected,let replies=result.replies,let opponentThreat=result.opponentThreat else{throw CheckmateError.invalid("The training search returned no result.")}
        return Threat(accepted:accepted,rejected:rejected,replies:replies,opponentThreat:opponentThreat)
    }
    /// Whether one of the learner's pieces is in danger (see `TrainingSearch.danger`); nil when in check.
    func danger(_ scenario:TrainingScenario)throws -> Bool? {
        let result=try call("danger",spec(scenario,line:[],plies:0),as:Danger.self)
        try spend(result.nodes ?? 0,exhausted:result.exhausted)
        return result.danger
    }
    /// Re-derives a searched teaching graph exactly (plan: exact bounded search, multi-move runtime): each node's
    /// accepted set equals the search's, each reply is legal and does what it claims (a refutation defeats the
    /// move, a testing reply leaves the goal reachable), and every continuation node is reached by its reply.
    func certifyGraph(_ scenario:TrainingScenario,runtimeFactory:(() throws -> any ChessScriptRuntime)?)throws {
        guard let nodes=scenario.nodes,let plies=scenario.plies else{throw CheckmateError.invalid("missing teaching graph")}
        var visited=Set<Int>()
        func certify(_ index:Int,line:[String],plies:Int)throws {
            guard visited.insert(index).inserted else{throw CheckmateError.invalid("teaching node \(index) is reached twice")}
            let node=nodes[index]
            let legality=try TrainingLegality(fen:scenario.fen ?? "",prelude:(scenario.prelude ?? [])+line,runtimeFactory:runtimeFactory)
            guard try legality.fingerprint()==node.fingerprint else{throw CheckmateError.invalid("teaching node \(index) fingerprint differs from the position")}
            let found=try classify(scenario,line:line,plies:plies)
            guard Set(node.accepted)==found.accepted,node.accepted.count==found.accepted.count else{throw CheckmateError.invalid("node \(index) accepted moves differ from the search: \(found.accepted.sorted())")}
            guard Set(node.replies.keys)==Set(found.replies.keys) else{throw CheckmateError.invalid("node \(index) shows replies for different moves than the search")}
            for (move,reply) in node.replies {
                let keeps=try holds(scenario,line:line+[move,reply],plies:max(0,plies-2))
                guard keeps==found.accepted.contains(move) else{throw CheckmateError.invalid("node \(index): \(reply) after \(move) does not \(keeps ? "refute it":"keep the goal reachable")")}
            }
            for (move,next) in node.next ?? [:] {
                guard plies>=3,let reply=node.replies[move] else{throw CheckmateError.invalid("node \(index) continues past the horizon or without a reply")}
                try certify(next,line:line+[move,reply],plies:plies-2)
            }
        }
        try certify(0,line:[],plies:plies)
        guard visited.count==nodes.count else{throw CheckmateError.invalid("unreachable teaching nodes")}
    }
}
