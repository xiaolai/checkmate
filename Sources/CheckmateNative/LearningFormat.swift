import CheckmateCore

/// One puzzle library row: what it shows and what VoiceOver reads. `PuzzleLibraryContent` draws these values.
struct PuzzleRowFormat:Equatable {
    /// Solved alone, or solved with help; an assisted solve is marked apart from mastery.
    enum Mark:Equatable {
        case solved,assisted
        var symbol:String {self == .solved ? "checkmark.circle.fill":"checkmark.circle"}
        var help:String {self == .solved ? PuzzleStanding.solved.title:PuzzleStanding.solvedWithHints.title}
    }
    let title:String,detail:String,review:Bool,mark:Mark?,accessibilityValue:String
    init(_ puzzle:Puzzle,record:PuzzleProgress) {
        title=puzzle.title;detail="\(puzzle.topic) · \(puzzle.level)";review=record.review
        mark=record.solved ? .solved:record.countsAsSolved ? .assisted:nil
        accessibilityValue=([record.standing.title]+(record.review ? ["to review"]:[])+[puzzle.level]).joined(separator:", ")
    }
    /// The library heading: solves, alone or with help, and puzzles queued for review.
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
