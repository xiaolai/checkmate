import CheckmateDomain
import CheckmateSupport
import CodexAuth
import Foundation
import RealtimeConnection

/// The one thing the learner can do about a voice or Codex problem (V-6). Each is a button.
public enum VoiceAction:String,CaseIterable,Sendable {
    case openMicrophoneSettings="Open Microphone Settings",tryAgain="Try Again",signIn="Sign In",getCodex="Get Codex",setUpCodex="Set Up Codex",openVoiceSettings="Open Voice Settings",openConnections="Open Connection Settings"
    public var title:String {rawValue}
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
        case .noCodex:return "Voice needs the Codex app, and it is not on this Mac."
        case .codexNotSetUp:return "Codex is not set up to use Checkmate's chess tools."
        case .codexTooOld:return "Codex on this Mac is too old for voice. Voice needs Codex \(minimumCodexVersion) or later."
        case .signedOut:return "Codex on this Mac is not signed in with your ChatGPT account."
        case .apiKeySignIn:return "Codex on this Mac is signed in with an API key, and voice uses your ChatGPT subscription instead."
        case .otherSignIn:return "Codex on this Mac is signed in another way, and voice needs a ChatGPT sign-in."
        case .signInExpired:return "Your Codex sign-in has expired."
        case .signInRejected:return "Your Codex sign-in was not accepted."
        case .keychainSignIn:return "Codex keeps its sign-in in the keychain, and this version of Codex cannot share it with Checkmate."
        case .otherProvider:return "Codex on this Mac uses a service other than ChatGPT, so voice cannot use its sign-in."
        case .codexUnresponsive:return "Codex on this Mac did not answer when Checkmate asked for its sign-in."
        case .accessRefused:return "Your ChatGPT account cannot use live voice."
        case .rateLimited:return "Your account has used live voice a lot recently, so it is paused for now."
        case .serviceDown:return "The live voice service is having trouble right now."
        case .offline:return "Checkmate cannot reach the live voice service from this Mac."
        case .requestRefused:return "The live voice service turned down this connection."
        case .noModel:return "No voice coach is available to your account right now."
        case .thinkingUnsupported:return "The voice coach available to your account cannot think at the level you chose."
        case .connectionLost:return "The voice connection ended."
        case .timedOut:return "The voice coach stopped answering."
        case .serviceError:return "The live voice service stopped this session."
        case .connectFailed:return "The voice coach could not connect."
        case .audioOutput:return "Your Mac could not play the coach's voice."
        case .microphoneDenied:return "Checkmate is not allowed to use the microphone."
        case .microphoneUnavailable:return "The selected microphone is not available."
        case .microphoneFormat:return "The selected microphone records in a format Checkmate cannot use."
        case .companionConnected:return "Codex is connected to Checkmate, so the voice coach cannot connect."
        case .networkGame:return "Voice coaching is off during your network game."
        case .notHere:return "The voice coach cannot connect to what is shown now."
        case .consentNeeded:return "The voice coach needs your agreement to what it sends to OpenAI before it connects."
        }
    }
    public var action:VoiceAction {
        switch self {
        case .noCodex,.codexTooOld,.keychainSignIn:return .getCodex
        case .signedOut,.apiKeySignIn,.otherSignIn,.signInExpired,.signInRejected,.otherProvider,.accessRefused:return .signIn
        case .codexUnresponsive,.rateLimited,.serviceDown,.offline,.requestRefused,.noModel,.connectionLost,.timedOut,.serviceError,.connectFailed,.audioOutput,.networkGame,.notHere,.consentNeeded:return .tryAgain
        case .thinkingUnsupported,.microphoneUnavailable,.microphoneFormat:return .openVoiceSettings
        case .microphoneDenied:return .openMicrophoneSettings
        case .codexNotSetUp:return .setUpCodex
        case .companionConnected:return .openConnections
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
    public var title:String {switch self {case .quick:return "Quick";case .balanced:return "Balanced";case .thorough:return "Thorough"}}
    public var detail:String {switch self {case .quick:return "Answers fastest.";case .balanced:return "Thinks a little longer before answering.";case .thorough:return "Thinks longest, and may take a while to answer."}}
    /// The learner's name for any reasoning effort, including the ones only Advanced offers.
    public static func name(effort:String)->String {CoachThinking(rawValue:effort)?.title ?? (effort=="xhigh" ? "Extra high":effort.capitalized)}
}
