import CheckmateDomain
import CheckmateContent
import CheckmateApplication
import CheckmateSupport
import Foundation
import Combine

/// D6: plays a short greeting in the voice selected in Settings, in its own short-lived session with no microphone,
/// no tools and no conversation, so the learner hears the voice they chose rather than the one a connected coach
/// already uses. One preview at a time; it closes when the greeting ends, is cancelled, or times out.
@MainActor public final class VoicePreview:ObservableObject {
    @Published public private(set) var playing=false
    @Published public private(set) var status=""
    public var usageLedger:UsageLedger?
    /// Why a preview cannot play now (coach speaking, lesson narration or recording); nil when it may.
    public var blocked:()->String?={nil}
    /// Whether the learner has agreed to what voice sends to OpenAI (V-1). A preview opens an OpenAI session, so until
    /// the app says so it plays nothing.
    public var consented:()->Bool={false}
    /// Told when a preview starts and ends, so a listening coach does not hear it as the learner.
    public var onPlayingChanged:(Bool)->Void={_ in}
    public let audio=VoiceAudio()
    private let gateway=VoiceGateway()
    private var task:Task<Void,Never>?,generation=UUID(),operation:String?,watchdog:Task<Void,Never>?
    /// The greeting has been received in full; only then does the end of playback end the preview (a gap between
    /// chunks is not the end).
    private var received=false
    public init(){}

    /// The session: audio out in the chosen voice, nothing in, no tools.
    nonisolated public static func sessionEvent(voice:String)->[String:Any] {
        ["type":"session.update","session":["type":"realtime","instructions":"You only greet the learner to preview your voice.","output_modalities":["audio"],"audio":["output":["format":["type":"audio/pcm","rate":24000],"voice":voice]],"tools":[] as [Any],"tool_choice":"none"]]
    }
    /// One greeting outside any conversation.
    nonisolated public static func greetingEvent(language:String)->[String:Any] {
        ["type":"response.create","response":["conversation":"none","input":[] as [Any],"output_modalities":["audio"],"tool_choice":"none","metadata":["checkmate_preview":"greeting"],"instructions":"Say one short, friendly greeting as a chess coach, under fifteen words, in \(language). Do not mention a move or a position."]]
    }

    public func play(voice:String,language:String,model:String,volume:Double){
        cancel()
        guard consented() else{status=VoiceUnavailability.consentNeeded.message;return}
        guard !NativePolicy.silent else{status="Live voice previews are disabled during automation.";return}
        if let reason=blocked(){status=reason;return}
        let current=UUID();generation=current;status="Preparing a preview…";audio.volume=Float(volume);setPlaying(true)
        received=false;let operation=usageLedger?.begin(activity:.voiceCoach,provider:"openai-realtime",sessionID:current.uuidString,model:model,locale:language,voice:voice);self.operation=operation
        audio.onPlaybackStart={[weak self] in guard let self,self.generation==current else{return};self.status="Playing \(voice.capitalized)…"}
        audio.onPlaybackEnd={[weak self] in guard let self,self.generation==current,self.received else{return};self.finish(nil)}
        // A route change discards what was queued: the preview is over.
        audio.onOutputChanged={[weak self] _ in guard let self,self.generation==current else{return};self.finish(nil)}
        task=Task{[weak self] in
            guard let self else{return}
            var bytes:Int64=0
            do {
                let secret=try await gateway.authorize(model:model)
                let socket=try await VoiceSocket.open(secret:secret,model:model,handshakeTimeout:15)
                defer{socket.closeSoon()}
                let deadline=Task{try? await Task.sleep(nanoseconds:20_000_000_000);if !Task.isCancelled{await socket.close()}}
                defer{deadline.cancel()}
                try await socket.send(Self.sessionEvent(voice:voice))
                var requested=false
                while !Task.isCancelled,generation==current {
                    let event=try await socket.receive()
                    guard generation==current else{return}
                    guard let type=event["type"] as? String else{continue}
                    if type=="error"{throw CheckmateError.unavailable("The preview could not be played. Try again.")}
                    if type=="session.updated",!requested{requested=true;try await socket.send(Self.greetingEvent(language:language))}
                    if type=="response.output_audio.delta",let encoded=event["delta"] as? String,let chunk=Data(base64Encoded:encoded){bytes+=Int64(chunk.count);try audio.append(chunk)}
                    if type=="response.done" {
                        let response=event["response"] as? [String:Any] ?? [:]
                        if let operation{usageLedger?.record(operationID:operation,providerID:response["id"] as? String,tokens:UsageTokens.parseRealtime(response["usage"] as? [String:Any]),status:response["status"] as? String=="completed" ? .completed:.failed,durationSeconds:Double(bytes)/48000,model:model);self.operation=nil}
                        guard response["status"] as? String=="completed",bytes>0 else{throw CheckmateError.unavailable("The preview could not be played. Try again.")}
                        // The socket closes; the greeting already received keeps playing until its end, bounded by its length.
                        received=true;if !audio.playing{finish(nil)}else{let limit=Double(bytes)/48000+5;watchdog=Task{[weak self] in try? await Task.sleep(nanoseconds:UInt64(limit*1_000_000_000));guard let self,!Task.isCancelled,self.generation==current else{return};self.finish(nil)}};return
                    }
                }
            } catch {
                guard generation==current else{return}
                if let operation=self.operation{usageLedger?.finish(operationID:operation,status:.failed);self.operation=nil}
                finish(Task.isCancelled ? nil:userFacingMessage(error,fallback:"The preview could not be played. Check account access and connectivity."))
            }
        }
    }
    /// Ends any preview: its session closes, its audio stops, and an unfinished usage record is closed as cancelled.
    public func cancel(){finish(nil)}
    private func finish(_ problem:String?){generation=UUID();task?.cancel();task=nil;watchdog?.cancel();watchdog=nil;if let operation{usageLedger?.finish(operationID:operation,status:.cancelled);self.operation=nil};audio.stop();setPlaying(false);status=problem ?? ""}
    private func setPlaying(_ value:Bool){guard playing != value else{return};playing=value;onPlayingChanged(value)}
}
