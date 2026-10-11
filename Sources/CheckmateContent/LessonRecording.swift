import CheckmateDomain
import CheckmateSupport
import Foundation
public struct LessonRecordingResult:Sendable {public var pcm:Data,transcript:String,responseID:String,tokens:UsageTokens?,model:String;public init(pcm:Data,transcript:String,responseID:String,tokens:UsageTokens?,model:String){self.pcm=pcm;self.transcript=transcript;self.responseID=responseID;self.tokens=tokens;self.model=model}}
public protocol LessonRecordingProvider:Sendable {func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult}
public enum LessonRecording {
 public static let maximumPCMBytes=28_800_000
 public static let maximumMessageBytes=2_000_000,maximumTranscriptBytes=64000
 public static func acceptedModel(_ model:String)->Bool {model.range(of:"^gpt-realtime(-[0-9]{4}-[0-9]{2}-[0-9]{2})?$",options:.regularExpression) == model.startIndex..<model.endIndex}
 /// No speech is faster than about 25 letters a second, and speech peaks far above -40 dBFS: shorter or quieter audio
 /// is a truncated or silent clip, whatever the provider's transcript says.
 public static func plausible(pcm:Data,script:String)->Bool {let letters=script.unicodeScalars.filter{CharacterSet.letters.contains($0)}.count;guard Double(pcm.count)/48000>=Double(letters)/25 else{return false};return pcm.withUnsafeBytes{raw in raw.bindMemory(to:Int16.self).contains{abs(Int32(Int16(littleEndian:$0)))>=328}}}
 public static func validate(pcm:Data,transcript:String,script:String,locale:String?=nil)throws->Double {guard !pcm.isEmpty,pcm.count%2==0,pcm.count<=maximumPCMBytes,plausible(pcm:pcm,script:script),VoiceScriptRequest.matches(transcript,script:script,locale:locale) else{throw CheckmateError.invalid("The recording did not match the requested script, or its audio was invalid. Retry explicitly.")};return Double(pcm.count)/48000}
 public static func validWAV(_ data:Data)->Bool {guard data.count>44,data.count<=maximumPCMBytes+44 else{return false};let bytes=[UInt8](data.prefix(44));func u16(_ i:Int)->Int{Int(bytes[i])|Int(bytes[i+1])<<8};func u32(_ i:Int)->Int{u16(i)|u16(i+2)<<16};return data.prefix(4)==Data("RIFF".utf8) && data[8..<16]==Data("WAVEfmt ".utf8) && data[36..<40]==Data("data".utf8) && u32(4)==data.count-8 && u32(16)==16 && u16(20)==1 && u16(22)==1 && u32(24)==24000 && u32(28)==48000 && u16(32)==2 && u16(34)==16 && u32(40)==data.count-44 && (data.count-44)%2==0}
 public static func wav(_ pcm:Data)->Data {var data=Data("RIFF".utf8);func append<T:FixedWidthInteger>(_ n:T){var v=n.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}};append(UInt32(pcm.count+36));data.append(Data("WAVEfmt ".utf8));append(UInt32(16));append(UInt16(1));append(UInt16(1));append(UInt32(24000));append(UInt32(48000));append(UInt16(2));append(UInt16(16));data.append(Data("data".utf8));append(UInt32(pcm.count));data.append(pcm);return data}
}

protocol LessonRecordingSocket:Sendable {
 func send(_ data:Data)async throws
 func receive()async throws->Data
 func close()
}
private final class LiveLessonRecordingSocket:LessonRecordingSocket,@unchecked Sendable {
 let session:URLSession,socket:URLSessionWebSocketTask
 init(secret:String) {
  let configuration=URLSessionConfiguration.ephemeral;configuration.timeoutIntervalForResource=180
  session=URLSession(configuration:configuration,delegate:VoiceGateway(),delegateQueue:nil)
  var request=URLRequest(url:URL(string:"wss://api.openai.com/v1/realtime?model=gpt-realtime")!)
  request.setValue("Bearer "+secret,forHTTPHeaderField:"Authorization")
  socket=session.webSocketTask(with:request);socket.maximumMessageSize=LessonRecording.maximumMessageBytes;socket.resume()
 }
 func send(_ data:Data)async throws {try await socket.send(.string(String(decoding:data,as:UTF8.self)))}
 func receive()async throws->Data {switch try await socket.receive(){case .data(let data):return data;case .string(let text):return Data(text.utf8);@unknown default:throw CheckmateError.unavailable("Unknown recording response.")}}
 func close(){socket.cancel(with:.goingAway,reason:nil);session.invalidateAndCancel()}
}
private final class RecordingTimeoutFlag:@unchecked Sendable {
 private let lock=NSLock();private var expired=false
 func mark(){lock.lock();expired=true;lock.unlock()}
 var timedOut:Bool {lock.lock();defer{lock.unlock()};return expired}
}
public final class RealtimeLessonRecorder:LessonRecordingProvider,@unchecked Sendable {
 private let secretProvider:@Sendable()async throws->String
 private let socketFactory:@Sendable(String)throws->any LessonRecordingSocket
 private let timeout:TimeInterval,fixture:Bool
 public init(){secretProvider={try await VoiceGateway().authorize()};socketFactory={LiveLessonRecordingSocket(secret:$0)};timeout=180;fixture=false}
 // Internal injection is restricted to silent fixture execution and cannot access live credentials.
 init(timeout:TimeInterval=180,secretProvider:@escaping @Sendable()async throws->String,socketFactory:@escaping @Sendable(String)throws->any LessonRecordingSocket){self.timeout=max(0.01,min(timeout,180));self.secretProvider=secretProvider;self.socketFactory=socketFactory;fixture=true}
 public func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {
  guard fixture == NativePolicy.silent else{throw CheckmateError.unavailable("Live recording is disabled during automation.")}
  guard LessonLanguages.normalizedSelection(locale)==locale,["cedar","marin"].contains(voice),!script.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,script.utf8.count<=32000 else{throw CheckmateError.invalid("Invalid recording language or voice.")}
  let socket=try socketFactory(try await secretProvider()),expired=RecordingTimeoutFlag();defer{socket.close()}
  do{return try await withTaskCancellationHandler(operation:{try await withThrowingTaskGroup(of:LessonRecordingResult.self){group in
   group.addTask {
    func send(_ event:[String:Any])async throws {try await socket.send(JSONSerialization.data(withJSONObject:event))}
    try await send(["type":"session.update","session":["type":"realtime","instructions":"Read the supplied script exactly; no tools or extra words.","output_modalities":["audio"],"audio":["input":["turn_detection":NSNull()],"output":["format":["type":"audio/pcm","rate":24000],"voice":voice,"speed":1.0]],"tools":[],"tool_choice":"none"]])
    var pcm=Data(),transcript="",started=false,responseID="",resolvedModel="gpt-realtime"
    while true {
     try Task.checkCancellation();let data=try await socket.receive()
     guard data.count<=LessonRecording.maximumMessageBytes,let event=try JSONSerialization.jsonObject(with:data) as? [String:Any],let type=event["type"] as? String else{throw CheckmateError.invalid("Invalid recording response.")}
     if type=="session.created" || type=="session.updated",let model=(event["session"] as? [String:Any])?["model"] as? String {resolvedModel=model}
     if type=="session.updated",!started {guard LessonRecording.acceptedModel(resolvedModel) else{throw CheckmateError.unavailable("The provider selected an unsupported recording model. No clip was saved.")};started=true;try await send(VoiceScriptRequest.event(text:script,language:locale))}
     if type=="response.created" {guard started,responseID.isEmpty,let id=(event["response"] as? [String:Any])?["id"] as? String,!id.isEmpty,id.utf8.count<=256 else{throw CheckmateError.invalid("Unexpected recording response.")};responseID=id}
     if type=="response.done",let response=event["response"] as? [String:Any] {
      let id=response["id"] as? String ?? responseID,tokens=UsageTokens.parseRealtime(response["usage"] as? [String:Any]);onUsage(id,tokens)
      guard started,!id.isEmpty,responseID==id,response["status"] as? String=="completed" else{throw CheckmateError.unavailable("Recording did not finish. Completed clips are preserved.")}
      guard LessonRecording.acceptedModel(resolvedModel) else{throw CheckmateError.unavailable("The provider selected an unsupported recording model. No clip was saved.")}
      _=try LessonRecording.validate(pcm:pcm,transcript:transcript,script:script,locale:locale)
      return LessonRecordingResult(pcm:pcm,transcript:transcript,responseID:id,tokens:tokens,model:resolvedModel)
     }
     if type.hasPrefix("response.output_audio") {
      guard !responseID.isEmpty,event["response_id"] as? String==responseID else{throw CheckmateError.invalid("Audio belonged to another recording response.")}
     }
     if type=="response.output_audio.delta" {guard let delta=event["delta"] as? String,let bytes=Data(base64Encoded:delta),bytes.count%2==0 else{throw CheckmateError.invalid("Invalid recording audio.")};guard pcm.count+bytes.count<=LessonRecording.maximumPCMBytes else{throw CheckmateError.invalid("The recording was too long.")};pcm.append(bytes)}
     if type=="response.output_audio_transcript.delta",let delta=event["delta"] as? String {guard transcript.utf8.count+delta.utf8.count<=LessonRecording.maximumTranscriptBytes else{throw CheckmateError.invalid("The recording transcript was too long.")};transcript+=delta}
     if type=="response.output_audio_transcript.done",let text=event["transcript"] as? String {guard text.utf8.count<=LessonRecording.maximumTranscriptBytes else{throw CheckmateError.invalid("The recording transcript was too long.")};transcript=text}
     if type.contains("function_call") || (event["item"] as? [String:Any])?["type"] as? String=="function_call" {throw CheckmateError.unavailable("Recording stopped because the provider attempted a tool.")}
     if type=="error" {throw CheckmateError.unavailable("The account could not generate this recording.")}
    }
   }
   group.addTask {try await Task.sleep(for:.seconds(self.timeout));expired.mark();socket.close();throw CheckmateError.unavailable("Recording timed out. Resume explicitly.")}
   defer{group.cancelAll()};guard let result=try await group.next() else{throw CancellationError()};return result
  }},onCancel:{socket.close()})}catch{if expired.timedOut{throw CheckmateError.unavailable("Recording timed out. Resume explicitly.")};if Task.isCancelled{throw CancellationError()};throw error}
 }
}
