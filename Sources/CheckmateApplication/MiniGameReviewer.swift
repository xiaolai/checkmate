import CheckmateDomain
import CheckmateSupport
import Foundation
import Combine

/// Owns the post-game review of the mini-game shown (plan D5, WI-018). A review starts when a game finishes and runs
/// off the main actor on a copy of it, within `MiniGameProofBudget`'s CPU budget. Like `ReviewAnalyzer`, each run
/// carries a generation: a restart, undo or leaving the game cancels it, and a result is shown only if its generation
/// is current and the game shown is still the one reviewed (same kind, run, length, final position and opponent).
@MainActor public final class MiniGameReviewer:ObservableObject {
    public enum Status:Equatable {case idle,running,ready(MiniGameReview)}
    /// The game a review belongs to; a result for any other is never shown.
    public struct Identity:Equatable {
        let kind:MiniGameKind,run:String?,plies:Int,final:MiniGameSnapshot,computer:Bool
        public init(_ game:MiniGameState){kind=game.kind;run=game.opponentSeed;plies=game.history.count;final=game.snapshot;computer=game.computer}
    }
    @Published public private(set) var status:Status = .idle
    /// Whether the review's sheet is open: it opens when a result arrives and stays closed once dismissed.
    @Published public private(set) var sheetOpen=false
    public private(set) var identity:Identity?
    /// The game shown now, read before a result is published.
    public var current:()->MiniGameState?={nil}
    /// The review's CPU budget and clock; tests shorten the one and replace the other.
    var budget=MiniGameProofBudget.reviewCPUSeconds
    var cpuSeconds:@Sendable ()->Double={MiniGameReviewer.threadCPUSeconds()}
    private var task:Task<Void,Never>?,generation=0
    public init(){}
    /// The CPU time of the calling thread. A review runs synchronously on one thread from start to end, so this is the
    /// review's own CPU time, whatever else the machine is doing.
    nonisolated static func threadCPUSeconds()->Double {Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))/1e9}

    /// Reviews a finished game against the computer from `learner`'s side, or a two-player game from both.
    public func start(_ game:MiniGameState,learner:String="w"){
        guard !game.kind.solo,game.isFinished else{return}
        cancel();generation+=1;let reviewed=Identity(game),budget=budget,clock=cpuSeconds
        identity=reviewed
        launch(Task.detached(priority:.utility){MiniGameReview.run(game,learner:learner,budget:budget,cpuSeconds:clock,stop:{Task.isCancelled})},opens:true){[weak self] in self?.current().map(Identity.init)==reviewed}
    }
    /// A network game's moves from its kind's start, while it is shown (protocol 1.3): `start(kind:moves:)` shows a
    /// result only for the same session's same moves.
    public var currentNetwork:()->(session:Int,kind:MiniGameKind,moves:[MiniGameMove])?={nil}
    /// Reviews a network mini-game whose result has been verified, whatever ended it (the referee, a resignation, an
    /// agreement, a flag, abandonment), over every move from the start (`MiniGameReview.run(kind:moves:)`). The sheet
    /// opens only when asked (`showSheet`): a network game's result is announced first.
    public func start(session:Int,kind:MiniGameKind,moves:[MiniGameMove]){
        guard !kind.solo,!moves.isEmpty else{return}
        cancel();generation+=1;let budget=budget,clock=cpuSeconds
        launch(Task.detached(priority:.utility){MiniGameReview.run(kind:kind,moves:moves,budget:budget,cpuSeconds:clock,stop:{Task.isCancelled})},opens:false){[weak self] in
            guard let shown=self?.currentNetwork() else{return false};return shown.session==session && shown.kind==kind && shown.moves==moves
        }
    }
    private var openWhenReady=false
    private func launch(_ worker:Task<MiniGameReview,Never>,opens:Bool,stillShown:@escaping @MainActor ()->Bool){
        let epoch=generation;status = .running;openWhenReady=opens
        task=Task{[weak self] in
            let review=await withTaskCancellationHandler(operation:{await worker.value},onCancel:{worker.cancel()})
            guard let self,!Task.isCancelled,self.generation==epoch else{return}
            self.task=nil
            guard stillShown(),review.consistent else{self.status = .idle;self.identity=nil;return}
            self.status = .ready(review);if self.openWhenReady{self.sheetOpen=true}
        }
    }
    /// Restart, undo, a change of opponent and leaving the game end the review; nothing from it is shown afterwards.
    public func cancel(){generation+=1;task?.cancel();task=nil;identity=nil;if status != .idle{status = .idle};if sheetOpen{sheetOpen=false}}
    public func dismissSheet(){sheetOpen=false}
    /// Opens the sheet now, or as soon as the review running is ready.
    public func showSheet(){if case .ready=status{sheetOpen=true}else if status == .running{openWhenReady=true}}
    public var review:MiniGameReview? {if case .ready(let review)=status{return review};return nil}
    /// What voice may read aloud at `activity` (plan D5): this review of the game shown, while its sheet is open, its
    /// facts proved and the learner still at that mini-game. Nil during play, before or without a result, and once
    /// the sheet closes or anything else is shown.
    public func voiceScope(at activity:Activity)->MiniGameReviewVoiceScope? {
        guard sheetOpen,let review,!review.facts.isEmpty,let identity,case .at(let place)=activity,case .miniGame(_,let kind,_)=place,kind==identity.kind,let shown=current(),Identity(shown)==identity else{return nil}
        return MiniGameReviewVoiceScope(place:place,identity:identity,generation:generation)
    }
}
/// What reading a finished game's review aloud is bound to (plan D5): the mini-game place shown, the game reviewed
/// and that review's generation. A restart, undo, new review, closed sheet or another place is another scope.
public struct MiniGameReviewVoiceScope:Equatable {
    public let place:Place,identity:MiniGameReviewer.Identity,generation:Int
    public var kind:MiniGameKind {identity.kind}
}
/// What a mini-game review may say aloud: only its facts' exact text, with their own square cues, like
/// `ReviewVoiceScript` for a game review. The game is over, so nothing is assessed.
public enum MiniGameReviewVoiceScript {
    public static func segments(_ review:MiniGameReview)->[[String:Any]] {review.facts.prefix(3).map{["text":$0.text,"squares":Array($0.squares.prefix(8)),"kind":"focus"]}}
    public static func validate(_ segments:[SpeechSegment],review:MiniGameReview)throws {
        guard segments.count<=8 else{throw ProtocolFailure("INVALID_ARGUMENT")}
        for segment in segments {guard review.facts.contains(where:{$0.text==segment.text && Set(segment.squares).isSubset(of:Set($0.squares))}) else{throw ProtocolFailure("UNGROUNDED_REVIEW_SPEECH","Mini-game review narration must use a proved fact's exact text and its own square cues.")}}
    }
}
