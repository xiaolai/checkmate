import CheckmateAssets
import CheckmateDomain
import CheckmateSupport
import CodexAuth
import Foundation
import RealtimeConnection

/// The one thing the learner can do about a voice or Codex problem (V-6). Each is a button.
public enum VoiceAction:String,CaseIterable,Sendable {
    case openMicrophoneSettings="Open Microphone Settings",tryAgain="Try Again",signIn="Sign In",getCodex="Get Codex",setUpCodex="Set Up Codex",openVoiceSettings="Open Voice Settings",openConnections="Open Connection Settings"
    public var title:String {switch self{case .openMicrophoneSettings:return String(localized:"Open Microphone Settings",bundle:.checkmate);case .tryAgain:return String(localized:"Try Again",bundle:.checkmate);case .signIn:return String(localized:"Sign In",bundle:.checkmate);case .getCodex:return String(localized:"Get Codex",bundle:.checkmate);case .setUpCodex:return String(localized:"Set Up Codex",bundle:.checkmate);case .openVoiceSettings:return String(localized:"Open Voice Settings",bundle:.checkmate);case .openConnections:return String(localized:"Open Connection Settings",bundle:.checkmate)}}
}

/// Why voice or Codex could not do what was asked, as one plain cause and one action (V-6, V-7). The details (states,
/// HTTP statuses, error classes) go to the log; the learner reads only `cause` and presses `action`.
public enum VoiceFailure:String,Error,UserFacingError,CaseIterable,Equatable,Sendable {
    case noCodex,codexNotSetUp,codexTooOld,signedOut,apiKeySignIn,otherSignIn,signInExpired,signInRejected,keychainSignIn,otherProvider,codexUnresponsive
    case accessRefused,rateLimited,serviceDown,offline,requestRefused,noModel,thinkingUnsupported
    case connectionLost,timedOut,serviceError,connectFailed,audioOutput,microphoneDenied,microphoneUnavailable,microphoneFormat
    case companionConnected,networkGame,notHere,consentNeeded
    public var cause:String {
        switch self {
        case .noCodex:return String(localized:"Voice needs the Codex app, and it is not on this Mac.",bundle:.checkmate)
        case .codexNotSetUp:return String(localized:"Codex is not set up to use Checkmate's chess tools.",bundle:.checkmate)
        case .codexTooOld:return String(localized:"Codex on this Mac is too old for voice. Voice needs Codex \(minimumCodexVersion) or later.",bundle:.checkmate)
        case .signedOut:return String(localized:"Codex on this Mac is not signed in with your ChatGPT account.",bundle:.checkmate)
        case .apiKeySignIn:return String(localized:"Codex on this Mac is signed in with an API key, and voice uses your ChatGPT subscription instead.",bundle:.checkmate)
        case .otherSignIn:return String(localized:"Codex on this Mac is signed in another way, and voice needs a ChatGPT sign-in.",bundle:.checkmate)
        case .signInExpired:return String(localized:"Your Codex sign-in has expired.",bundle:.checkmate)
        case .signInRejected:return String(localized:"Your Codex sign-in was not accepted.",bundle:.checkmate)
        case .keychainSignIn:return String(localized:"Codex keeps its sign-in in the keychain, and this version of Codex cannot share it with Checkmate.",bundle:.checkmate)
        case .otherProvider:return String(localized:"Codex on this Mac uses a service other than ChatGPT, so voice cannot use its sign-in.",bundle:.checkmate)
        case .codexUnresponsive:return String(localized:"Codex on this Mac did not answer when Checkmate asked for its sign-in.",bundle:.checkmate)
        case .accessRefused:return String(localized:"Your ChatGPT account cannot use live voice.",bundle:.checkmate)
        case .rateLimited:return String(localized:"Your account has used live voice a lot recently, so it is paused for now.",bundle:.checkmate)
        case .serviceDown:return String(localized:"The live voice service is having trouble right now.",bundle:.checkmate)
        case .offline:return String(localized:"Checkmate cannot reach the live voice service from this Mac.",bundle:.checkmate)
        case .requestRefused:return String(localized:"The live voice service turned down this connection.",bundle:.checkmate)
        case .noModel:return String(localized:"No voice coach is available to your account right now.",bundle:.checkmate)
        case .thinkingUnsupported:return String(localized:"The voice coach available to your account cannot think at the level you chose.",bundle:.checkmate)
        case .connectionLost:return String(localized:"The voice connection ended.",bundle:.checkmate)
        case .timedOut:return String(localized:"The voice coach stopped answering.",bundle:.checkmate)
        case .serviceError:return String(localized:"The live voice service stopped this session.",bundle:.checkmate)
        case .connectFailed:return String(localized:"The voice coach could not connect.",bundle:.checkmate)
        case .audioOutput:return String(localized:"Your Mac could not play the coach's voice.",bundle:.checkmate)
        case .microphoneDenied:return String(localized:"Checkmate is not allowed to use the microphone.",bundle:.checkmate)
        case .microphoneUnavailable:return String(localized:"The selected microphone is not available.",bundle:.checkmate)
        case .microphoneFormat:return String(localized:"The selected microphone records in a format Checkmate cannot use.",bundle:.checkmate)
        case .companionConnected:return String(localized:"Codex is connected to Checkmate, so the voice coach cannot connect.",bundle:.checkmate)
        case .networkGame:return String(localized:"Voice coaching is off during your network game. The coach can connect once the game ends.",bundle:.checkmate)
        case .notHere:return String(localized:"The voice coach cannot connect to what is shown now. Return to Practice or a training game you are playing to connect it.",bundle:.checkmate)
        case .consentNeeded:return String(localized:"The voice coach needs your agreement to what it sends to OpenAI before it connects.",bundle:.checkmate)
        }
    }
    /// The one action that can fix it now; nil when nothing can until the learner leaves where they are, which the
    /// cause says.
    public var action:VoiceAction? {
        switch self {
        case .noCodex,.codexTooOld,.keychainSignIn:return .getCodex
        case .signedOut,.apiKeySignIn,.otherSignIn,.signInExpired,.signInRejected,.otherProvider,.accessRefused:return .signIn
        case .codexUnresponsive,.rateLimited,.serviceDown,.offline,.requestRefused,.noModel,.connectionLost,.timedOut,.serviceError,.connectFailed,.audioOutput,.consentNeeded:return .tryAgain
        case .thinkingUnsupported,.microphoneUnavailable,.microphoneFormat:return .openVoiceSettings
        case .microphoneDenied:return .openMicrophoneSettings
        case .codexNotSetUp:return .setUpCodex
        case .companionConnected:return .openConnections
        case .networkGame,.notHere:return nil
        }
    }
    public var userFacingMessage:String {cause}
    /// What a sign-in state means. Every state that is not ready has its own cause; not signed in and no sign-in file
    /// are the same thing to the learner.
    public static func signIn(_ state:CodexAuthState)->VoiceFailure {
        switch state {
        case .ready,.notSignedIn,.noSignInFile:return .signedOut
        case .apiKey:return .apiKeySignIn
        case .unsupportedAuth:return .otherSignIn
        case .noCodex:return .noCodex
        case .codexTooOld:return .codexTooOld
        case .expired:return .signInExpired
        case .appServerAuthUnavailable:return .keychainSignIn
        case .providerWithoutOpenAIAuth:return .otherProvider
        case .codexError:return .codexUnresponsive
        }
    }
    /// What a refused or failed realtime request means, by the class sayso gave it.
    public static func realtime(_ errorClass:ErrorClass)->VoiceFailure {
        switch errorClass {
        case .authExpired:return .signInRejected
        case .routeDenied:return .accessRefused
        case .rateLimited:return .rateLimited
        case .server:return .serviceDown
        case .network:return .offline
        default:return .requestRefused
        }
    }
    /// Any error from connecting, as one failure; `fallback` is the failure for an error nothing here recognises. The
    /// error's own words go to the log only.
    public static func from(_ error:Error,fallback:VoiceFailure = .connectFailed)->VoiceFailure {
        if let failure=error as? VoiceFailure {return failure}
        if let failure=error as? CodexAuthError {NativeLog.voice.error("Voice sign-in unavailable: \(failure.state.rawValue, privacy: .public)");return signIn(failure.state)}
        if let failure=error as? RealtimeError {NativeLog.voice.error("Voice request failed: \(failure.errorClass.rawValue, privacy: .public), HTTP \(failure.status, privacy: .public)");return realtime(failure.errorClass)}
        if let code=refusalCode(error),let failure=refusal(code) {NativeLog.voice.error("Voice refused: \(code, privacy: .public)");return failure}
        NativeLog.voice.error("Voice failed: \(String(describing:error), privacy: .public)")
        return fallback
    }
    /// A session refusal by its code: Codex holds the session, a network game allows no coach (`FairnessPolicy.refusal`),
    /// or the coach does not connect to what is shown. Any other code is not a refusal.
    public static func refusal(_ code:String)->VoiceFailure? {
        switch code {
        case "SESSION_IN_USE":return .companionConnected
        case "NETWORK_GAME":return .networkGame
        case "UNSUPPORTED_MODE":return .notHere
        default:return nil
        }
    }
    private static func refusalCode(_ error:Error)->String? {
        if let failure=error as? ProtocolFailure {return failure.code}
        if case .invalid(let code)? = error as? CheckmateError {return code}
        if case .unavailable(let code)? = error as? CheckmateError {return code}
        return nil
    }
}

/// How long the coach thinks before it answers, in the learner's words (V-28). Each level is a reasoning effort the
/// voice models accept; Advanced settings still offer every effort.
public enum CoachThinking:String,CaseIterable,Sendable {
    case quick="minimal",balanced="low",thorough="high"
    public var title:String {switch self {case .quick:return String(localized:"Quick",bundle:.checkmate);case .balanced:return String(localized:"Balanced",bundle:.checkmate);case .thorough:return String(localized:"Thorough",bundle:.checkmate)}}
    public var detail:String {switch self {case .quick:return String(localized:"Answers fastest.",bundle:.checkmate);case .balanced:return String(localized:"Thinks a little longer before answering.",bundle:.checkmate);case .thorough:return String(localized:"Thinks longest, and may take a while to answer.",bundle:.checkmate)}}
    /// The learner's name for any reasoning effort, including the ones only Advanced offers.
    public static func name(effort:String)->String {CoachThinking(rawValue:effort)?.title ?? (effort=="xhigh" ? String(localized:"Extra high",bundle:.checkmate):effort.capitalized)}
}
