import Foundation
public struct SpeechSegment:Decodable {public let text:String,squares:[String],kind:String}
public struct VoiceHistory:Identifiable {
    /// What the learner was doing when the exchange happened; `context` is only the shown caption (D-12).
    public enum Source:String,Sendable {case practice,network,training,miniReview="mini-review",review}
    public init(id:String,role:String,text:String,context:String,source:Source = .practice){self.id=id;self.role=role;self.text=text;self.context=context;self.source=source}
    public let id:String,role:String,text:String,context:String,source:Source}
