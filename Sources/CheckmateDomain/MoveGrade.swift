/// A reviewed move's grade (R-1): how much of the mover's expected score it gave up, on the review's own thresholds.
/// A move within `nearBestExpectationLoss` of the engine's leading option has no grade.
public enum MoveGrade:String,Codable,CaseIterable,Sendable {
    case inaccuracy,mistake,blunder
    public init?(expectationLoss loss:Double?){
        guard let loss else{return nil}
        if loss>ReviewQualityPolicy.severeExpectationLoss{self = .blunder}else if loss>ReviewQualityPolicy.interestingExpectationLoss{self = .mistake}else if loss>ReviewQualityPolicy.nearBestExpectationLoss{self = .inaccuracy}else{return nil}
    }
    /// The standard annotation glyph written after the move.
    public var glyph:String {switch self{case .inaccuracy:return "?!";case .mistake:return "?";case .blunder:return "??"}}
    public var name:String {switch self{case .inaccuracy:return "Inaccuracy";case .mistake:return "Mistake";case .blunder:return "Blunder"}}
}
