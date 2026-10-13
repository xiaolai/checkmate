import Foundation
import CheckmateDomain
import CheckmateRules
public enum WorkspaceNavigation {
        case practice,returnToGame,lesson(Int,resume:Bool=true),puzzles,reviewWorkspace
        case review(GameDocument,saved:SavedReview?,draft:Bool)
        case importProgress(ApplicationState,backup:(URL)->Void)
        case practiceFork(side:String,preset:String)
        /// The training library; a new exercise for an entry; the saved unfinished exercise; an existing mini-game
        /// opened from the library (its one saved board, or a new one on an explicit restart).
        case trainingLibrary,trainingExercise(entry:String,variant:String?=nil),trainingScenario(id:String),trainingResume,trainingRetry(id:String),trainingLegacy(MiniGameKind,restart:Bool)
        /// A training entry's linked lesson, read without moving the course bookmark; the way back leads to training.
        case trainingLesson(id:String)
    }
fileprivate enum WorkspaceEntry {case none,review(GameDocument,restore:(cursor:Int,branches:[ReviewBranch])?),importProgress(ApplicationState),practiceFork(ChessRules),training(TrainingController.StagedExercise)}

/// A successful preparation carries its request; callers cannot pair it with another navigation.
public struct PreparedWorkspaceTransition {
    fileprivate let navigation:WorkspaceNavigation
    fileprivate let entry:WorkspaceEntry
    public var importedState:ApplicationState? {if case .importProgress(let state)=entry{return state};return nil}
}
/// Stages fallible entry work before the host performs any exit effects. UI consent and native service teardown stay with the host.
@MainActor public final class WorkspaceTransitionCoordinator {
    private let session:GameSession,learning:LearningPlayer,review:ReviewController
    public init(session:GameSession,learning:LearningPlayer,review:ReviewController){self.session=session;self.learning=learning;self.review=review}
    /// Whether a staged entry can still be entered: a training exercise is entered only over the record it was staged
    /// from. The host asks before its exit effects, so a refusal leaves the review and every service as they were.
    public func stillCurrent(_ prepared:PreparedWorkspaceTransition)->Bool {
        if case .training(let staged)=prepared.entry{return training?.isCurrent(staged) ?? false};return true
    }
    public static let staleTrainingMessage="Training progress changed while this exercise was being opened, so it was not opened. Try again; your progress is unchanged."
    /// The new-exercise controller, when training is enabled: a review closing over an exercise hands its board back.
    public var training:TrainingController?
    public func prepare(_ next:WorkspaceNavigation,pendingReview:(document:GameDocument,cursor:Int,branches:[ReviewBranch])?=nil)throws -> PreparedWorkspaceTransition {
        PreparedWorkspaceTransition(navigation:next,entry:try prepareEntry(next,pendingReview:pendingReview))
    }
    private func prepareEntry(_ next:WorkspaceNavigation,pendingReview:(document:GameDocument,cursor:Int,branches:[ReviewBranch])?=nil)throws -> WorkspaceEntry {
        switch next {
        case .review(let document,let saved,_):
            let shown=pendingReview?.document ?? document
            let restore=pendingReview.map{(cursor:$0.cursor,branches:$0.branches)} ?? saved.map{(cursor:$0.cursor,branches:$0.branches)}
            guard restore.map({shown.nodes.indices.contains($0.cursor)}) ?? true else{throw WorkspaceEntryError.invalidRestore}
            return .review(shown,restore:restore)
        case .importProgress(let state,_):try StateStore.validate(state);return .importProgress(state)
        case .practiceFork(let side,_):
            let rules=try review.practiceForkRules()
            guard !rules.over else{throw CheckmateError.invalid("This position is terminal and cannot start practice.")}
            try GameSession.validatePracticeFork(rules,side:side);try ChessRules().restore(rules.pgn);return .practiceFork(rules)
        // A training exercise is chosen, validated and its evaluator built here: a failure leaves the activity as it was.
        case .trainingExercise(let entry,let variant):return .training(try trainingController().stage(trainingController().prepare(entry:entry,variant:variant)))
        case .trainingScenario(let id):return .training(try trainingController().stage(trainingController().prepare(scenario:id)))
        case .trainingResume:return .training(try trainingController().stage(trainingController().prepareResume()))
        case .trainingRetry(let id):return .training(try trainingController().stage(trainingController().prepareRetry(id:id)))
        case .trainingLibrary,.trainingLegacy:_ = try trainingController();return .none
        // A lesson that does not exist fails here, before the host closes a review or stops playback for it.
        case .lesson(let index,_):guard learning.library.lessons.indices.contains(index) else{throw CheckmateError.invalid("That lesson is not available.")};return .none
        case .trainingLesson(let id):_ = try trainingController();guard learning.library.lessons.contains(where:{$0.id==id}) else{throw CheckmateError.invalid("That lesson is not available.")};return .none
        default:return .none
        }
    }
    public func enter(prepared:PreparedWorkspaceTransition,from place:Place,wasReviewing:Bool,beforeReviewRestore:()->Void={},afterReviewRestore:()->Void={})throws {
        switch (prepared.navigation,prepared.entry) {
        case (.practice,_):
            leaveTraining()
            if wasReviewing{session.enter(.at(.practice),resume:place == .practice)}else if place == .practice{session.resumeHeldReply()}else{session.enter(.at(.practice))}
        case (.returnToGame,_):if wasReviewing{session.enter(.at(place),resume:true)}else if place == .practice{session.resumeHeldReply()};learning.resumeMiniOpponent();if place.mode == .training{training?.resumeAfterReview()}
        case (.lesson(let index,let resume),_):leaveReview(wasReviewing,place);leaveTraining();learning.openLesson(index:index,resume:resume)
        case (.puzzles,_):leaveReview(wasReviewing,place);leaveTraining();learning.showPuzzleLibrary()
        case (.reviewWorkspace,_):training?.pauseForReview();session.enter(.reviewing(ReviewVisit(document:nil,draft:false,returnTo:place)))
        case (.review(let document,_,let draft),.review(let shown,let restore)):
            training?.pauseForReview()
            review.load(shown);session.enter(.reviewing(ReviewVisit(document:document.id,draft:draft,returnTo:place)));beforeReviewRestore()
            if let restore{try? review.restoreSaved(cursor:restore.cursor,branches:restore.branches)}
            afterReviewRestore()
        case (.importProgress,.importProgress(let state)):
            do{try session.installImportedState(state)}catch{if session.activity.review != nil{session.enter(.at(place))};throw error}
            // The imported record replaces the exercise held in memory: no reply for it may save over the import.
            leaveTraining();training?.exercise=nil;training?.guidedReview=nil
            learning.reloadFilters()
            // Likewise the lesson exercise shown: it is read again from the imported attempts.
            learning.reloadAttempt()
        case (.practiceFork(let side,let preset),.practiceFork(let rules)):
            let previous=session.state.settings;var settings=previous;settings.opponentPreset=preset;session.updateSettings(settings,restartOpponent:false)
            do{try session.installPracticeFork(rules,side:side)}catch{session.updateSettings(previous,restartOpponent:false);if session.activity.review != nil{session.enter(.at(place))};throw error}
            leaveTraining()
        case (.trainingLibrary,_):leaveReview(wasReviewing,place);training?.openLibrary()
        case (.trainingLegacy(let kind,let restart),_):leaveReview(wasReviewing,place);leaveTraining();training?.playLegacy(kind,restart:restart)
        case (.trainingLesson(let id),_):
            leaveReview(wasReviewing,place);leaveTraining()
            if let index=learning.library.lessons.firstIndex(where:{$0.id==id}){learning.openLesson(index:index,fromTraining:true)}
        case (.trainingExercise,.training(let staged)),(.trainingScenario,.training(let staged)),(.trainingResume,.training(let staged)),(.trainingRetry,.training(let staged)):
            // Progress saved since staging would be overwritten by this exercise: refused before the review is left
            // (one the host already closed returns to the place it covered), and entry itself cannot fail.
            let training=try trainingController()
            guard training.isCurrent(staged) else{
                if session.activity.review != nil{session.enter(.at(place))}
                throw CheckmateError.unavailable(Self.staleTrainingMessage)
            }
            leaveReview(wasReviewing,place);training.begin(staged:staged)
        default:break
        }
    }
    /// Every exit from an exercise cancels its pending defender reply, so none advances or saves the exercise unseen.
    /// Only Return to game, back to the training place, asks for it again.
    private func leaveTraining(){training?.games.cancel()}
    private func trainingController()throws -> TrainingController {guard let training else{throw CheckmateError.unavailable("Training is not available in this version.")};return training}
    /// A review closed for another activity first returns to the place it covered, so the new one replaces that place.
    private func leaveReview(_ wasReviewing:Bool,_ place:Place){if wasReviewing{session.enter(.at(place));session.cancelWork()}}
}
public enum WorkspaceEntryError:Error {case invalidRestore}
