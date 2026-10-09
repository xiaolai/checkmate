import Foundation
public enum ReviewVoiceScript {
    public static func segments(_ explanation:ReviewExplanation)->[[String:Any]] {explanation.facts.prefix(3).map{["text":$0.text,"squares":Array($0.squares.prefix(8)),"kind":"focus"]}}
    public static func validate(_ segments:[SpeechSegment],explanation:ReviewExplanation)throws {
        guard segments.count<=8 else{throw ProtocolFailure("INVALID_ARGUMENT")}
        for segment in segments {guard explanation.facts.contains(where:{$0.text==segment.text && Set(segment.squares).isSubset(of:Set($0.squares))}),segment.squares.allSatisfy(ChessRules.validSquare) else{throw ProtocolFailure("UNGROUNDED_REVIEW_SPEECH","Review narration must use a verified factual segment and its own square cues.")}}
    }
    @MainActor public static func context(review:ReviewController)->[String:Any] {guard let d=review.document,let rules=review.displayRules else{return [:]};return ["scope":"read-only-review","documentId":d.id.uuidString,"reviewRevision":review.revision,"nodeId":review.nodeID,"displayIdentity":review.identity,"fen":rules.fen,"facts":review.branch==nil ? review.explanation.map{jsonObject($0)} ?? NSNull():NSNull(),"legalMoves":rules.moves().prefix(100).map{["san":$0.san,"uci":$0.uci]},"original":review.branch==nil,"earlierHistoryAvailable":d.historyAvailable,"rule":"Narrate only supplied verified factual text; do not infer intentions or edit any game."]}
}
