import SwiftUI
import CheckmateCore
/// The lesson drawer on an exercise step: what to do, how it is going, and the ways to recover or move on.
/// The board itself takes the moves; nothing here starts another activity or touches the practice game.
struct LessonAttemptPanel:View {
    @ObservedObject var learning:LearningPlayer
    let continueLesson:()->Void
    private var attempt:LessonAttemptController {learning.attempt}
    private var practice:LessonPractice? {attempt.practice}
    private var headline:String {
        guard let phase=attempt.phase else{return ""}
        if attempt.waitingToResume{return "Your attempt is paused."}
        if attempt.thinking{return "The computer is thinking…"}
        switch phase {
        case .yourTurn:return "Your turn. Move a White piece on the board."
        case .computerTurn:return "The computer is about to move."
        case .offTrack:return "Not quite. Undo your move and try again."
        case .failed:return "This attempt cannot reach the goal any more."
        case .achieved:return "Well done!"
        case .playingOn:return attempt.rules.turn=="w" ? "Play on: your move.":"Play on: the computer is about to move."
        case .finished:return "The game is over."
        }
    }
    private var hintLabel:String {attempt.canShowMove ? "Show me a move":(attempt.record?.hints ?? 0)==0 ? "Hint":"Another hint"}
    var body:some View {
        VStack(alignment:.leading,spacing:Metrics.smallGap) {
            Text(headline).font(.headline).accessibilityIdentifier("lesson-attempt-status")
            if let practice {Text(practice.goal).foregroundStyle(.secondary)}
            ForEach(Array(zip(practice?.checkpoints ?? [],attempt.judgement?.done ?? []).enumerated()),id:\.offset){_,item in
                Label(item.0.label,systemImage:item.1 ? "checkmark.circle.fill":"circle")
                    .foregroundStyle(item.1 ? Color.accentColor:Color.secondary)
                    .accessibilityLabel(item.0.label+(item.1 ? ", done":", not done yet"))
            }
            if learning.playing,attempt.hasMoves {Text("The instruction describes the starting position; your game stays as it is.").font(.caption).foregroundStyle(.secondary)}
            if let text=attempt.notice ?? attempt.judgement?.feedback {Text(text).textSelection(.enabled).accessibilityIdentifier("lesson-attempt-feedback")}
            ForEach(Array(attempt.hints.enumerated()),id:\.offset){index,hint in Text("Hint \(index+1): \(hint)").foregroundStyle(.secondary)}
            HStack {
                if attempt.waitingToResume {Button("Resume"){attempt.resume()}.accessibilityIdentifier("lesson-attempt-resume")}
                if attempt.phase == .achieved,attempt.judgement?.ending==nil {Button("Play on"){attempt.playOn()}.accessibilityIdentifier("lesson-attempt-play-on")}
                if attempt.thinking {ProgressView().controlSize(.small).help("The computer is thinking")}
            }
            HStack {
                Button(hintLabel){attempt.hint()}.disabled(!(attempt.learnerToMove || attempt.phase == .offTrack)).accessibilityIdentifier("lesson-attempt-hint")
                Button("Undo turn"){attempt.undo()}.disabled(!attempt.hasMoves).accessibilityIdentifier("lesson-attempt-undo")
                Button("Restart"){attempt.restart()}.disabled(!attempt.hasMoves).accessibilityIdentifier("lesson-attempt-restart")
            }
            if let next=learning.library.nextMainLesson(after:learning.lessonIndex) {
                Button("Continue to \(learning.localizedTitle(index:next))"){learning.complete();continueLesson()}.accessibilityIdentifier("lesson-attempt-continue")
            }
        }
    }
}
