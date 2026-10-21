import SwiftUI
import CheckmateCore

/// Retry mode's panel (R-18): its start button once the game is analyzed with a costly move to retry, then each
/// position's prompt, the verdict on every try and the way on. Engine help, so absent during a network game.
struct ReviewRetrySection:View {
    @ObservedObject var retry:ReviewRetry
    @ObservedObject var analyzer:ReviewAnalyzer
    @ObservedObject var model:NativeModel
    let document:GameDocument
    /// The learner's side in their own game; both sides of any other record.
    private var side:String? {ReviewRetry.learnerSide(document.provenance,current:model.session.humanSide,previous:model.session.state.practice.previousSide)}
    private func run(_ fallback:String,_ work:()throws->Void){do{try work()}catch{model.storageError=userFacingMessage(error,fallback:fallback)}}
    var body:some View {
        if retry.active {
            VStack(alignment:.leading,spacing:Metrics.smallGap){
                Text("Retry your mistakes").sectionHeading()
                if retry.phase != .finished{Text("Position \(retry.index+1) of \(retry.targets.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()}
                HStack(alignment:.firstTextBaseline,spacing:Metrics.tightGap){
                    if case .judging=retry.phase{ProgressView().controlSize(.small)}
                    Text(verbatim:retry.message).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("review-retry-message")
                }
                HStack(spacing:Metrics.smallGap){
                    switch retry.phase {
                    case .solved,.revealed:Button(retry.index+1<retry.targets.count ? String(localized:"Next Position",bundle:.checkmate):String(localized:"See Summary",bundle:.checkmate)){run(String(localized:"The next position could not be shown.",bundle:.checkmate)){try retry.next()}}.buttonStyle(.borderedProminent).accessibilityIdentifier("review-retry-next")
                    default:EmptyView()
                    }
                    Spacer(minLength:0)
                    Button(retry.phase == .finished ? String(localized:"Done",bundle:.checkmate):String(localized:"Stop Retrying",bundle:.checkmate)){retry.end()}.accessibilityIdentifier("review-retry-stop")
                }.controlSize(.small)
            }
        } else if retry.available(side:side) {
            VStack(alignment:.leading,spacing:Metrics.tightGap){
                Button("Retry Mistakes"){run(String(localized:"Retry mode could not start.",bundle:.checkmate)){try retry.start(side:side)}}.accessibilityIdentifier("review-retry-start")
                Text(side==nil ? String(localized:"Find a better move in each position where a player went wrong.",bundle:.checkmate):String(localized:"Find a better move in each position where you went wrong.",bundle:.checkmate)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
}
