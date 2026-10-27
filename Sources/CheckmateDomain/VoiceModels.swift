import Foundation
public struct SpeechSegment:Decodable {public let text:String,squares:[String],kind:String
    public init(text:String,squares:[String],kind:String){self.text=text;self.squares=squares;self.kind=kind}
    /// Segments from a script's or a tool call's JSON value, as the coach's speech queue takes them.
    public static func decode(_ json:Any)throws -> [SpeechSegment] {try JSONDecoder().decode([SpeechSegment].self,from:JSONSerialization.data(withJSONObject:json))}
}
public struct VoiceHistory:Identifiable {
    /// What the learner was doing when the exchange happened; `context` is only the shown caption (D-12).
    public enum Source:String,Sendable {case practice,network,training,miniReview="mini-review",review}
    public init(id:String,role:String,text:String,context:String,source:Source = .practice){self.id=id;self.role=role;self.text=text;self.context=context;self.source=source}
    public let id:String,role:String,text:String,context:String,source:Source}
