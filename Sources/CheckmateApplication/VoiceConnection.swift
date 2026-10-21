import CheckmateAssets
import CheckmateDomain

/// Why the voice coach cannot connect now, said in the learner's words. Every place that refuses a connection names
/// one of these, and every label, tooltip and status line shows its `message`.
public enum VoiceUnavailability:Equatable,Sendable {
    /// Codex (or another MCP client) holds the session.
    case companionConnected
    /// The practice coach connects only in Practice, or to a game review when review voice is on.
    case practiceOnly
    /// The training coach connects only to a training game being played.
    case trainingGameOnly
    /// The learner is in a network game whose level does not allow the coach (LAN-play plan D8).
    case networkGame
    /// A finished game's review is no longer the one shown, or something else holds the session.
    case reviewNotReadable
    /// The learner has not yet agreed to what voice sends to OpenAI (V-1); a Connect press asks first.
    case consentNeeded
    /// Neither the Codex app nor its ChatGPT sign-in is on this Mac (V-5): voice could only fail, so it is explained.
    case codexMissing
    case lessonRecording,previewPlaying,narrationPlaying
    public var message:String {
        switch self {
        case .companionConnected:return String(localized:"Voice is unavailable while Codex is connected to Checkmate.",bundle:.checkmate)
        case .practiceOnly:return ReviewRolloutPolicy.reviewVoiceEnabled ? String(localized:"The voice coach works in Practice and in game reviews.",bundle:.checkmate):String(localized:"The voice coach works in Practice.",bundle:.checkmate)
        case .trainingGameOnly:return String(localized:"The voice coach connects only to a training game being played.",bundle:.checkmate)
        case .networkGame:return String(localized:"Voice coaching is off during your network game.",bundle:.checkmate)
        case .reviewNotReadable:return String(localized:"This review can no longer be read aloud.",bundle:.checkmate)
        case .consentNeeded:return String(localized:"Connect the voice coach and agree to what it sends to OpenAI first.",bundle:.checkmate)
        case .codexMissing:return String(localized:"The voice coach needs the Codex app, signed in with your ChatGPT account. Settings › Voice Coach shows what you need.",bundle:.checkmate)
        case .lessonRecording:return String(localized:"Finish or cancel lesson recording before connecting the voice coach.",bundle:.checkmate)
        case .previewPlaying:return String(localized:"Wait for the voice preview to finish before connecting the voice coach.",bundle:.checkmate)
        case .narrationPlaying:return String(localized:"Stop lesson or preview playback before connecting the voice coach.",bundle:.checkmate)
        }
    }
}

/// Where the voice coach's connection stands. Logic reads this, never the status line shown with it.
public enum VoiceConnectionState:Equatable,Sendable {
    case disconnected,authorizing,connecting,ready
    /// The connection attempt or a live session ended without the learner asking; the reason is said to them.
    case failed(String)
    /// A connection was refused before anything was opened.
    case unavailable(VoiceUnavailability)
    /// The status line for a state; a ready session shows what it is doing instead.
    public var text:String {
        switch self {
        case .disconnected:return String(localized:"Disconnected",bundle:.checkmate)
        case .authorizing:return String(localized:"Authorizing voice…",bundle:.checkmate)
        case .connecting:return String(localized:"Connecting voice…",bundle:.checkmate)
        case .ready:return String(localized:"Connected",bundle:.checkmate)
        case .failed(let reason):return reason
        case .unavailable(let reason):return reason.message
        }
    }
    /// An attempt is under way: Cancel is offered.
    public var inProgress:Bool {self == .authorizing || self == .connecting}
    /// Why the coach is not connected, when it did not end at the learner's request.
    public var problem:String? {switch self{case .failed,.unavailable:return text;default:return nil}}
}
