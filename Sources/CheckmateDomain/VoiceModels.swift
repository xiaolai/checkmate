import Foundation
public struct SpeechSegment:Decodable {public let text:String,squares:[String],kind:String}
public struct VoiceHistory:Identifiable {public init(id:String,role:String,text:String,context:String){self.id=id;self.role=role;self.text=text;self.context=context}
public let id:String,role:String,text:String,context:String}
