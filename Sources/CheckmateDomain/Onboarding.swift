import CheckmateAssets
import Foundation

/// The first-run welcome (L-20): language and voice, where to start, then the first move. It is shown once, to a
/// learner with no saved progress, and never to an automation or test run unless that run asks for it.
public enum Onboarding {
    public enum Step:Int,CaseIterable {
        case languageAndVoice,placement,firstMove
        public var next:Step? {Step(rawValue:rawValue+1)}
        public var previous:Step? {Step(rawValue:rawValue-1)}
    }
    /// Where a learner starts: each choice is the first lesson of a part of the course.
    public enum Placement:String,CaseIterable {
        case new,knowsMoves,knowsRules
        public var title:String {switch self {case .new:String(localized:"I’m new to chess",bundle:.checkmate);case .knowsMoves:String(localized:"I know how the pieces move",bundle:.checkmate);case .knowsRules:String(localized:"I know the rules and want to learn openings and tactics",bundle:.checkmate)}}
        var lesson:String {switch self {case .new:"intro";case .knowsMoves:"safe-squares";case .knowsRules:"opening"}}
    }
    public static func shows(firstRun:Bool,silent:Bool,requested:Bool)->Bool {requested || (firstRun && !silent)}
    /// The placement's lesson in `library`; nil when the course has no such lesson.
    public static func lessonIndex(_ placement:Placement,in library:CourseLibrary)->Int? {library.lessons.firstIndex{$0.id==placement.lesson}}
}
