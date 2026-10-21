import CheckmateAssets
import Foundation
/// Today's Mix (L-29): an optional short set of puzzles, composed when the learner asks for it. Nothing about it is
/// saved, so a day without it changes nothing, and its words invite rather than count days.
public enum TodayMix {
    /// The most puzzles in a mix, and the most of them that are reviews before new ones get a turn.
    public static let size=5,reviews=3
    public static var title:String {String(localized:"Today’s Mix",bundle:.checkmate,comment:"Button: an optional short set of puzzles")}
    public static var detail:String {String(localized:"A few puzzles to look at again and a few new ones. Play it whenever you like.",bundle:.checkmate)}
    public static var finished:String {String(localized:"That was today’s mix. Well played!",bundle:.checkmate,comment:"Heading at the end of Today’s Mix")}
    /// Up to `reviews` puzzles due at `now`, then puzzles never tried (those from `explored` lessons first), then more
    /// due ones if there is room; each group in library order. Empty when nothing is due or new.
    public static func compose(_ puzzles:[Puzzle],progress:[String:PuzzleProgress],explored:Set<String>,at now:Date)->[String] {
        let due=puzzles.filter{progress[$0.id]?.isDue(at:now)==true}.map(\.id),fresh=puzzles.filter{progress[$0.id]==nil}
        let new=(fresh.filter{explored.contains($0.lesson)}+fresh.filter{!explored.contains($0.lesson)}).map(\.id)
        return Array((Array(due.prefix(reviews))+new+due.dropFirst(reviews)).prefix(size))
    }
}
