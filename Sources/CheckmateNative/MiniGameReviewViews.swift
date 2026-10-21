import SwiftUI
import CheckmateCore

/// The post-game review of a finished mini-game (WI-018): proved facts as text, and nothing during play. The words are a
/// learner's (L-25): what could have happened, not how the search proved it.
enum MiniGameReviewWording {
    static let method=String(localized:"Checkmate tried every possible reply, up to \(MiniGameProofBudget.plies) turns ahead, so each of these is certain.",bundle:.checkmate)
    static let running=String(localized:"Looking back over the game…",bundle:.checkmate)
    static let incomplete=String(localized:"There was not enough time to look at every position in this game.",bundle:.checkmate)
    static let noFacts=String(localized:"Neither side could have made sure of a win within \(MiniGameProofBudget.plies) turns at any point in this game.",bundle:.checkmate)
    static func summary(_ review:MiniGameReview)->String {review.facts.isEmpty ? noFacts:String(localized:"\(review.facts.count) things to look at from this game.",bundle:.checkmate)}
}
/// The details drawer's part: the review's progress, and the way back to its sheet once dismissed.
struct MiniGameReviewSection:View {
    @ObservedObject var reviewer:MiniGameReviewer
    var body:some View {
        switch reviewer.status {
        case .idle:EmptyView()
        case .running:ProgressView(MiniGameReviewWording.running).accessibilityIdentifier("mini-review-running")
        case .ready(let review):
            Text("Game review").sectionHeading()
            Text(MiniGameReviewWording.summary(review)).foregroundStyle(.secondary)
            Button("Show Review"){reviewer.showSheet()}.accessibilityIdentifier("mini-review-show")
        }
    }
}
/// The sheet shown over the board when a finished game's review is ready.
struct MiniGameReviewSheet:View {
    /// The width the sheet opens at and the narrowest it goes (L-25: resizable, no longer fixed at this width).
    static let minimumWidth:CGFloat=420
    let review:MiniGameReview
    @ObservedObject var voice:VoiceCoach
    let read:()->Void,close:()->Void
    /// Shows a fact's position on the board (by its index); nil where the board shown is not the reviewed game's.
    let show:((Int)->Void)?
    var body:some View {
        VStack(alignment:.leading,spacing:Metrics.sectionGap) {
            Text("\(review.kind.title) review").sectionHeading(.title2.bold())
            Text(MiniGameReviewWording.method).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if review.facts.isEmpty {Text(MiniGameReviewWording.noFacts).accessibilityIdentifier("mini-review-none")}
            else {ForEach(Array(review.facts.enumerated()),id:\.offset){index,fact in
                HStack(alignment:.firstTextBaseline) {
                    Text(fact.text).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("mini-review-fact")
                    if let show {Button("Show on Board"){show(index)}.accessibilityIdentifier("mini-review-show-on-board")}
                }
            }}
            if !review.complete {Text(MiniGameReviewWording.incomplete).font(.caption).foregroundStyle(.secondary)}
            HStack {MiniGameReviewReadAloud(voice:voice,read:read);Spacer();Button("Done",action:close).keyboardShortcut(.defaultAction).accessibilityIdentifier("mini-review-done")}
        }.padding(Metrics.sectionGap*1.5).frame(minWidth:Self.minimumWidth,idealWidth:Self.minimumWidth,maxWidth:.infinity,alignment:.leading)
    }
    /// The sheet's window: it opens at its ideal size and the learner can make it larger, never narrower than its minimum.
    /// The default sizing (`standardBounds`) would also cap the window at the content's maximum; only its minimum and
    /// opening size come from the content here. The minimum width is also set at once: the content's own minimum
    /// reaches the window only after its first layout.
    @MainActor static func window(_ sheet:MiniGameReviewSheet)->NSWindow {
        let host=NSHostingController(rootView:sheet);host.sizingOptions=[.minSize,.preferredContentSize]
        let window=NSWindow(contentViewController:host);window.styleMask.insert(.resizable);window.title=String(localized:"\(sheet.review.kind.title) review",bundle:.checkmate,comment:"The title of a finished mini-game's review sheet")
        window.contentMinSize=NSSize(width:minimumWidth,height:window.contentMinSize.height)
        return window
    }
}
/// The details drawer's way back from a fact shown on the board (L-25): what it says, and the game's final position.
struct MiniGameShownFact:View {
    @ObservedObject var learning:LearningPlayer
    var body:some View {
        if let index=learning.miniShownFact,let facts=learning.miniReview.review?.facts,facts.indices.contains(index) {
            Text(facts[index].text).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("mini-shown-fact")
            Button("Show Final Position"){learning.showMiniEnd()}.accessibilityIdentifier("mini-show-final")
        }
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
            Text(voice.checkingAvailability ? String(localized:"Checking your Codex sign-in…",bundle:.checkmate):String(localized:"Read Aloud checks your Codex sign-in first.",bundle:.checkmate)).font(.caption).foregroundStyle(.secondary)
            if let problem=voice.miniReviewProblem {Text(problem).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        }
    }
}
