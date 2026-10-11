import Foundation
public struct SeededReviewRandom:RandomNumberGenerator {private var state:UInt64;public init(seed:UInt64){state=seed == 0 ? 1:seed};public mutating func next()->UInt64 {state = state &* 6364136223846793005 &+ 1442695040888963407;return state}}
public enum BeginnerPolicy {
    public static let version=3,severeRegretCp=300,maximumConsecutiveSevereErrors=2,maximumRegretCp=700,minorRegretCp=100,candidateCount=6,explorationCount=4,budgetMs=180,mistakePercent=65
}
