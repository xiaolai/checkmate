import CheckmateCore

/// One puzzle library row: what it shows and what VoiceOver reads. `PuzzleLibraryContent` draws these values.
struct PuzzleRowFormat:Equatable {
    /// Solved alone, or solved but not first time (with hints or on a later try), which is marked apart from mastery.
    enum Mark:Equatable {
        case solved,notFirstTry
        var symbol:String {self == .solved ? "checkmark.circle.fill":"checkmark.circle"}
    }
    /// `markHelp`: the mark's tooltip, the puzzle's standing; nil without a mark.
    let title:String,detail:String,review:Bool,mark:Mark?,markHelp:String?,accessibilityValue:String
    init(_ puzzle:Puzzle,record:PuzzleProgress) {
        title=puzzle.title;detail="\(puzzle.topic) · \(puzzle.level)";review=record.review
        mark=record.solved ? .solved:record.countsAsSolved ? .notFirstTry:nil;markHelp=mark == nil ? nil:record.standing.title
        accessibilityValue=([record.standing.title]+(record.review ? ["to review"]:[])+[puzzle.level]).joined(separator:", ")
    }
    /// The library heading: every solve, first time or not, and puzzles queued for review.
    static func heading(_ progress:[String:PuzzleProgress])->String {
        "\(progress.values.filter(\.countsAsSolved).count) solved · \(progress.values.filter(\.review).count) to review"
    }
}

/// The card a finished course shows on its last main lesson, with next steps instead of a next lesson.
enum CourseCompleteCard {
    enum Action:CaseIterable {
        case puzzles,training,game
        var title:String {switch self {case .puzzles:return "Quick Puzzles";case .training:return "Training";case .game:return "Play a Game"}}
    }
    static let title="You Explored the Whole Course"
    @MainActor static func shown(_ learning:LearningPlayer)->Bool {learning.courseComplete && learning.library.nextMainLesson(after:learning.lessonIndex)==nil}
    static func actions(trainingAvailable:Bool)->[Action] {Action.allCases.filter{$0 != .training || trainingAvailable}}
    static func message(trainingAvailable:Bool)->String {"Keep your skills sharp with puzzles\(trainingAvailable ? ", training or":" or") a game."}
}
