import CheckmateAssets
import Foundation
/// What the board area shows outside a review: the one value the app, agents and voice read for where the learner is.
public enum Place:Equatable {
    case practice
    case lesson(index:Int)
    case puzzleLibrary
    case puzzle(id:String)
    case miniGame(lessonIndex:Int,kind:MiniGameKind)
    public var mode:NativeMode {switch self{case .practice:return .practice;case .lesson,.miniGame:return .lesson;case .puzzleLibrary,.puzzle:return .puzzles}}
    /// The lesson this place belongs to, if any.
    public var lessonIndex:Int? {switch self{case .lesson(let index),.miniGame(let index,_):return index;default:return nil}}
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
