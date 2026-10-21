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
    case lessonRecording,previewPlaying,narrationPlaying
    public var message:String {
        switch self {
        case .companionConnected:return "Voice is unavailable while Codex is connected to Checkmate."
        case .practiceOnly:return ReviewRolloutPolicy.reviewVoiceEnabled ? "The voice coach works in Practice and in game reviews.":"The voice coach works in Practice."
        case .trainingGameOnly:return "The voice coach connects only to a training game being played."
        case .networkGame:return "Voice coaching is off during your network game."
        case .reviewNotReadable:return "This review can no longer be read aloud."
        case .lessonRecording:return "Finish or cancel lesson recording before connecting the voice coach."
        case .previewPlaying:return "Wait for the voice preview to finish before connecting the voice coach."
        case .narrationPlaying:return "Stop lesson or preview playback before connecting the voice coach."
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
        case .disconnected:return "Disconnected"
        case .authorizing:return "Authorizing voice…"
        case .connecting:return "Connecting voice…"
        case .ready:return "Connected"
        case .failed(let reason):return reason
        case .unavailable(let reason):return reason.message
        }
    }
    /// An attempt is under way: Cancel is offered.
    public var inProgress:Bool {self == .authorizing || self == .connecting}
    /// Why the coach is not connected, when it did not end at the learner's request.
    public var problem:String? {switch self{case .failed,.unavailable:return text;default:return nil}}
}
