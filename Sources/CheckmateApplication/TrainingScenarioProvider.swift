import CheckmateDomain
import CheckmateAssets
import CheckmateSupport
import Foundation
/// Whether material is new to the learner. Exhausted unseen material is labelled `repeat`, never fresh (plan rule 10).
public enum TrainingFreshness:String,Codable {case new,reserve,`repeat`}
/// Chooses the next concrete scenario for an entry: generated boards from a seed, or curated positions from the
/// practice pool, then the reserved clusters, then labelled repeats.
@MainActor public final class TrainingScenarioProvider {
    public enum Choice:Equatable {case scenario(TrainingScenario,TrainingFreshness),exhausted}
    public let catalog:TrainingCatalog
    private let curated:[String:[TrainingScenario]]
    /// Scenarios withdrawn this session after a runtime validation failure; they are never shown or scored.
    private var suspended=Set<String>()
    public init(catalog:TrainingCatalog,scenarios:[TrainingScenario])throws {
        try catalog.validate();self.catalog=catalog
        for scenario in scenarios {guard let definition=catalog.entry(scenario.entry) else{throw CheckmateError.invalid("Scenario \(scenario.id) names an unknown entry.")};try scenario.validateStructure(for:definition)}
        guard Set(scenarios.map(\.id)).count==scenarios.count else{throw CheckmateError.invalid("Duplicate training scenario identifiers.")}
        curated=Dictionary(grouping:scenarios,by:\.entry)
    }
    struct Published:Decodable {let schemaVersion:Int,scenarios:[TrainingScenario]}
    struct Manifest:Decodable {let schemaVersion:Int,contentVersion:Int,validatorVersion:Int,chessJS:String,trainingSearch:String,files:[String:String]}
    /// The bundled catalog and scenarios. The manifest pins the validator version, the chess.js and training search
    /// the content was validated against, and the exact catalog and scenario files that passed; a mismatch fails
    /// loudly instead of trusting stale answers.
    public static func bundled()throws -> TrainingScenarioProvider {
        let manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:NativeResources.url("training/manifest.json")))
        guard manifest.schemaVersion==1,manifest.validatorVersion==TrainingValidationService.validatorVersion else{throw CheckmateError.invalid("Training content was validated by another validator version.")}
        guard try reviewFileHash(NativeResources.url("chess.js"))==manifest.chessJS else{throw CheckmateError.invalid("Training content was validated against another chess.js; revalidate it.")}
        guard try reviewFileHash(NativeResources.url("training-search.js"))==manifest.trainingSearch else{throw CheckmateError.invalid("Training content was validated against another training search; revalidate it.")}
        // Each file is hashed from the very bytes that are then decoded.
        func validated(_ name:String)throws -> Data {
            let data=try Data(contentsOf:NativeResources.url("training/"+name))
            guard let pinned=manifest.files[name],reviewHash(data)==pinned else{throw CheckmateError.invalid("Training \(name) is not the validated file; revalidate the content.")}
            return data
        }
        let catalog=try JSONDecoder().decode(TrainingCatalog.self,from:try validated("catalog.json"))
        guard catalog.contentVersion==manifest.contentVersion else{throw CheckmateError.invalid("The training catalog's content version differs from the validated content.")}
        let published=try JSONDecoder().decode(Published.self,from:try validated("scenarios.json"))
        guard published.schemaVersion==1 else{throw CheckmateError.invalid("Unsupported training scenario version.")}
        return try TrainingScenarioProvider(catalog:catalog,scenarios:published.scenarios)
    }
    public func scenarios(for entry:String)->[TrainingScenario] {curated[entry] ?? []}
    /// An entry's published scenarios that are not suspended.
    public func liveScenarios(for entry:String)->[TrainingScenario] {scenarios(for:entry).filter{!suspended.contains($0.id)}}
    public func scenario(_ id:String)->TrainingScenario? {curated.values.lazy.flatMap{$0}.first{$0.id==id && !self.suspended.contains(id)}}
    /// The normal-chess case that contrasts with an existing game's simplified rules, shared by its rule family.
    public func bridge(for kind:MiniGameKind)->TrainingScenario? {curated.values.lazy.flatMap{$0}.filter{$0.bridge==kind.bridgeFamily && !self.suspended.contains($0.id)}.min{$0.id<$1.id}}
    public static let generated:Set<TrainingObjectiveKind>=[.reachTarget,.findAttackers,.findDefenders]
    /// Legacy games are always available; generated tasks need their generator; curated tasks need content.
    public func available(_ definition:TrainingEntryDefinition)->Bool {
        definition.objective == .legacyGame || Self.generated.contains(definition.objective) || scenarios(for:definition.id).contains{!suspended.contains($0.id)}
    }
    public func suspend(_ id:String){suspended.insert(id)}
    /// The next scenario. `seen` holds the novelty clusters the learner has already practised for this entry.
    public func next(for definition:TrainingEntryDefinition,seen:Set<String>,seed:UInt64,tier:Int=1,variant:String?=nil,previous:TrainingSkill?=nil)->Choice {
        // An explicit variant must be one the entry offers; only nil leaves the choice to the seed.
        if let variant,!definition.variants.contains(variant){return .exhausted}
        var random=TrainingRandom(seed:seed)
        switch definition.objective {
        case .reachTarget,.findAttackers,.findDefenders:
            let tier=max(1,min(definition.tiers,tier)),color:Character=random.chance(1,in:2) ? "w":"b"
            // A few fresh seeds before giving up: each is itself capped at 64 candidates.
            for attempt in 0..<4 {
                let draw=random.next() &+ UInt64(attempt)
                let made:TrainingScenario?
                switch definition.objective {
                case .reachTarget:let piece=variant.flatMap{name in TrainingGenerator.pieceNames.first{$0.value==name}?.key} ?? random.pick(["p","n","b","r","q","k"]);made=TrainingGenerator.reachTarget(seed:draw,tier:tier,color:color,piece:piece)
                case .findAttackers:made=TrainingGenerator.findAttackers(seed:draw,tier:tier,color:color)
                default:made=TrainingGenerator.findDefenders(seed:draw,tier:tier,color:color)
                }
                // A suspended (withdrawn) generated scenario is skipped like a failed draw.
                if let made,!suspended.contains(made.id){return .scenario(made,seen.contains(made.cluster) ? .repeat:.new)}
            }
            return .exhausted
        default:
            let pool=scenarios(for:definition.id).filter{!suspended.contains($0.id) && (variant==nil || $0.variant==variant)}
            guard !pool.isEmpty else{return .exhausted}
            let start=Int(random.next() % UInt64(pool.count)),cycle=Array(pool[start...]+pool[..<start])
            let rotated=definition.objective == .mixedPractice ? TrainingMixedController.order(cycle,seen:seen,previous:previous):cycle
            if let fresh=rotated.first(where:{$0.reserve != true && !seen.contains($0.cluster)}){return .scenario(fresh,.new)}
            if let reserve=rotated.first(where:{$0.reserve==true && !seen.contains($0.cluster)}){return .scenario(reserve,.reserve)}
            return .scenario(rotated[0],.repeat)
        }
    }
}
