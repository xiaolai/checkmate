import Foundation
/// Pilot rollout: facts-only review is available; unvalidated labels, voice and beginner policy require explicit opt-in.
public enum ReviewRolloutPolicy {
    public static var reviewEnabled:Bool {let env=ProcessInfo.processInfo.environment;return env["CHECKMATE_REVIEW_DISABLED"] != "1" && (env["CHECKMATE_REVIEW_ENABLED"] == "1" || env["CHECKMATE_AUTOMATION"] == "1")}
    public static var reviewQualityLabels:Bool {ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_QUALITY_LABELS"] == "1"}
    public static var reviewVoiceEnabled:Bool {ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_VOICE_ENABLED"] == "1"}
    public static var beginnerOpponentEnabled:Bool {ProcessInfo.processInfo.environment["CHECKMATE_BEGINNER_OPPONENT_ENABLED"] == "1"}
}
public struct EngineCapabilities:Codable,Equatable {
    public var name="Unknown engine",options:Set<String>=[],skillRange=0...20,eloRange:ClosedRange<Int>?
    public init(){}
    public mutating func ingest(_ line:String){let fields=line.split(separator:" ").map(String.init);if line.hasPrefix("id name "){name=String(line.dropFirst(8))};guard line.hasPrefix("option name "),let type=fields.firstIndex(of:"type") else{return};let name=fields[2..<type].joined(separator:" ");options.insert(name);func number(_ key:String)->Int?{guard let i=fields.firstIndex(of:key),i+1<fields.count else{return nil};return Int(fields[i+1])};if let min=number("min"),let max=number("max"),min<=max{if name=="Skill Level"{skillRange=min...max};if name=="UCI_Elo"{eloRange=min...max}}}
}
public struct OpponentProfile:Codable,Equatable {
    public let version:Int,mode:String,value:Int
    public static func skill(_ value:Int)->Self {Self(version:1,mode:"skill",value:value)}
    public static func elo(_ value:Int)->Self {Self(version:1,mode:"elo",value:value)}
    public static let beginner=Self(version:1,mode:"beginner",value:0)
    public var options:[String:String] {mode=="elo" ? ["UCI_LimitStrength":"true","UCI_Elo":String(value),"Skill Level":"20"]:["UCI_LimitStrength":"false","Skill Level":String(mode=="beginner" ? 0:value)]}
    public static func settings(_ settings:AppSettings)->Self {switch settings.opponentPreset{case "first_steps":return ReviewRolloutPolicy.beginnerOpponentEnabled ? .beginner:.skill(settings.skill);case "gentle":return .skill(0);case "club":return .skill(10);default:break};return settings.opponentMode=="elo" ? .elo(settings.opponentElo):settings.opponentMode=="beginner" && ReviewRolloutPolicy.beginnerOpponentEnabled ? .beginner:.skill(settings.skill)}
}
public enum AnalysisPolicy {public static let version=1;public static let options=["UCI_LimitStrength":"false","Skill Level":"20","Threads":"1","Hash":"32","UCI_ShowWDL":"true"]}
public enum ReviewQualityPolicy {
    public static let version=1,nearBestCp=50,stableCpTolerance=80,minimumDepth=12
    public static let nearBestExpectationLoss=0.03,interestingExpectationLoss=0.10,severeExpectationLoss=0.20
}
public enum MoveQuality {
    public static func compare(best:AnalysisScore,played:AnalysisScore,mover:String,stable:Bool)->String {
        guard stable,best.bound==nil,played.bound==nil else{return "provisional"}
        let sign=mover=="w" ? 1:-1
        if best.kind=="mate" || played.kind=="mate" {
            if best.kind=="mate",played.kind=="mate",(best.value*sign>0)==(played.value*sign>0){return "same-mate-outcome"}
            return "mate-outcome-changed"
        }
        guard best.kind=="cp",played.kind=="cp" else{return "provisional"}
        return (best.value-played.value)*sign<=ReviewQualityPolicy.nearBestCp ? "near-best":"engine-prefers-alternative"
    }
}
