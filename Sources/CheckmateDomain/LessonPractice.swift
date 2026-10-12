import Foundation
/// A complete, legal position for trying a lesson against an opponent rather than copying a recorded line. Authored
/// with the lesson in the course content (`practice`), where the content check verifies it.
public struct LessonPractice:Codable,Equatable {
    public let fen:String,goal:String
    public init(fen:String,goal:String){self.fen=fen;self.goal=goal}
}
