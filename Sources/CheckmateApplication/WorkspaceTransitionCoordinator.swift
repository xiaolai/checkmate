import Foundation
import CheckmateDomain
import CheckmateRules
import CheckmateContent
import CheckmateSupport
import CheckmateAssets
public enum WorkspaceNavigation {
        case practice,returnToGame,lesson(Int,resume:Bool=true),puzzles,reviewWorkspace
        /// A lesson's own practice position, played as White in a separate game.
        case lessonPractice(fen:String)
        case review(GameDocument,saved:SavedReview?,draft:Bool)
        case importProgress(ApplicationState,backup:(URL)->Void)
        case practiceFork(side:String,preset:String)
    }
fileprivate enum WorkspaceEntry {case none,lessonPractice(ChessRules),review(GameDocument,restore:(cursor:Int,branches:[ReviewBranch])?),importProgress(ApplicationState),practiceFork(ChessRules)}

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
        case .lessonPractice(let fen):let rules=try ChessRules(fen:fen);try GameSession.validatePracticeFork(rules,side:"w");return .lessonPractice(rules)
        default:return .none
        }
    }
    public func enter(prepared:PreparedWorkspaceTransition,from place:Place,wasReviewing:Bool,beforeReviewRestore:()->Void={},afterReviewRestore:()->Void={})throws {
        switch (prepared.navigation,prepared.entry) {
        case (.practice,_):
            if wasReviewing{session.enter(.at(.practice),resume:place == .practice)}else if place == .practice{session.resumeHeldReply()}else{session.enter(.at(.practice))}
        case (.returnToGame,_):if wasReviewing{session.enter(.at(place),resume:true)}else if place == .practice{session.resumeHeldReply()};learning.resumeMiniOpponent()
        case (.lesson(let index,let resume),_):if wasReviewing{session.enter(.at(place));session.cancelWork()};learning.openLesson(index:index,resume:resume)
        case (.puzzles,_):if wasReviewing{session.enter(.at(place));session.cancelWork()};learning.showPuzzleLibrary()
        case (.reviewWorkspace,_):session.enter(.reviewing(ReviewVisit(document:nil,draft:false,returnTo:place)))
        case (.review(let document,_,let draft),.review(let shown,let restore)):
            review.load(shown);session.enter(.reviewing(ReviewVisit(document:document.id,draft:draft,returnTo:place)));beforeReviewRestore()
            if let restore{try? review.restoreSaved(cursor:restore.cursor,branches:restore.branches)}
            afterReviewRestore()
        case (.importProgress,.importProgress(let state)):
            do{try session.installImportedState(state)}catch{if session.activity.review != nil{session.enter(.at(place))};throw error}
            learning.reloadFilters()
        case (.practiceFork(let side,let preset),.practiceFork(let rules)):
            let previous=session.state.settings;var settings=previous;settings.opponentPreset=preset;session.updateSettings(settings,restartOpponent:false)
            do{try session.installPracticeFork(rules,side:side)}catch{session.updateSettings(previous,restartOpponent:false);if session.activity.review != nil{session.enter(.at(place))};throw error}
        case (.lessonPractice,.lessonPractice(let rules)):
            do{try session.installPracticeFork(rules,side:"w")}catch{if session.activity.review != nil{session.enter(.at(place))};throw error}
        default:break
        }
    }
}
public enum WorkspaceEntryError:Error {case invalidRestore}
