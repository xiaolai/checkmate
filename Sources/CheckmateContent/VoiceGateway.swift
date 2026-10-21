import CheckmateAssets
import CheckmateDomain
import CheckmateSupport
import CodexAuth
import Foundation
import RealtimeConnection
public struct VoiceTurnGate {
    private var generating=false,playing=false,ended=false
    public init(){}
    public var ready:Bool{!generating && !playing}
    /// A response is still being generated (as opposed to only its audio still playing).
    public var generatingResponse:Bool{generating}
    public mutating func begin(){generating=true;ended=false}
    public mutating func generated(hasAudio:Bool){generating=false;if hasAudio && !ended{playing=true}}
    public mutating func playbackStarted(){playing=true}
    public mutating func playbackEnded(){playing=false;ended=true}
    public mutating func reset(){generating=false;playing=false;ended=false}
}
/// Voice runs on the learner's ChatGPT subscription only, through Codex's sign-in (sayso's CodexAuth): Codex is asked for
/// the token and renews it itself; without an installed Codex, Codex's sign-in file is read and never written. An
/// API-key sign-in (and its key) is never used. The token only mints a short-lived realtime secret.
public final class VoiceGateway:Sendable {
    /// Codex's sign-in file, read by voice only when no Codex is installed (lesson translation never reads it: its
    /// private home is signed in from the token). It is where sayso's CodexAuth reads it: in `CODEX_HOME` when that is
    /// set, followed through links, else in ~/.codex.
    public static var credentialURL:URL{credentialURL(environment:ProcessInfo.processInfo.environment,home:FileManager.default.homeDirectoryForCurrentUser)}
    public static func credentialURL(environment:[String:String],home:URL)->URL{
        guard let codexHome=environment["CODEX_HOME"],!codexHome.isEmpty else{return home.appendingPathComponent(".codex/auth.json")}
        return URL(fileURLWithPath:codexHome,isDirectory:true).resolvingSymlinksInPath().appendingPathComponent("auth.json")
    }
    /// The mint request's limit and the whole exchange's, in seconds.
    public static let mintTimeout:TimeInterval=20,mintResourceTimeout:TimeInterval=25
    /// The asked lifetime of a realtime secret, the provider's default: a secret only opens a socket.
    public static let secretLifetime=600
    /// A sign-in with less than this left is renewed through Codex before it is used; one read from the file is expired.
    public static let signInMargin:TimeInterval=60
    /// Bounds each call to Codex while it fetches or renews the sign-in.
    public static let codexTimeout:TimeInterval=20
    /// One sign-in for the process: Codex runs only to fetch or renew the token, which stays in memory.
    static let credentials=Result{try Credentials(CodexAuthConfiguration(margin:signInMargin,timeout:codexTimeout,clientName:"checkmate",guardAccess:{_ in if NativePolicy.silent{throw CheckmateError.unavailable(String(localized:"Live voice is disabled during automation.",bundle:.checkmate))}},log:{NativeLog.voice.debug("\($0)")}))}
    private let client:HTTPClient
    public init(){let configuration=URLSessionConfiguration.ephemeral;configuration.timeoutIntervalForResource=Self.mintResourceTimeout;client=HTTPClient(configuration:configuration)}
    /// What a sign-in state means for the learner (V-6): one cause and its action. Every state that is not ready has its own.
    public static func signInFailure(_ state:CodexAuthState)->VoiceFailure {VoiceFailure.signIn(state)}
    /// A model the account cannot open a session for; the next candidate model is tried.
    public struct ModelUnsupported:Error {public let status:Int}
    /// What a failed mint means for the learner. 400, 404 and 422 name the model as the problem, so selection moves on;
    /// every other failure is about the sign-in, the account or the service and stops it.
    public static func authorizationFailure(_ error:Error)->Error {
        if error is CancellationError || Task.isCancelled {return CancellationError()}
        if error is CheckmateError || error is ModelUnsupported || error is VoiceFailure {return error}
        if let failure=error as? RealtimeError {
            if failure.errorClass == .cancelled {return CancellationError()}
            if [400,404,422].contains(failure.status) {return ModelUnsupported(status:failure.status)}
        }
        return VoiceFailure.from(error,fallback:.requestRefused)
    }
    /// A realtime secret for a session of `model`, minted with Codex's sign-in (renewed once if the provider refuses it).
    public func authorize(model:String="gpt-realtime") async throws->ClientSecret {
        guard !NativePolicy.silent else{throw CheckmateError.unavailable(String(localized:"Live voice is disabled during automation.",bundle:.checkmate))}
        do {
            let minter=Minter(client:client,credentials:try Self.credentials.get(),timeout:Self.mintTimeout,lifetimeSeconds:Self.secretLifetime)
            return try await minter.secret(session:JSONSerialization.data(withJSONObject:["type":"realtime","model":model]))
        } catch {throw Self.authorizationFailure(error)}
    }
}

/// A realtime session (sayso's) speaking JSON objects, with Checkmate's caps. Every voice socket of the app is one.
public final class VoiceSocket:Sendable {
    /// The read limit of every session but the lesson recorder's (LessonRecording.maximumMessageBytes).
    public static let maximumMessageBytes=2*1024*1024
    private let session:RealtimeSession
    private init(_ session:RealtimeSession){self.session=session}
    /// Opens `model`'s session with `secret`. `resourceTimeout` bounds the whole connection; nil leaves URLSession's.
    public static func open(secret:ClientSecret,model:String,handshakeTimeout:TimeInterval,readLimit:Int=maximumMessageBytes,resourceTimeout:TimeInterval?=nil)async throws->VoiceSocket {
        let configuration=URLSessionConfiguration.ephemeral;if let resourceTimeout{configuration.timeoutIntervalForResource=resourceTimeout}
        return VoiceSocket(try await RealtimeSession.open(client:HTTPClient(configuration:configuration),secret:secret,configuration:.init(url:RealtimeSession.url(model:model),handshakeTimeout:handshakeTimeout,readLimit:readLimit)))
    }
    public func send(_ event:[String:Any])async throws {try await send(data:JSONSerialization.data(withJSONObject:event))}
    /// Sends one encoded JSON object.
    public func send(data:Data)async throws {try await session.send(data)}
    /// The next message's bytes. A message over the read limit, a close or a broken connection ends the session.
    public func receiveData()async throws->Data {try await session.next().raw}
    /// The next event; one that is not a JSON object fails.
    public func receive()async throws->[String:Any] {guard let event=try JSONSerialization.jsonObject(with:try await receiveData()) as? [String:Any] else{throw CheckmateError.invalid(String(localized:"Malformed voice event",bundle:.checkmate))};return event}
    /// Closes the session: a normal close, dropped if the provider does not finish it promptly.
    public func close()async {await session.close()}
    /// Closes the session without waiting, for a caller that cannot.
    public func closeSoon(){let session=session;Task{await session.close()}}
}

/// One configuration shared by the app and explicit headless service acceptance.
public enum VoiceSessionConfiguration {
    public static let model="gpt-realtime-2.1"
    public static func reasoningEvent(effort:String)->[String:Any] {
        ["type":"session.update","session":["type":"realtime","reasoning":["effort":AppSettings.reasoningEfforts.contains(effort) ? effort:"minimal"]]]
    }
    /// Low eagerness waits through a beginner's thinking pause instead of answering half a question.
    public static let eagerness="low"
    /// Transcription settings: a language hint only when the learner chose one (ISO-639-1, as the provider expects).
    public static func transcription(language:String?)->[String:Any] {var value:[String:Any]=["model":"gpt-4o-mini-transcribe"];if let language,!language.isEmpty{value["language"]=language};return value}
    public static func transcriptionEvent(language:String?)->[String:Any] {["type":"session.update","session":["type":"realtime","audio":["input":["transcription":transcription(language:language)]]]]}
    public static func event(instructions:String,voice:String,tools:[[String:Any]],effort:String="minimal",inputLanguage:String?=nil)->[String:Any] {
        ["type":"session.update","session":["type":"realtime","instructions":instructions,"reasoning":["effort":AppSettings.reasoningEfforts.contains(effort) ? effort:"minimal"],"output_modalities":["audio"],"audio":["input":["format":["type":"audio/pcm","rate":24000],"turn_detection":["type":"semantic_vad","eagerness":eagerness,"create_response":false,"interrupt_response":false],"transcription":transcription(language:inputLanguage),"noise_reduction":["type":"far_field"]],"output":["format":["type":"audio/pcm","rate":24000],"voice":voice]],"tools":tools,"tool_choice":"auto"]]
    }
}

public enum VoiceScriptRequest {
    public static func event(text:String,language:String,metadata:[String:String]=[:])->[String:Any] {
        ["type":"response.create","response":["conversation":"none","input":[],"output_modalities":["audio"],"tool_choice":"none","metadata":metadata,"instructions":"You are a text-to-speech reader. Read exactly the script below, in its written language. Do not greet, answer, explain, translate, or add words. The selected response language is \(language). SCRIPT:\n"+text]] // not localized: model instructions
    }
}
