import SwiftUI
import CheckmateCore

/// The post-game review of a finished mini-game (WI-018): proved facts as text, and nothing during play.
enum MiniGameReviewWording {
    static let method="Each fact below was proved by checking every reply, up to \(MiniGameProofBudget.plies) single moves ahead, under this game’s rules."
    static let running="Checking the game for forced wins…"
    static let incomplete="The review ran out of time before it had checked every position."
    static let noFacts="No forced win was proved within \(MiniGameProofBudget.plies) single moves of any position in this game."
    static func summary(_ review:MiniGameReview)->String {review.facts.isEmpty ? noFacts:"\(review.facts.count) proved \(review.facts.count==1 ? "fact":"facts") about this game."}
}
/// The details drawer's part: the review's progress, and the way back to its sheet once dismissed.
struct MiniGameReviewSection:View {
    @ObservedObject var reviewer:MiniGameReviewer
    var body:some View {
        switch reviewer.status {
        case .idle:EmptyView()
        case .running:ProgressView(MiniGameReviewWording.running).accessibilityIdentifier("mini-review-running")
        case .ready(let review):
            Text("Game review").font(.headline)
            Text(MiniGameReviewWording.summary(review)).foregroundStyle(.secondary)
            Button("Show Review"){reviewer.showSheet()}.accessibilityIdentifier("mini-review-show")
        }
    }
}
/// The sheet shown over the board when a finished game's review is ready.
struct MiniGameReviewSheet:View {
    let review:MiniGameReview
    @ObservedObject var voice:VoiceCoach
    let read:()->Void,close:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:Metrics.sectionGap) {
            Text("\(review.kind.title) review").font(.title2.bold())
            Text(MiniGameReviewWording.method).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if review.facts.isEmpty {Text(MiniGameReviewWording.noFacts).accessibilityIdentifier("mini-review-none")}
            else {ForEach(Array(review.facts.enumerated()),id:\.offset){Text($0.element.text).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("mini-review-fact")}}
            if !review.complete {Text(MiniGameReviewWording.incomplete).font(.caption).foregroundStyle(.secondary)}
            HStack {MiniGameReviewReadAloud(voice:voice,read:read);Spacer();Button("Done",action:close).keyboardShortcut(.defaultAction).accessibilityIdentifier("mini-review-done")}
        }.padding(Metrics.sectionGap*1.5).frame(width:420,alignment:.leading)
    }
}
/// D5: with a sign-in, the facts are read aloud word for word, and nothing else is said or heard. Without one the
/// review stays text only. Closing the sheet ends the reading.
struct MiniGameReviewReadAloud:View {
    @ObservedObject var voice:VoiceCoach
    /// Reads the review aloud, after the voice consent question (V-1) and any sign-in check it needs.
    let read:()->Void
    var body:some View {
        if voice.miniReviewSession != nil,voice.connected || voice.connecting {
            Button("Stop Reading"){voice.disconnect()}.accessibilityIdentifier("mini-review-stop")
            Text(voice.status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("mini-review-voice-status")
        } else if voice.miniReviewReadable {
            Button("Read Aloud",action:read).accessibilityIdentifier("mini-review-read-aloud")
            if let problem=voice.miniReviewProblem {Text(problem).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        } else if voice.miniReviewNeedsSignIn {
            // The review stays readable as text without a sign-in; this says why, and offers the check in place.
            Button("Read Aloud",action:read).disabled(voice.checkingAvailability).accessibilityIdentifier("mini-review-read-aloud")
            Text(voice.checkingAvailability ? "Checking your Codex sign-in…":"Read Aloud checks your Codex sign-in first.").font(.caption).foregroundStyle(.secondary)
            if let problem=voice.miniReviewProblem {Text(problem).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        }
    }
}
