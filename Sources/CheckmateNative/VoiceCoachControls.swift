import SwiftUI
import CheckmateCore
/// The voice coach's buttons, worded and ordered the same on every surface that offers them (V-26): a surface's own
/// actions first while it holds the session, then Stop Speaking and Disconnect Voice Coach; Cancel Voice Coach while
/// connecting; otherwise Connect Voice Coach when the surface offers it. Identifiers are `<idPrefix>-<role>`.
struct VoiceCoachControls:View {
    struct Action:Identifiable {let id:String,title:String,run:()->Void}
    static let connectTitle="Connect Voice Coach",cancelTitle="Cancel Voice Coach",stopTitle="Stop Speaking",disconnectTitle="Disconnect Voice Coach"
    @ObservedObject var voice:VoiceCoach
    let idPrefix:String
    /// Whether the live session is this surface's (a network or training coach belongs to its own activity).
    var owned=true
    var actions:[Action]=[]
    /// Nil when this surface does not start a session itself.
    var connect:(()->Void)?=nil
    var body:some View {
        HStack(spacing:Metrics.smallGap) {
            if voice.connected,owned {
                ForEach(actions){action in Button(action.title,action:action.run).accessibilityIdentifier("\(idPrefix)-\(action.id)")}
                Button(Self.stopTitle){voice.stopTurn()}.disabled(!voice.canStopTurn).accessibilityIdentifier("\(idPrefix)-stop")
                Button(Self.disconnectTitle){voice.disconnect()}.accessibilityIdentifier("\(idPrefix)-disconnect")
            } else if voice.connecting {Button(Self.cancelTitle){voice.disconnect()}.accessibilityIdentifier("\(idPrefix)-cancel")}
            else if let connect {Button(Self.connectTitle,action:connect).accessibilityIdentifier("\(idPrefix)-connect")}
        }
    }
}
