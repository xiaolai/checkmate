import CheckmateCore

/// One puzzle library row: what it shows and what VoiceOver reads. `PuzzleLibraryContent` draws these values.
struct PuzzleRowFormat:Equatable {
    /// Solved alone, or solved but not first time (with hints or on a later try), which is marked apart from mastery.
    enum Mark:Equatable {
        case solved,notFirstTry
        var symbol:AppSymbol {self == .solved ? .done:.solvedLater}
    }
    /// `markHelp`: the mark's tooltip, the puzzle's standing; nil without a mark.
    let title:String,detail:String,review:Bool,mark:Mark?,markHelp:String?,accessibilityValue:String
    init(_ puzzle:Puzzle,record:PuzzleProgress) {
        title=puzzle.title;detail="\(puzzle.topic) · \(puzzle.level)";review=record.review
        mark=record.solved ? .solved:record.countsAsSolved ? .notFirstTry:nil;markHelp=mark == nil ? nil:record.standing.title
        accessibilityValue=([record.standing.title]+(record.review ? [String(localized:"to review",bundle:.checkmate,comment:"A puzzle queued for review, in its spoken description")]:[])+[puzzle.level]).joined(separator:", ")
    }
    /// The library heading: every solve, first time or not, and puzzles queued for review.
    static func heading(_ progress:[String:PuzzleProgress])->String {
        String(localized:"\(progress.values.filter(\.countsAsSolved).count) solved · \(progress.values.filter(\.review).count) to review",bundle:.checkmate,comment:"The puzzle library heading: puzzles solved, then puzzles to review")
    }
}

/// The card a finished course shows on its last main lesson, with next steps instead of a next lesson.
enum CourseCompleteCard {
    enum Action:CaseIterable {
        case puzzles,training,game
        var title:String {switch self {case .puzzles:return String(localized:"Quick Puzzles",bundle:.checkmate);case .training:return String(localized:"Training",bundle:.checkmate);case .game:return String(localized:"Play a Game",bundle:.checkmate)}}
    }
    static let title=String(localized:"You Explored the Whole Course",bundle:.checkmate)
    @MainActor static func shown(_ learning:LearningPlayer)->Bool {learning.courseComplete && learning.library.nextMainLesson(after:learning.lessonIndex)==nil}
    static func actions(trainingAvailable:Bool)->[Action] {Action.allCases.filter{$0 != .training || trainingAvailable}}
    static func message(trainingAvailable:Bool)->String {trainingAvailable ? String(localized:"Keep your skills sharp with puzzles, training or a game.",bundle:.checkmate):String(localized:"Keep your skills sharp with puzzles or a game.",bundle:.checkmate)}
}
