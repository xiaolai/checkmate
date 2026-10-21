import CheckmateAssets
import Foundation
/// One rung of a puzzle's hint ladder: words to read, and the square of the piece it points at (highlighted as a hint).
public struct PuzzleHint:Equatable {public let text:String,square:String?}
extension Puzzle {
    /// The puzzle's hints, weakest first; after the last one only Reveal is left. A move or path puzzle first points at
    /// the piece to move, then says what to look for; a squares puzzle says what to look for; a choice puzzle rules out
    /// one wrong choice.
    public var hints:[PuzzleHint] {
        let words=exercise.claim.flatMap{Self.lookFor[$0.type]}.map{PuzzleHint(text:$0,square:nil)}
        switch exercise.kind {
        case "move":return [exercise.referenceAnswer.first.map{PuzzleHint(text:String(localized:"Move the highlighted piece.",bundle:.checkmate),square:$0)},words].compactMap{$0}
        case "path":return [exercise.from.map{PuzzleHint(text:String(localized:"Move the highlighted king one step at a time.",bundle:.checkmate),square:$0)},words].compactMap{$0}
        case "choice":return (exercise.choices ?? []).first{$0 != exercise.answer}.map{[PuzzleHint(text:String(localized:"It is not “\($0)”.",bundle:.checkmate),square:nil)]} ?? []
        default:return [words].compactMap{$0}
        }
    }
    /// What to look for, by the kind of claim the puzzle's answer makes. Plain words that never name the answer.
    static let lookFor:[String:String]=[
        "mate":String(localized:"Look for a check that leaves the king no safe square, no block and no capture.",bundle:.checkmate),
        "check":String(localized:"Look for a move that attacks the enemy king.",bundle:.checkmate),
        "escape-check":String(localized:"You can move the king, block the check or capture the checking piece. Only one of them works here.",bundle:.checkmate),
        "fork":String(localized:"Look for one move that attacks two pieces at the same time.",bundle:.checkmate),
        "safe-capture":String(localized:"Look for a capture where no enemy piece can take your piece back.",bundle:.checkmate),
        "castle":String(localized:"Castling moves the king two squares toward a rook, and the rook jumps over the king.",bundle:.checkmate),
        "promote":String(localized:"Move a pawn onto the last row of the board.",bundle:.checkmate),
        "destinations":String(localized:"Picture the piece moving: count each square it can reach in one move, and stop at any piece in the way.",bundle:.checkmate),
        "attacked-pieces":String(localized:"Go through the pieces one at a time and ask which ones could be captured right now.",bundle:.checkmate),
        "attackers":String(localized:"Follow every line into the square and see which pieces could capture there.",bundle:.checkmate),
        "undefended":String(localized:"For each piece, ask whether a piece of its own side could capture back if it were taken.",bundle:.checkmate),
        "locate":String(localized:"Find the letter along the bottom edge first, then the number along the side.",bundle:.checkmate),
        "attacks":String(localized:"Picture where the piece could capture: those are the squares it attacks.",bundle:.checkmate),
        "king-route":String(localized:"Before each step, check that no enemy piece attacks the square.",bundle:.checkmate),
    ]
}
/// What a finished set of puzzles shows instead of starting it again: how each of its puzzles stands.
public struct PuzzleSetSummary:Equatable {
    public let total:Int,solved:Int,helped:Int,toReview:Int,notTried:Int
    public init(total:Int,solved:Int,helped:Int,toReview:Int,notTried:Int){self.total=total;self.solved=solved;self.helped=helped;self.toReview=toReview;self.notTried=notTried}
    public init(_ puzzles:[Puzzle],progress:[String:PuzzleProgress]){
        let records=puzzles.map{progress[$0.id] ?? PuzzleProgress()},standings=records.map(\.standing)
        self.init(total:puzzles.count,solved:standings.filter{$0 == .solved}.count,helped:standings.filter{$0 == .solvedWithHints || $0 == .solvedLater}.count,toReview:records.filter(\.review).count,notTried:standings.filter{$0 == .notTried}.count)
    }
    public var text:String {
        var parts=["\(solved) of \(total) solved on your own."]
        if helped>0{parts.append(String(localized:"\(helped) solved with a hint or on a later try.",bundle:.checkmate))};if toReview>0{parts.append("\(toReview) to review.")};if notTried>0{parts.append("\(notTried) not tried.")}
        return parts.joined(separator:" ")
    }
}
/// How many of the course's main lessons have been explored to their end.
public struct CourseStanding:Equatable {public let explored:Int,total:Int;public var text:String {"\(explored) of \(total)"}}
extension CourseLibrary {
    public func standing(_ course:CourseProgress)->CourseStanding {
        let main=lessons.filter{!$0.isPractice}.map(\.id),done=Set(course.completed)
        return CourseStanding(explored:main.filter{done.contains($0)}.count,total:main.count)
    }
    /// Every main lesson has been explored.
    public func complete(_ course:CourseProgress)->Bool {let standing=standing(course);return standing.explored==standing.total}
    /// Where Continue Learning goes: the bookmarked lesson while it is unfinished, then the next unexplored main lesson
    /// after it, then the first one anywhere; nil once every main lesson is explored.
    public func continueIndex(_ course:CourseProgress)->Int? {
        let done=Set(course.completed),bookmark=lessons.firstIndex{$0.id==course.lessonID}
        if let bookmark,!done.contains(lessons[bookmark].id){return bookmark}
        let open=lessons.indices.filter{!lessons[$0].isPractice && !done.contains(lessons[$0].id)}
        return open.first{$0>(bookmark ?? -1)} ?? open.first
    }
    /// The puzzle topics, grouped by course section in course order; a section without puzzles is left out.
    public var topicGroups:[(title:String,topics:[String])] {
        sections.compactMap{section in let topics=section.lessons.compactMap{puzzles(for:$0).first?.topic};return topics.isEmpty ? nil:(section.title,topics)}
    }
}
