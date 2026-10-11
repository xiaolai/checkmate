import Foundation
public struct AnalysisScore:Codable,Equatable {public var kind:String,value:Int,perspective="white",bound:String?;public init(kind:String,value:Int,bound:String?=nil){self.kind=kind;self.value=value;self.bound=bound}}
public struct AnalysisLine:Codable,Equatable {public init(depth:Int,multiPv:Int,score:AnalysisScore,pv:[String],san:[String],nodes:Int?=nil,timeMs:Int?=nil,wdl:[Int]?=nil){self.depth=depth;self.multiPv=multiPv;self.score=score;self.pv=pv;self.san=san;self.nodes=nodes;self.timeMs=timeMs;self.wdl=wdl}
public var depth:Int,multiPv:Int,score:AnalysisScore,pv:[String],san:[String];public var nodes:Int?=nil,timeMs:Int?=nil,wdl:[Int]?=nil}
public struct OpponentDecision:Codable {public init(policyVersion:Int,estimatedRegretCp:Int?,fallback:Bool,priorSevereStreak:Int){self.policyVersion=policyVersion;self.estimatedRegretCp=estimatedRegretCp;self.fallback=fallback;self.priorSevereStreak=priorSevereStreak}
public let policyVersion:Int,estimatedRegretCp:Int?,fallback:Bool,priorSevereStreak:Int}
public struct EngineAnalysis:Codable {public var opponentDecision:OpponentDecision?=nil;public var bestMove:String?,budgetMs:Int,lines:[AnalysisLine];public init(bestMove:String?=nil,budgetMs:Int=350,lines:[AnalysisLine]=[]){self.bestMove=bestMove;self.budgetMs=budgetMs;self.lines=lines}}
