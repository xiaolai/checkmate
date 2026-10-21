import SwiftUI
import CheckmateCore
/// The lesson drawer on an exercise step: what to do, how it is going, and the ways to recover or move on.
/// The board itself takes the moves; nothing here starts another activity or touches the practice game.
struct LessonAttemptPanel:View {
    @ObservedObject var learning:LearningPlayer
    let continueLesson:()->Void
    /// Restart, confirmed first when it would lose more than the first exchange (`NativeModel.requestRestartAttempt`).
    let restart:()->Void
    private var attempt:LessonAttemptController {learning.attempt}
    private var practice:LessonPractice? {attempt.practice}
    private var headline:String {
        guard let phase=attempt.phase else{return ""}
        if attempt.waitingToResume{return String(localized:"Your attempt is paused.",bundle:.checkmate)}
        if attempt.thinking{return String(localized:"The computer is thinking…",bundle:.checkmate)}
        switch phase {
        case .yourTurn:return String(localized:"Your turn. Move a White piece on the board.",bundle:.checkmate)
        case .computerTurn:return String(localized:"The computer is about to move.",bundle:.checkmate)
        case .offTrack:return String(localized:"Not quite. Take back your move and try again.",bundle:.checkmate)
        case .failed:return String(localized:"This attempt cannot reach the goal any more.",bundle:.checkmate)
        case .achieved:return String(localized:"Well done!",bundle:.checkmate)
        case .playingOn:return attempt.rules.turn=="w" ? String(localized:"Play on: your move.",bundle:.checkmate):String(localized:"Play on: the computer is about to move.",bundle:.checkmate)
        case .finished:return String(localized:"The game is over.",bundle:.checkmate)
        }
    }
    private var hintLabel:String {attempt.canShowMove ? String(localized:"Show me a move",bundle:.checkmate):(attempt.record?.hints ?? 0)==0 ? String(localized:"Hint",bundle:.checkmate,comment:"Noun: ask for a hint"):String(localized:"Another hint",bundle:.checkmate)}
    var body:some View {
        VStack(alignment:.leading,spacing:Metrics.smallGap) {
            Text(headline).font(.headline).accessibilityIdentifier("lesson-attempt-status")
            if let practice {Text(practice.goal).foregroundStyle(.secondary)}
            ForEach(Array(zip(practice?.checkpoints ?? [],attempt.judgement?.done ?? []).enumerated()),id:\.offset){_,item in
                Label(item.0.label,systemImage:(item.1 ? AppSymbol.done:.markerOff).rawValue)
                    .foregroundStyle(item.1 ? Color.accentColor:Color.secondary)
                    .accessibilityLabel(item.1 ? String(localized:"\(item.0.label), done",bundle:.checkmate,comment:"A lesson checkpoint that is done"):String(localized:"\(item.0.label), not done yet",bundle:.checkmate,comment:"A lesson checkpoint that is not done yet"))
            }
            if learning.playing,attempt.hasMoves {Text("The instruction describes the starting position; your game stays as it is.").font(.caption).foregroundStyle(.secondary)}
            if let text=attempt.notice ?? attempt.judgement?.feedback {Text(text).textSelection(.enabled).accessibilityIdentifier("lesson-attempt-feedback")}
            ForEach(Array(attempt.hints.enumerated()),id:\.offset){index,hint in Text("Hint \(index+1): \(hint)").foregroundStyle(.secondary)}
            HStack {
                if attempt.waitingToResume {Button("Resume"){attempt.resume()}.accessibilityIdentifier("lesson-attempt-resume")}
                if attempt.phase == .achieved,attempt.judgement?.ending==nil {Button("Play On"){attempt.playOn()}.accessibilityIdentifier("lesson-attempt-play-on")}
                if attempt.thinking {ProgressView().controlSize(.small).help("The computer is thinking")}
            }
            // Off track the refutation stays on the board until the learner takes the move back: one prominent way back.
            HStack {
                if attempt.phase == .offTrack {Button("Take Back"){attempt.undo()}.buttonStyle(.borderedProminent).accessibilityIdentifier("lesson-attempt-undo")}
                else {
                    Button(hintLabel){attempt.hint()}.disabled(!attempt.learnerToMove).accessibilityIdentifier("lesson-attempt-hint")
                    Button("Undo Turn"){attempt.undo()}.disabled(!attempt.hasMoves).accessibilityIdentifier("lesson-attempt-undo")
                }
                Button("Restart"){restart()}.disabled(!attempt.hasMoves).accessibilityIdentifier("lesson-attempt-restart")
            }
            if let next=learning.library.nextMainLesson(after:learning.lessonIndex) {
                Button("Continue to \(learning.localizedTitle(index:next))"){learning.complete();continueLesson()}.accessibilityIdentifier("lesson-attempt-continue")
            }
        }
    }
}
