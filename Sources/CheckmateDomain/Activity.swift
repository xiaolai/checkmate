import Foundation
/// What the board area shows outside a review: the one value the app, agents and voice read for where the learner is.
public enum Place:Equatable {
    case practice
    /// A lesson. `fromTraining`: opened from a training entry's lesson link, so reading it leaves the course
    /// bookmark where it was and the way back leads to training.
    case lesson(index:Int,fromTraining:Bool=false)
    case puzzleLibrary
    case puzzle(id:String)
    /// An existing mini-game. `lessonIndex` is the lesson it was opened from, or nil when the training library opened
    /// it; `fromTraining` is that lesson's own `fromTraining` (always false without a lesson). The origin lives here and
    /// nowhere else, so its mode, exit (back to which lesson, kept as a training link or not) and review return follow
    /// from this one value.
    case miniGame(lessonIndex:Int?,kind:MiniGameKind,fromTraining:Bool=false)
    /// The training library, and a new training exercise (by entry identifier).
    case trainingLibrary
    case training(entry:String)
    /// Play on Network: hosting, joining or watching a game over the local network, and the game itself. The network
    /// game owns its own board (LAN-play plan D9); practice keeps its game underneath, untouched.
    case network
    public var mode:NativeMode {switch self{case .practice:return .practice;case .lesson:return .lesson;case .miniGame(let index,_,_):return index==nil ? .training:.lesson;case .puzzleLibrary,.puzzle:return .puzzles;case .trainingLibrary,.training:return .training;case .network:return .network}}
    /// The lesson this place belongs to, if any.
    public var lessonIndex:Int? {switch self{case .lesson(let index,_):return index;case .miniGame(let index,_,_):return index;default:return nil}}
}
/// A review shown over a place, which it returns to. `document` is nil in the review workspace (choosing a game).
public struct ReviewVisit:Equatable {
    public var document:UUID?,draft:Bool,returnTo:Place
    public init(document:UUID?,draft:Bool,returnTo:Place){self.document=document;self.draft=draft;self.returnTo=returnTo}
}
/// Where the learner is (B8.2). `GameSession.activity` holds it; every other flag about the current activity
/// (`mode`, `reviewSuspended`, the review workspace and draft, the displayed puzzle or mini-game) is derived from it.
public enum Activity:Equatable {
    case at(Place)
    case reviewing(ReviewVisit)
    /// The place shown, or the one an open review returns to.
    public var place:Place {switch self{case .at(let place):return place;case .reviewing(let visit):return visit.returnTo}}
    public var review:ReviewVisit? {if case .reviewing(let visit)=self{return visit};return nil}
    public var inReviewWorkspace:Bool {review.map{$0.document==nil} ?? false}
}
