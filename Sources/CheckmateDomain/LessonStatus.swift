import Foundation
/// How far the learner has taken a lesson, derived from saved progress alone; nothing here is saved.
///
/// Each status claims only what its records show: `explored`, the lesson was followed to its end (`completed`);
/// `practised`, its own exercise was done (`practised`); `mastered`, that exercise was done in an attempt with no hint
/// (`unaided`) and every puzzle linked to the lesson (it names the lesson by id) was solved with the first answer.
/// A lesson without an exercise is explored at most.
public enum LessonStatus:String,Equatable,CaseIterable {
    case notStarted,explored,practised,mastered
    /// The sidebar's badge; nil when there is nothing to claim.
    public var title:String? {switch self {case .notStarted:return nil;case .explored:return "Explored";case .practised:return "Practised";case .mastered:return "Mastered"}}
    public static func of(_ lesson:CourseLesson,in library:CourseLibrary,course:CourseProgress,puzzles:[String:PuzzleProgress])->LessonStatus {
        if lesson.practice?.playable==true,course.practised?.contains(lesson.id)==true {
            let linked=library.puzzles(for:lesson.id)
            return course.unaided?.contains(lesson.id)==true && linked.allSatisfy({puzzles[$0.id]?.solvedFirstTime==true}) ? .mastered:.practised
        }
        return course.completed.contains(lesson.id) ? .explored:.notStarted
    }
}
